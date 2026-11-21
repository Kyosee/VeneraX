import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/image_translation/bubble_pop_model.dart';
import 'package:venera/foundation/image_translation/model_file_download.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_sources.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

Future<String> _modelDigest(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

/// A single downloadable file of a model component. [urls] is a fallback
/// chain: mirrors are tried in order, so a blocked host does not make the
/// component impossible to install.
class ModelFile {
  const ModelFile(this.name, this.urls, {this.size, this.sha256Digest});

  /// File name inside the component directory.
  final String name;

  /// Candidate URLs. `{hf}` is replaced with the configured HuggingFace
  /// endpoint (official or mirror) at download time.
  final List<String> urls;

  final int? size;
  final String? sha256Digest;

  bool isComplete(FileStat stat) =>
      stat.type == FileSystemEntityType.file &&
      stat.size > 0 &&
      (size == null || stat.size == size);
}

/// A downloadable model component (detector / OCR / translator).
class ModelComponent {
  const ModelComponent({
    required this.id,
    required this.files,
    required this.approxSizeBytes,
    this.marker = false,
    this.preparedFile,
  });

  final String id;
  final List<ModelFile> files;

  /// Rough total download size, for display before downloading.
  final int approxSizeBytes;

  /// Mark the component installed after its validation or preparation succeeds.
  final bool marker;
  final String? preparedFile;

  String get displayName => switch (id) {
    'text_detector' => "Text detector".tl,
    'ocr_ja' => "Japanese OCR (manga)".tl,
    'ocr_zh_v5' => "Chinese OCR (Simplified + Traditional)".tl,
    'ocr_zh' => "Chinese / Latin OCR".tl,
    'ocr_en' => "English OCR".tl,
    'ocr_ko' => "Korean OCR".tl,
    'rt_detr' => "RT-DETR INT8 · Dialogue detection".tl,
    'bubble_pop' => "BubblePop · Speech bubbles".tl,
    'comic_text_detector' => "CTD · Text strokes".tl,
    _ => id,
  };

  static const markerName = 'verified';

  String get directory => FilePath.join(App.dataPath, 'translation_models', id);

  bool get isInstalled {
    for (var file in files) {
      if (!file.isComplete(File(filePath(file.name)).statSync())) {
        return false;
      }
    }
    final prepared = preparedFile;
    if (prepared != null) {
      final stat = File(filePath(prepared)).statSync();
      if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
        return false;
      }
    }
    return !marker || File(FilePath.join(directory, markerName)).existsSync();
  }

  String filePath(String name) => FilePath.join(directory, name);
}

/// Registry of every component the local translation pipeline can use.
///
/// The app downloads model files when the reader chooses to install them.
abstract class TranslationModels {
  /// Text region detector (PP-OCRv4 mobile, DBNet). Language independent.
  static const detector = ModelComponent(
    id: 'text_detector',
    approxSizeBytes: 4900000,
    files: [
      ModelFile('det.onnx', [
        '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_det_infer.onnx',
      ]),
    ],
  );

  /// Japanese OCR (manga-ocr, vision encoder-decoder). The only reliable
  /// option for vertical manga text; large but worth it.
  static const ocrJa = ModelComponent(
    id: 'ocr_ja',
    approxSizeBytes: 461000000,
    files: [
      ModelFile('encoder.onnx', [
        '{hf}/mayocream/manga-ocr-onnx/resolve/main/encoder_model.onnx',
      ]),
      ModelFile('decoder.onnx', [
        '{hf}/mayocream/manga-ocr-onnx/resolve/main/decoder_model.onnx',
      ]),
      ModelFile('vocab.txt', [
        '{hf}/mayocream/manga-ocr-onnx/resolve/main/vocab.txt',
      ]),
    ],
  );

  /// Chinese + Latin OCR (PP-OCRv4 mobile rec).
  static const ocrZh = ModelComponent(
    id: 'ocr_zh',
    approxSizeBytes: 11000000,
    files: [
      ModelFile('rec.onnx', [
        '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv4/ch_PP-OCRv4_rec_infer.onnx',
      ]),
      ModelFile('dict.txt', [
        'https://cdn.jsdelivr.net/gh/PaddlePaddle/PaddleOCR@v2.7.0/ppocr/utils/ppocr_keys_v1.txt',
        'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v2.7.0/ppocr/utils/ppocr_keys_v1.txt',
      ]),
    ],
  );

  /// English OCR (PP-OCRv3 rec).
  static const ocrEn = ModelComponent(
    id: 'ocr_en',
    approxSizeBytes: 9000000,
    files: [
      ModelFile('rec.onnx', [
        '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv3/en_PP-OCRv3_rec_infer.onnx',
      ]),
      ModelFile('dict.txt', [
        'https://cdn.jsdelivr.net/gh/PaddlePaddle/PaddleOCR@v2.7.0/ppocr/utils/en_dict.txt',
        'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v2.7.0/ppocr/utils/en_dict.txt',
      ]),
    ],
  );

  /// Korean OCR (PP-OCR mobile rec).
  static const ocrKo = ModelComponent(
    id: 'ocr_ko',
    approxSizeBytes: 8000000,
    files: [
      ModelFile('rec.onnx', [
        '{hf}/SWHL/RapidOCR/resolve/main/PP-OCRv1/korean_mobile_v2.0_rec_infer.onnx',
      ]),
      ModelFile('dict.txt', [
        'https://cdn.jsdelivr.net/gh/PaddlePaddle/PaddleOCR@v2.7.0/ppocr/utils/dict/korean_dict.txt',
        'https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/v2.7.0/ppocr/utils/dict/korean_dict.txt',
      ]),
    ],
  );

  /// Chinese OCR covering Simplified and Traditional (PP-OCRv5 mobile rec,
  /// 18k characters). The v4 dictionary lacks ~3.8k Traditional characters
  /// (說/讓/從/幾 ...), which then come out as wrong look-alikes.
  static const ocrZhV5 = ModelComponent(
    id: 'ocr_zh_v5',
    approxSizeBytes: 16700000,
    files: [
      ModelFile('rec.onnx', [
        'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master/onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx',
        '{hf}/webnn/PP-OCRv5-ONNX/resolve/main/ch_PP-OCRv5_rec.onnx',
      ]),
      ModelFile('dict.txt', [
        'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master/paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/ppocrv5_dict.txt',
        '{hf}/webnn/PP-OCRv5-ONNX/resolve/main/ch_PP-OCRv5_dict.txt',
      ]),
    ],
  );

  static const rtDetrRevision = '16e8a622f91fabc6b5b65c96d32d1183f8843546';
  static const rtDetrRepository = 'ogkalu/comic-text-and-bubble-detector';
  static const rtDetr = ModelComponent(
    id: 'rt_detr',
    approxSizeBytes: 11120765,
    marker: true,
    files: [
      ModelFile(
        'detector-v4-s_int8.onnx',
        [
          '{hf}/$rtDetrRepository/resolve/$rtDetrRevision/detector-v4-s_int8.onnx',
        ],
        size: 11120765,
        sha256Digest:
            '5fe9e4f576e49d4e7e8b0e029d6d3cdc252abd4694113e1cae120e62c931ea79',
      ),
    ],
  );
  static const bubblePopRevision = 'c8f207e98fc39065096e2ff602b65045051c447b';
  static const bubblePop = ModelComponent(
    id: 'bubble_pop',
    approxSizeBytes: 1904999,
    marker: true,
    preparedFile: bubblePopRuntimeFileName,
    files: [
      ModelFile(
        'model_fp16.onnx',
        [
          'https://raw.githubusercontent.com/letmutex/bubble-pop/$bubblePopRevision/model_fp16.onnx',
        ],
        size: 1904999,
        sha256Digest:
            '2c1a2cec608ba68ed1e2326570d47622db5920127bf53a80e713d393c74192d7',
      ),
    ],
  );
  static const comicTextDetector = ModelComponent(
    id: 'comic_text_detector',
    approxSizeBytes: 94669756,
    marker: true,
    files: [
      ModelFile(
        'comictextdetector.pt.onnx',
        [
          'https://github.com/zyddnys/manga-image-translator/releases/download/beta-0.3/comictextdetector.pt.onnx',
        ],
        size: 94669756,
        sha256Digest:
            '1a86ace74961413cbd650002e7bb4dcec4980ffa21b2f19b86933372071d718f',
      ),
    ],
  );
  static const recognizers = [ocrJa, ocrZhV5, ocrZh, ocrEn, ocrKo];
  static const enhancements = [rtDetr, comicTextDetector];
  static const all = [detector, ...recognizers, ...enhancements, bubblePop];

  static String? get strokeModelPath =>
      TranslationConfig.strokeEnhancementEnabled &&
          comicTextDetector.isInstalled
      ? comicTextDetector.filePath(comicTextDetector.files.single.name)
      : null;

  static ModelComponent? find(String id) {
    for (var c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Line-recognition engines (CTC models) by worker engine key. 'ja'
  /// (manga-ocr) is handled separately by the worker.
  static const _builtInRec = <String, (ModelComponent, String, int)>{
    'zh5': (ocrZhV5, 'zh', 48),
    'zh': (ocrZh, 'zh', 48),
    'en': (ocrEn, 'en', 48),
    'ko': (ocrKo, 'ko', 32),
  };

  /// The detector in use: the user's own once it passed its check, otherwise
  /// the built-in one.
  static ModelComponent get activeDetector {
    var custom = TranslationSources.detector?.component;
    return custom != null && custom.isInstalled ? custom : detector;
  }

  /// Model file paths for the worker isolate, containing only what is
  /// actually installed, plus the engines to try for [sourceLang].
  static WorkerModelPaths workerPaths([String sourceLang = 'auto']) {
    var recModels = <String, String>{};
    var recDicts = <String, String>{};
    var recHeights = <String, int>{};
    var recLanguages = <String, String>{};
    void add(String engine, ModelComponent component, String lang, int h) {
      if (!component.isInstalled) return;
      recModels[engine] = component.filePath('rec.onnx');
      recDicts[engine] = component.filePath('dict.txt');
      recHeights[engine] = h;
      recLanguages[engine] = lang;
    }

    _builtInRec.forEach((engine, e) => add(engine, e.$1, e.$2, e.$3));
    var custom = TranslationSources.find(sourceLang);
    if (custom != null) {
      add(custom.engine, custom.component, custom.code, custom.inputHeight);
    }
    var hasJa = ocrJa.isInstalled;
    final useBubbles = TranslationConfig.bubbleEnhancementEnabled;
    return WorkerModelPaths(
      detector: activeDetector.filePath('det.onnx'),
      rtDetrModel: useBubbles && rtDetr.isInstalled
          ? rtDetr.filePath(rtDetr.files.single.name)
          : null,
      bubbleModel: useBubbles && bubblePop.isInstalled
          ? bubblePop.filePath(bubblePopRuntimeFileName)
          : null,
      jaEncoder: hasJa ? ocrJa.filePath('encoder.onnx') : null,
      jaDecoder: hasJa ? ocrJa.filePath('decoder.onnx') : null,
      jaVocab: hasJa ? ocrJa.filePath('vocab.txt') : null,
      recModels: recModels,
      recDicts: recDicts,
      recHeights: recHeights,
      recLanguages: recLanguages,
      engines: resolveOcrEngines(
        sourceLang,
        installed: {...recModels.keys, if (hasJa) 'ja'},
        customEngine: custom?.engine,
      ),
    );
  }

  /// Components to flag "required" in the model management UI. With 'auto'
  /// any one OCR component suffices, so only the detector is required.
  static List<ModelComponent> requiredFor(String sourceLang) {
    var custom = TranslationSources.find(sourceLang);
    return [
      activeDetector,
      if (custom != null) custom.component,
      if (sourceLang == 'ja') ocrJa,
      if (sourceLang == 'zh-TW') ocrZhV5,
      if (sourceLang == 'zh') ocrZh.isInstalled ? ocrZh : ocrZhV5,
      if (sourceLang == 'en') ocrEn,
      if (sourceLang == 'ko') ocrKo,
    ];
  }

  /// Whether detection + OCR can run for [sourceLang]. Translation-engine
  /// readiness (LLM configured / local model installed) is checked
  /// separately by the service.
  static bool isReadyFor(String sourceLang) {
    // Checked on every reader image-provider construction; cache the file
    // probes and invalidate when the model store changes anything.
    return _readyCache[sourceLang] ??= _computeReady(sourceLang);
  }

  static bool _computeReady(String sourceLang) {
    if (!activeDetector.isInstalled) return false;
    return switch (sourceLang) {
      'auto' =>
        ocrJa.isInstalled || _builtInRec.values.any((e) => e.$1.isInstalled),
      'ja' => ocrJa.isInstalled,
      // v4 misreads Traditional text, so an explicit choice needs v5.
      'zh-TW' => ocrZhV5.isInstalled,
      'zh' => ocrZhV5.isInstalled || ocrZh.isInstalled,
      'en' => ocrEn.isInstalled,
      'ko' => ocrKo.isInstalled,
      _ => TranslationSources.find(sourceLang)?.component.isInstalled ?? false,
    };
  }

  static final _readyCache = <String, bool>{};

  static void invalidateReadyCache() => _readyCache.clear();
}

/// Ordered recognition engines for [sourceLang], limited to [installed].
/// v5 reads both Chinese scripts at least as well as v4, so it replaces v4
/// whenever present. 'auto' lists line engines only; the worker places 'ja'
/// by text direction.
List<String> resolveOcrEngines(
  String sourceLang, {
  required Set<String> installed,
  String? customEngine,
}) {
  var order = switch (sourceLang) {
    'auto' => const ['zh5', 'zh', 'en', 'ko'],
    'ja' => const ['ja'],
    // A comic auto-locked to Traditional still reads with v4 if that is all
    // that is installed.
    'zh' || 'zh-TW' => const ['zh5', 'zh'],
    'en' => const ['en'],
    'ko' => const ['ko'],
    _ => [if (customEngine != null) customEngine],
  };
  var result = order.where(installed.contains).toList();
  if (result.contains('zh5')) result.remove('zh');
  return result;
}

/// User-facing reason a downloaded model was rejected.
String describeModelCheck(ModelCheckException e) {
  return switch (e.failure) {
    ModelCheckFailure.cannotRun =>
      "The model could not run. Check that it is an ONNX file and the input height matches."
          .tl,
    ModelCheckFailure.notRecognizer =>
      "This is not a text recognition model (PP-OCR rec).".tl,
    ModelCheckFailure.notDetector =>
      "This is not a text detection model (PP-OCR det).".tl,
    ModelCheckFailure.dictionaryMismatch =>
      "The dictionary does not match the model: the model has @classes classes, the dictionary @entries lines."
          .tlParams({'classes': e.classes, 'entries': e.entries}),
  };
}

class ModelDownloadState {
  bool downloading = false;
  double progress = 0;
  int receivedBytes = 0;
  int? totalBytes;
  String? error;
}

/// Downloads and manages local translation model files.
class TranslationModelStore with ChangeNotifier {
  TranslationModelStore._();

  static final instance = TranslationModelStore._();

  final _states = <String, ModelDownloadState>{};
  final _cancelTokens = <String, CancelToken>{};
  final _downloads = <String, Completer<void>>{};
  final _deleting = <String>{};

  ModelDownloadState stateOf(ModelComponent component) {
    return _states.putIfAbsent(component.id, () => ModelDownloadState());
  }

  static String get hfEndpoint {
    var value = appdata.settings['imageTranslationHfEndpoint'];
    if (value is String && value.isNotEmpty) {
      return value;
    }
    return 'https://huggingface.co';
  }

  /// Model downloads are large one-shot transfers, so this stays a bare [Dio]
  /// (no shared cache / cookie / log interceptors, no total timeout) rather
  /// than [AppDio]. The adapter is still the app's: dio's default `dart:io`
  /// one honored none of the proxy / DNS / certificate settings, which made
  /// every download fail behind a TLS-intercepting proxy while the rest of the
  /// app kept working.
  Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        headers: {'User-Agent': 'venera/${App.version}'},
        followRedirects: true,
        maxRedirects: 10,
      ),
    )..httpClientAdapter = createAppHttpClientAdapter();
  }

  /// Download size of [url] without fetching it: a one-byte range request
  /// (some hosts omit Content-Length on HEAD), then Content-Length. Null when
  /// the host reports neither.
  Future<int?> probeSize(String url) async {
    var dio = _createDio();
    try {
      var response = await dio.get<ResponseBody>(
        url.replaceFirst('{hf}', hfEndpoint),
        options: Options(
          headers: {'Range': 'bytes=0-0'},
          responseType: ResponseType.stream,
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      var range = response.headers.value('content-range');
      var total = range == null ? null : int.tryParse(range.split('/').last);
      total ??= int.tryParse(response.headers.value('content-length') ?? '');
      // A host ignoring Range answers 200 with the whole file; the body is
      // never read and the forced close below drops it.
      if (total == null || (range == null && response.statusCode != 200)) {
        return null;
      }
      return total;
    } catch (e) {
      Log.warning('Translation Models', 'Size probe failed for $url: $e');
      return null;
    } finally {
      dio.close(force: true);
    }
  }

  /// Downloads [component]. [verify] runs once every file is present; a
  /// rejected model is deleted again and the reason shown as the error.
  Future<void> download(
    ModelComponent component, {
    Future<void> Function()? verify,
  }) async {
    var state = stateOf(component);
    if (state.downloading ||
        _deleting.contains(component.id) ||
        component.isInstalled) {
      return;
    }
    state
      ..downloading = true
      ..error = null
      ..progress = 0
      ..receivedBytes = 0
      ..totalBytes = component.approxSizeBytes;
    notifyListeners();
    var cancelToken = CancelToken();
    _cancelTokens[component.id] = cancelToken;
    final completed = Completer<void>();
    _downloads[component.id] = completed;
    BackgroundKeepAlive.instance.allowTransferBackground();
    _refreshKeepAlive();
    var dio = _createDio();
    try {
      Directory(component.directory).createSync(recursive: true);
      if (component.marker) {
        await File(
          component.filePath(ModelComponent.markerName),
        ).deleteIfExists();
      }
      // Progress is reported across the whole component, weighted by each
      // file's share of the approximate total.
      var finishedBytes = 0;
      for (var file in component.files) {
        var target = File(component.filePath(file.name));
        final stat = target.statSync();
        if (file.isComplete(stat)) {
          finishedBytes += stat.size;
          continue;
        }
        if (stat.type == FileSystemEntityType.file) await target.delete();
        Object? lastError;
        var ok = false;
        for (var url in file.urls) {
          url = url.replaceFirst('{hf}', hfEndpoint);
          try {
            await BackgroundKeepAlive.instance.runTransfer(
              '${"Translation model".tl}: ${component.displayName}',
              (onProgress) => downloadModelFile(
                dio: dio,
                url: url,
                target: target,
                cancelToken: cancelToken,
                onProgress: (count, total) {
                  onProgress(count, total);
                  state.receivedBytes = finishedBytes + count;
                  var estimated = component.approxSizeBytes;
                  if (estimated <= 0) estimated = finishedBytes + total;
                  state.progress = estimated <= 0
                      ? 0
                      : (state.receivedBytes / estimated).clamp(0.0, 1.0);
                  _refreshKeepAlive();
                  notifyListeners();
                },
              ),
            );
            if (!file.isComplete(target.statSync())) {
              await target.delete();
              throw FormatException('Incomplete model download'.tl);
            }
            ok = true;
            break;
          } catch (e) {
            if (cancelToken.isCancelled) {
              rethrow;
            }
            lastError = e;
            Log.warning(
              'Translation Models',
              'Model file download failed; trying the next configured source.',
            );
          }
        }
        if (!ok) {
          throw lastError ?? Exception('Download failed');
        }
        finishedBytes += target.lengthSync();
      }
      if (component.marker || verify != null) {
        try {
          for (final file in component.files) {
            final expected = file.sha256Digest;
            if (expected == null) continue;
            // Validate the downloaded bytes once, off the reader's UI isolate.
            final path = component.filePath(file.name);
            final actual = await compute(_modelDigest, path);
            if (actual != expected) {
              throw FormatException(
                'Model file differs from the official release'.tl,
              );
            }
          }
          if (component == TranslationModels.bubblePop) {
            await prepareBubblePopModel(component.filePath('model_fp16.onnx'));
          }
          await verify?.call();
        } catch (_) {
          // Gone so a retry downloads fresh files instead of re-checking bad
          // ones.
          await Directory(
            component.directory,
          ).deleteIgnoreError(recursive: true);
          rethrow;
        }
      }
      if (cancelToken.isCancelled) return;
      if (component.marker) {
        File(
          component.filePath(ModelComponent.markerName),
        ).writeAsStringSync('');
      }
      state.progress = 1;
    } catch (e) {
      if (!cancelToken.isCancelled) {
        state.error = e is ModelCheckException
            ? describeModelCheck(e)
            : e.toString();
        Log.error(
          'Translation Models',
          'Failed to download ${component.id}',
          e,
        );
      }
    } finally {
      dio.close();
      _cancelTokens.remove(component.id);
      state.downloading = false;
      _downloads.remove(component.id);
      completed.complete();
      _refreshKeepAlive();
      TranslationModels.invalidateReadyCache();
      notifyListeners();
    }
  }

  void cancelDownload(ModelComponent component) {
    _cancelTokens[component.id]?.cancel();
  }

  void _refreshKeepAlive() {
    // OHOS transfer grants are acquired around each file's network operation.
    if (!App.isAndroid) return;
    final active = _states.values.where((state) => state.downloading).toList();
    if (active.isEmpty) {
      BackgroundKeepAlive.instance.remove(BackgroundKeepAlive.tagModelDownload);
      return;
    }
    final progress =
        active.fold<double>(0, (sum, state) => sum + state.progress) /
        active.length;
    BackgroundKeepAlive.instance.update(
      BackgroundKeepAlive.tagModelDownload,
      '${"Translation model".tl}: ${active.length} · ${(progress * 100).toInt()}%',
    );
  }

  Future<void> delete(ModelComponent component) async {
    if (!_deleting.add(component.id)) return;
    try {
      cancelDownload(component);
      await _downloads[component.id]?.future;
      var dir = Directory(component.directory);
      if (dir.existsSync()) {
        await dir.deleteIgnoreError(recursive: true);
      }
      _states.remove(component.id);
      TranslationModels.invalidateReadyCache();
      notifyListeners();
    } finally {
      _deleting.remove(component.id);
    }
  }

  /// Total disk usage of installed model files.
  int get installedSizeBytes {
    var root = Directory(FilePath.join(App.dataPath, 'translation_models'));
    if (!root.existsSync()) return 0;
    var total = 0;
    for (var entity in root.listSync(recursive: true)) {
      if (entity is File) {
        total += entity.lengthSync();
      }
    }
    return total;
  }
}

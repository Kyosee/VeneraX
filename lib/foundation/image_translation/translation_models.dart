import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

/// A single downloadable file of a model component. [urls] is a fallback
/// chain: mirrors are tried in order, so a blocked host does not make the
/// component impossible to install.
class ModelFile {
  const ModelFile(this.name, this.urls);

  /// File name inside the component directory.
  final String name;

  /// Candidate URLs. `{hf}` is replaced with the configured HuggingFace
  /// endpoint (official or mirror) at download time.
  final List<String> urls;
}

/// A downloadable model component (detector / OCR / translator).
class ModelComponent {
  const ModelComponent({
    required this.id,
    required this.files,
    required this.approxSizeBytes,
  });

  final String id;
  final List<ModelFile> files;

  /// Rough total download size, for display before downloading.
  final int approxSizeBytes;

  String get directory =>
      FilePath.join(App.dataPath, 'translation_models', id);

  bool get isInstalled {
    for (var file in files) {
      var f = File(FilePath.join(directory, file.name));
      if (!f.existsSync() || f.lengthSync() == 0) {
        return false;
      }
    }
    return true;
  }

  String filePath(String name) => FilePath.join(directory, name);
}

/// Registry of every component the local translation pipeline can use.
///
/// All models are public, permissively licensed releases fetched directly
/// from their official repositories; nothing is bundled into the app so the
/// install stays lightweight until the user opts in.
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

  /// Neural translation model (M2M100-418M, int8 quantized ONNX export).
  /// One model translates between any pair of ~100 languages, fully offline.
  static const translator = ModelComponent(
    id: 'translator',
    approxSizeBytes: 350000000,
    files: [
      ModelFile('encoder.onnx', [
        '{hf}/Xenova/m2m100_418M/resolve/main/onnx/encoder_model_quantized.onnx',
      ]),
      ModelFile('decoder.onnx', [
        '{hf}/Xenova/m2m100_418M/resolve/main/onnx/decoder_model_quantized.onnx',
      ]),
      ModelFile('tokenizer.json', [
        '{hf}/Xenova/m2m100_418M/resolve/main/tokenizer.json',
      ]),
    ],
  );

  static const all = [detector, ocrJa, ocrZh, ocrEn, ocrKo, translator];

  static ModelComponent? find(String id) {
    for (var c in all) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The OCR component required for a source language.
  static ModelComponent ocrFor(String sourceLang) {
    return switch (sourceLang) {
      'ja' => ocrJa,
      'ko' => ocrKo,
      'en' => ocrEn,
      _ => ocrZh,
    };
  }

  /// Components required for the current source-language setting.
  static List<ModelComponent> requiredFor(String sourceLang) {
    return [detector, ocrFor(sourceLang), translator];
  }

  static bool isReadyFor(String sourceLang) {
    // Checked on every reader image-provider construction; cache the file
    // probes and invalidate when the model store changes anything.
    return _readyCache[sourceLang] ??= requiredFor(
      sourceLang,
    ).every((c) => c.isInstalled);
  }

  static final _readyCache = <String, bool>{};

  static void invalidateReadyCache() => _readyCache.clear();
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

  /// Model downloads are large one-shot transfers; a bare [Dio] client
  /// (no total timeout, default adapter) matches how the app handles other
  /// large file downloads.
  Dio _createDio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 30),
        headers: {'User-Agent': 'venera/${App.version}'},
        followRedirects: true,
        maxRedirects: 10,
      ),
    );
  }

  Future<void> download(ModelComponent component) async {
    var state = stateOf(component);
    if (state.downloading || component.isInstalled) {
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
    var dio = _createDio();
    try {
      Directory(component.directory).createSync(recursive: true);
      // Progress is reported across the whole component, weighted by each
      // file's share of the approximate total.
      var finishedBytes = 0;
      for (var file in component.files) {
        var target = File(component.filePath(file.name));
        if (target.existsSync() && target.lengthSync() > 0) {
          continue;
        }
        var temp = File('${target.path}.part');
        Object? lastError;
        var ok = false;
        for (var url in file.urls) {
          url = url.replaceFirst('{hf}', hfEndpoint);
          try {
            await dio.download(
              url,
              temp.path,
              cancelToken: cancelToken,
              onReceiveProgress: (count, total) {
                state.receivedBytes = finishedBytes + count;
                var estimated = component.approxSizeBytes;
                state.progress = (state.receivedBytes / estimated).clamp(
                  0.0,
                  1.0,
                );
                notifyListeners();
              },
            );
            temp.renameSync(target.path);
            ok = true;
            break;
          } catch (e) {
            temp.deleteIgnoreError();
            if (cancelToken.isCancelled) {
              rethrow;
            }
            lastError = e;
            Log.warning(
              'Translation Models',
              'Download failed from $url, trying next mirror: $e',
            );
          }
        }
        if (!ok) {
          throw lastError ?? Exception('Download failed');
        }
        finishedBytes += target.lengthSync();
      }
      state.progress = 1;
    } catch (e) {
      if (!cancelToken.isCancelled) {
        state.error = e.toString();
        Log.error('Translation Models', 'Failed to download ${component.id}', e);
      }
    } finally {
      dio.close();
      _cancelTokens.remove(component.id);
      state.downloading = false;
      TranslationModels.invalidateReadyCache();
      notifyListeners();
    }
  }

  void cancelDownload(ModelComponent component) {
    _cancelTokens[component.id]?.cancel();
  }

  Future<void> delete(ModelComponent component) async {
    cancelDownload(component);
    var dir = Directory(component.directory);
    if (dir.existsSync()) {
      await dir.deleteIgnoreError(recursive: true);
    }
    _states.remove(component.id);
    TranslationModels.invalidateReadyCache();
    notifyListeners();
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

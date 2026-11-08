import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/translations.dart';

// Serve the existing three models with tool/serve_ohos_ocr_models.dart.
// For hdc forwarding, override the URL with the device's loopback endpoint.
const _modelBase = String.fromEnvironment(
  'OHOS_OCR_MODEL_BASE_URL',
  defaultValue: 'http://10.0.2.2:18767',
);
const _restoreOnly = bool.fromEnvironment('OHOS_OCR_RESTORE_ONLY');
const _width = 800;
const _height = 256;
const _source = 'ohos_ocr_probe';
const _comic = 'hello_world';
const _config = TranslationConfig(
  sourceLang: 'en',
  targetLang: 'zh',
  mode: InpaintMode.smart,
);

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _letters(String text) =>
    text.replaceAll(RegExp(r'\s+'), '').toUpperCase();

Future<void> _downloadModels() async {
  final base = Uri.parse(_modelBase);
  _check(
    base.scheme == 'http' &&
        const {'127.0.0.1', '::1', '10.0.2.2'}.contains(base.host) &&
        base.userInfo.isEmpty &&
        !base.hasQuery &&
        !base.hasFragment &&
        (base.path.isEmpty || base.path == '/'),
    'Model URL must be HTTP on loopback or the emulator host, without a path.',
  );
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..findProxy = (_) => 'DIRECT';
  try {
    for (final entry in const {
      'text_detector/det.onnx': 8 * 1024 * 1024,
      'ocr_en/rec.onnx': 16 * 1024 * 1024,
      'ocr_en/dict.txt': 64 * 1024,
    }.entries) {
      final request = await client.getUrl(base.resolve('/${entry.key}'));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      _check(response.statusCode == 200, 'Model server rejected ${entry.key}.');
      _check(
        response.contentLength > 0 && response.contentLength <= entry.value,
        'Invalid model length for ${entry.key}.',
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        _check(
          bytes.length + chunk.length <= entry.value,
          'Model is too large.',
        );
        bytes.add(chunk);
      }
      _check(
        bytes.length == response.contentLength,
        'Model transfer was truncated.',
      );
      final file = File('${App.dataPath}/translation_models/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes.takeBytes(), flush: true);
    }
  } finally {
    client.close(force: true);
  }
  TranslationModels.invalidateReadyCache();
  _check(TranslationModels.isReadyFor('en'), 'English models are not ready.');
}

Future<Uint8List> _fixture({bool blank = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(Colors.white, BlendMode.src);
  if (!blank) {
    final text = TextPainter(
      text: const TextSpan(
        text: 'HELLO WORLD',
        style: TextStyle(color: Colors.black, fontSize: 64),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: _width - 96);
    _check(text.height < 100, 'Fixture unexpectedly wrapped.');
    text.paint(canvas, const Offset(48, 80));
    text.dispose();
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(_width, _height);
  picture.dispose();
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    _check(bytes != null, 'Fixture encoding failed.');
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<PageOcr> _ocr(PageTranslationPipeline pipeline, Uint8List bytes) =>
    pipeline
        .ocrPage(bytes, sourceLang: 'en', targetLang: 'zh')
        .timeout(const Duration(seconds: 90));

void _checkOcr(PageOcr result) {
  final text = result.pending.map((block) => block.text).join(' ');
  _check(
    _letters(text) == 'HELLOWORLD',
    'OCR expected HELLO WORLD, got: $text',
  );
  _check(result.ready.isEmpty, 'English OCR unexpectedly skipped translation.');
  _check(
    result.languageVotes['en'] == result.pending.length,
    'OCR language votes are not English.',
  );
  for (final block in result.pending) {
    final rect = block.rect;
    _check(
      rect.left >= 0 &&
          rect.top >= 0 &&
          rect.right <= _width &&
          rect.bottom <= _height &&
          rect.width > 0 &&
          rect.height > 0 &&
          rect.intersects(IntRect(48, 80, _width - 48, 180)),
      'OCR returned a box outside the fixture text area.',
    );
  }
}

void _setProvider({required bool enabled}) {
  final provider = LlmProvider(
    id: 'ohos_ocr_fixture',
    name: 'Local smoke fixture',
    url: '',
    key: '',
    model: '',
    kind: LlmProviderKind.customScript,
    // This checks real OCR input; it never makes a network request.
    script: r'''
async function translate(input) {
  const normalize = text => text.replace(/\s+/g, '').toUpperCase();
  if (input.sourceLang !== 'en' || input.targetLang !== 'zh' ||
      normalize(input.texts.join(' ')) !== 'HELLOWORLD') {
    throw new Error('Unexpected OCR input or language pair');
  }
  const words = {HELLO: '你好', WORLD: '世界', HELLOWORLD: '你好，世界'};
  return {texts: input.texts.map(text => {
    const translated = words[normalize(text)];
    if (!translated) throw new Error('Unexpected OCR block grouping');
    return translated;
  })};
}
''',
  );
  // Set fixture settings directly to avoid starting the app's sync workflow.
  appdata.settings['imageTranslationProviders'] = [
    if (enabled) provider.toJson(),
  ];
  appdata.settings['imageTranslationActiveProviderId'] = enabled
      ? provider.id
      : '';
  appdata.settings[LlmProviderStore.scriptsKey] = {
    if (enabled) provider.id: provider.script,
  };
}

String _key(int run, int page) =>
    ImageTranslationService.cacheKeyFor(_source, _comic, 'run_$run', page);

TranslationChapterIdentity _chapter(int run) =>
    ImageTranslationService.chapterIdentity(
      cid: _comic,
      sourceKey: _source,
      eid: 'run_$run',
      config: _config,
      comicTitle: 'OCR probe',
      chapterTitle: 'Run $run',
    );

List<TranslatedRegion> _stored(int run) {
  final regions = TranslationStore().get(_key(run, 1));
  _check(
    regions != null && regions.isNotEmpty,
    'Stored translation is missing.',
  );
  _check(
    regions!.map((region) => region.text).join().replaceAll('，', '') == '你好世界',
    'Stored translation text changed.',
  );
  final blank = TranslationStore().get(_key(run, 2));
  _check(blank != null && blank.isEmpty, 'Blank-page result was not stored.');
  return regions;
}

Future<Uint8List> _pixels(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  try {
    _check(
      image.width == _width && image.height == _height,
      'Image size changed.',
    );
    return (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    codec.dispose();
  }
}

Future<void> _checkPixels(
  Uint8List original,
  Uint8List rendered,
  List<TranslatedRegion> regions,
) async {
  final before = await _pixels(original);
  final after = await _pixels(rendered);
  // The inpainter dilates source masks; keep its small edge margin in scope.
  final allowed = [
    for (final region in regions) ...[
      region.rect.inflated(8, 8, _width, _height),
      for (final rect in region.eraseRects)
        rect.inflated(8, 8, _width, _height),
    ],
  ];
  var changed = 0;
  var outside = 0;
  for (var y = 0; y < _height; y++) {
    for (var x = 0; x < _width; x++) {
      final inside = allowed.any(
        (rect) =>
            x >= rect.left &&
            x < rect.right &&
            y >= rect.top &&
            y < rect.bottom,
      );
      if (!inside) outside++;
      final index = (y * _width + x) * 4;
      for (var channel = 0; channel < 4; channel++) {
        if (before[index + channel] == after[index + channel]) continue;
        _check(
          inside,
          'Rendering changed artwork outside the text area at $x,$y.',
        );
        changed++;
      }
    }
  }
  _check(
    changed > 0 && outside > _width * _height ~/ 2,
    'Rendered text is unchanged or its bounds cover the fixture.',
  );
}

Future<(Uint8List, Uint8List)> _restore(int run) async {
  _setProvider(enabled: false);
  TranslationWorker.instance.release();
  TranslationWorker.instance.dispose();
  final regions = _stored(run);
  final original = await File('${App.dataPath}/fixture_$run.png').readAsBytes();
  await CacheManager().delete(
    ImageTranslationService.renderedKey(_key(run, 1), _config.mode),
  );
  _check(!LlmTranslator.isConfigured, 'Restore unexpectedly has a translator.');
  final rendered = await ImageTranslationService.instance.renderStoredPage(
    _key(run, 1),
    original,
    _config.mode,
    chapter: _chapter(run),
  );
  _check(
    rendered != null,
    'Stored text could not regenerate the rendered image.',
  );
  _check(
    !TranslationWorker.instance.isWarm,
    'Restoring stored text invoked OCR.',
  );
  await _checkPixels(original, rendered!, regions);
  return (original, rendered);
}

Future<(String, Uint8List, Uint8List)> _runProbe(
  void Function(String) report,
) async {
  await App.init();
  // Redirect every store before opening any production manager.
  App.dataPath = '${App.dataPath}/ohos_ocr_probe';
  App.cachePath = '${App.cachePath}/ohos_ocr_probe';
  await Directory(App.dataPath).create(recursive: true);
  await Directory(App.cachePath).create(recursive: true);
  await appdata.init();
  appdata.settings['comicCacheDirectory'] = '';
  appdata.settings['proxy'] = 'direct';
  appdata.settings[TranslationConfig.sourceKeyName] = 'en';
  appdata.settings[TranslationConfig.targetKeyName] = 'zh';
  appdata.settings[TranslationConfig.inpaintKeyName] = 'smart';
  appdata.settings['imageTranslationPerformancePreset'] = 'saver';
  _setProvider(enabled: false);
  await AppTranslation.init();
  await OpenCC.init();
  await TranslationStore().init();
  await CacheManager().ready;
  final marker = File('${App.dataPath}/completed_runs');
  final completed = await marker.exists()
      ? int.parse(await marker.readAsString())
      : 0;
  _check(completed >= 0, 'Invalid probe run counter.');
  if (completed > 0) {
    report('Checking previous-launch text and image persistence...');
    final previous = await _restore(completed);
    if (_restoreOnly) {
      return (
        'PASS: prior-launch SQLite text, blank-page result and fresh PNG '
            'render without OCR, model downloads or a translator. Run $completed.',
        previous.$1,
        previous.$2,
      );
    }
  } else {
    _check(!_restoreOnly, 'Run the full probe once before restore-only mode.');
  }

  report('Downloading the three local models...');
  await _downloadModels();
  final original = await _fixture();
  final blank = await _fixture(blank: true);
  final pipeline = PageTranslationPipeline();
  report('Running real DBNet and English PP-OCR...');
  _checkOcr(await _ocr(pipeline, original));
  _check(pipeline.ocrIsWarm, 'OCR worker did not warm up.');
  _checkOcr(await _ocr(pipeline, original));
  _check((await _ocr(pipeline, blank)).isEmpty, 'Blank image produced text.');
  await pipeline.release();
  _check(!pipeline.ocrIsWarm, 'Model release did not reset worker state.');
  _checkOcr(await _ocr(pipeline, original));

  report(
    'Checking local script translation, text storage and rendered pixels...',
  );
  _setProvider(enabled: true);
  _check(
    ImageTranslationService.isReadyForLang('en'),
    'Translation is not ready.',
  );
  final run = completed + 1;
  final chapter = _chapter(run);
  // A failed attempt may have saved this run before writing its success marker.
  TranslationStore().deleteByPrefix(chapter.scopePrefix);
  await CacheManager().deleteByPrefix(chapter.scopePrefix);
  await File(
    '${App.dataPath}/fixture_$run.png',
  ).writeAsBytes(original, flush: true);
  final service = ImageTranslationService.instance;
  _check(
    await service.translateOne(
      _key(run, 1),
      '$_comic@$_source',
      original,
      _config,
      chapter: chapter,
    ),
    'Full translation produced no image.',
  );
  _check(
    !await service.translateOne(
      _key(run, 2),
      '$_comic@$_source',
      blank,
      _config,
      chapter: chapter,
    ),
    'Blank page unexpectedly produced a translation.',
  );
  final regions = _stored(run);
  final cached = await service.findTranslated(_key(run, 1), _config.mode);
  _check(cached != null, 'Translation did not write the rendered-image cache.');
  await _checkPixels(original, await cached!.readAsBytes(), regions);

  report('Reopening SQLite and regenerating the image from stored text...');
  TranslationStore().close();
  await TranslationStore().init();
  final restored = await _restore(run);
  await appdata.saveData(false);
  await marker.writeAsString('$run', flush: true);
  return (
    'PASS: real HELLO WORLD OCR, warm repeat, blank control, model release '
        'and reload; local script translation, SQLite reopen and stored-text PNG '
        'render with pixel bounds. Runs: $run; prior-launch persistence: '
        '${completed > 0 ? "verified" : "restart to verify"}. '
        'The translation is a fixed local fixture, not an online quality test.',
    restored.$1,
    restored.$2,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final status = ValueNotifier('Preparing isolated OCR probe...');
  Uint8List? original;
  Uint8List? rendered;
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, value, _) => ListView(
                children: [
                  SelectableText(value),
                  if (original != null) Image.memory(original),
                  if (rendered != null) Image.memory(rendered),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
  void report(String message) {
    status.value = message;
    debugPrint('OCR probe: $message');
  }

  try {
    final result = await _runProbe(report);
    original = result.$2;
    rendered = result.$3;
    report(result.$1);
  } catch (error, stack) {
    report('FAIL: $error\n$stack');
  } finally {
    TranslationWorker.instance.dispose();
    TranslationStore().close();
  }
}

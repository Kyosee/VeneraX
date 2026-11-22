import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_sources.dart';
import 'package:venera/pages/guide_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String oldPath;
  const bubbleKey = TranslationConfig.bubbleEnhancementKey;
  const formerStrokeKey = 'imageTranslationStrokeEnhancement';

  setUpAll(() async {
    await AppTranslation.init();
    await OpenCC.init();
  });
  setUp(() {
    oldPath = App.dataPath;
    temp = Directory.systemTemp.createTempSync('translation-enhancements-');
    App.dataPath = temp.path;
    TranslationModels.invalidateReadyCache();
    appdata.settings['language'] = 'en-US';
  });
  tearDown(() {
    App.dataPath = oldPath;
    appdata.settings[bubbleKey] = true;
    TranslationModels.invalidateReadyCache();
    temp.deleteSync(recursive: true);
  });

  void makeFile(ModelComponent model, String name, int size) {
    Directory(model.directory).createSync(recursive: true);
    final handle = File(model.filePath(name)).openSync(mode: FileMode.write);
    try {
      handle.truncateSync(size);
    } finally {
      handle.closeSync();
    }
  }

  Future<void> details(WidgetTester tester, ModelComponent component) async {
    final button = find.descendant(
      of: find.byKey(ValueKey(component.id)),
      matching: find.byTooltip('Model details'.tl),
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  Future<void> deleteLocalFiles(
    WidgetTester tester,
    ModelComponent component,
  ) async {
    await details(tester, component);
    final delete = find.text('Delete downloaded files');
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    final directory = Directory(component.directory);
    expect(directory.existsSync(), isTrue);
    await tester.runAsync(() async {
      await tester.tap(find.text('Confirm'));
      for (var i = 0; i < 50 && directory.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(directory.existsSync(), isFalse);
  }

  void installFixture(ModelComponent model) {
    for (final file in model.files) {
      makeFile(model, file.name, file.size ?? 1);
    }
    if (model.marker) makeFile(model, ModelComponent.markerName, 0);
  }

  for (final width in [320.0, 900.0]) {
    testWidgets(
      'installed detector aligns with the other model rows at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const detectorKey = TranslationSources.detectorKey;
        final previous = appdata.settings[detectorKey];
        final alternative = TranslationSources.detectorPresets.values.first;
        appdata.settings[detectorKey] = alternative.toJson();
        addTearDown(() => appdata.settings[detectorKey] = previous);
        installFixture(alternative.component);
        installFixture(TranslationModels.ocrEn);
        installFixture(TranslationModels.rtDetr);
        await tester.pumpWidget(
          const MaterialApp(home: TranslationModelsPage()),
        );
        final picker = find.byKey(const ValueKey('active-detector'));
        final arrow = find.descendant(
          of: picker,
          matching: find.byIcon(Icons.arrow_drop_down),
        );
        final detectorTitle = find.descendant(
          of: picker,
          matching: find.text('PP-OCRv6 small'),
        );
        final englishTitle = find.text(TranslationModels.ocrEn.displayName);
        double gapBelow(Finder title, ModelComponent model) {
          final info = find.descendant(
            of: find.byKey(ValueKey(model.id)),
            matching: find.byTooltip('Model details'),
          );
          return tester.getTopLeft(info).dy - tester.getBottomLeft(title).dy;
        }

        expect(
          tester.getTopLeft(detectorTitle).dx,
          closeTo(tester.getTopLeft(englishTitle).dx, 0.5),
        );
        expect(
          tester.getCenter(arrow).dx,
          closeTo(tester.getCenter(find.byType(Switch)).dx, 0.5),
        );
        expect(
          gapBelow(detectorTitle, alternative.component),
          closeTo(gapBelow(englishTitle, TranslationModels.ocrEn), 2),
        );
        await details(tester, alternative.component);
        expect(
          find.text(
            'One detector finds text regions for all source languages.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('library actions share a column at $width', (tester) async {
      tester.view.physicalSize = Size(width, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      installFixture(TranslationSources.detectorPresets.values.first.component);
      await tester.pumpWidget(const MaterialApp(home: TranslationModelsPage()));
      await tester.tap(find.text('Model library'));
      await tester.pumpAndSettle();
      final arrow = tester
          .getCenter(
            find.descendant(
              of: find.byType(DropdownButtonFormField<String>),
              matching: find.byIcon(Icons.arrow_drop_down),
            ),
          )
          .dx;
      final download = tester
          .getCenter(find.byIcon(Icons.download_outlined))
          .dx;
      final installed = tester.getCenter(find.byIcon(Icons.download_done)).dx;
      expect([
        arrow,
        download,
        installed,
      ], everyElement(closeTo(download, 0.5)));
    });

    testWidgets(
      'download source is above the library tabs and persists at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const key = 'imageTranslationHfEndpoint';
        final previous = appdata.settings[key];
        final wasBackgroundTask = App.isBackgroundTask;
        appdata.settings[key] = 'https://huggingface.co';
        App.isBackgroundTask = true;
        addTearDown(() {
          App.isBackgroundTask = wasBackgroundTask;
          appdata.settings[key] = previous;
        });
        await tester.pumpWidget(
          const MaterialApp(home: TranslationModelsPage()),
        );
        final source = find.text('Hugging Face download source');
        final tabs = find.byType(TabBar);
        expect(source, findsOneWidget);
        expect(
          tester.getBottomLeft(source).dy,
          lessThan(tester.getTopLeft(tabs).dy),
        );
        Future<void> selectSource(String current, String next) async {
          await tester.tap(find.text(current).hitTestable());
          await tester.pumpAndSettle();
          await tester.tap(find.text(next).hitTestable().last);
          await tester.pumpAndSettle();
        }

        await selectSource('Hugging Face', 'hf-mirror.com');
        expect(TranslationModelStore.hfEndpoint, 'https://hf-mirror.com');
        await tester.tap(find.widgetWithText(Tab, 'Text recognition'));
        await tester.pumpAndSettle();
        expect(source, findsOneWidget);
        expect(find.text('hf-mirror.com').hitTestable(), findsOneWidget);
        await tester.tap(find.text('My models'));
        await tester.pumpAndSettle();
        expect(source, findsNothing);
        await tester.tap(find.text('Model library'));
        await tester.pumpAndSettle();
        await selectSource('hf-mirror.com', 'Hugging Face');
        expect(TranslationModelStore.hfEndpoint, 'https://huggingface.co');
        expect(tester.takeException(), isNull);
      },
    );
  }

  test(
    'switching detectors preserves verified alternatives and legacy URLs',
    () async {
      final wasBackgroundTask = App.isBackgroundTask;
      App.isBackgroundTask = true;
      addTearDown(() => App.isBackgroundTask = wasBackgroundTask);
      final key = TranslationSources.detectorKey;
      final previous = appdata.settings[key];
      addTearDown(() => appdata.settings[key] = previous);
      const old = CustomDetectorModel(
        url: 'https://example.invalid/custom.onnx',
        sizeBytes: 123,
      );
      appdata.settings[key] = old.toJson();
      expect(TranslationSources.savedDetectors.keys, [old.url]);
      expect(TranslationModels.activeDetector, TranslationModels.detector);
      installFixture(old.component);
      final preset = TranslationSources.detectorPresets.values.last;
      installFixture(preset.component);
      expect(TranslationModels.activeDetector.id, old.component.id);
      TranslationSources.setDetector(preset);
      expect(
        TranslationModels.workerPaths().detector,
        preset.component.filePath('det.onnx'),
      );
      TranslationSources.setDetector(null);
      expect(TranslationModels.activeDetector, TranslationModels.detector);
      expect(old.component.isInstalled && preset.component.isInstalled, isTrue);
      expect(TranslationSources.savedDetectors.keys, [old.url]);
      TranslationSources.setDetector(old);
      await TranslationSources.removeDetector(old);
      expect(TranslationSources.savedDetectors, isEmpty);
      expect(TranslationModels.activeDetector, TranslationModels.detector);
      expect(preset.component.isInstalled, isTrue);
      await appdata.saveData(false);
    },
  );

  testWidgets(
    'retired downloads are listed locally and never selected for new pages',
    (tester) async {
      const oldDetector = ModelComponent(
        id: 'text_detector',
        files: [],
        approxSizeBytes: 0,
      );
      const oldChinese = ModelComponent(
        id: 'ocr_zh',
        files: [],
        approxSizeBytes: 0,
      );
      const unknown = ModelComponent(
        id: 'former_preset',
        files: [],
        approxSizeBytes: 0,
      );
      makeFile(oldDetector, 'det.onnx', 128);
      makeFile(oldChinese, 'rec.onnx', 128);
      makeFile(unknown, 'unknown.onnx.part', 321);
      expect(TranslationModels.isReadyFor('zh'), isFalse);
      expect(TranslationModels.workerPaths('zh').engines, isEmpty);
      expect(
        TranslationModels.requiredFor('zh'),
        contains(TranslationModels.ocrZhV5),
      );
      expect(TranslationModels.activeDetector.id, isNot(oldDetector.id));
      expect(
        TranslationModels.all.map((c) => c.id),
        isNot(contains(oldChinese.id)),
      );
      expect(TranslationModelStore.instance.localModelSizes[unknown.id], 321);
      await tester.pumpWidget(const MaterialApp(home: TranslationModelsPage()));
      expect(find.text('Older model files'), findsOneWidget);
      expect(find.byKey(ValueKey(oldDetector.id)), findsOneWidget);
      expect(find.byKey(ValueKey(oldChinese.id)), findsOneWidget);
      await deleteLocalFiles(tester, unknown);
      expect(oldDetector.isInstalled && oldChinese.isInstalled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'My models can remove an incomplete download without affecting an installed recognizer',
    (tester) async {
      const japanese = TranslationModels.ocrJa;
      const english = TranslationModels.ocrEn;
      makeFile(japanese, 'encoder.onnx.part', 432);
      installFixture(TranslationModels.detector);
      installFixture(english);

      await tester.pumpWidget(const MaterialApp(home: TranslationModelsPage()));
      await tester.tap(find.text('My models'));
      await tester.pumpAndSettle();
      final partial = find.byKey(ValueKey(japanese.id));
      expect(find.text('Incomplete model download'), findsOneWidget);
      expect(
        find.descendant(of: partial, matching: find.text('432 B')),
        findsOneWidget,
      );
      expect(TranslationModels.isReadyFor('ja'), isFalse);
      expect(TranslationModels.isReadyFor('en'), isTrue);

      await deleteLocalFiles(tester, japanese);
      expect(partial, findsNothing);
      expect(find.byKey(ValueKey(english.id)), findsOneWidget);
      expect(TranslationModels.isReadyFor('en'), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the model library is browse-only and the installed detector picker switches immediately',
    (tester) async {
      final previous = appdata.settings[TranslationSources.detectorKey];
      appdata.settings[TranslationSources.detectorKey] = <String, dynamic>{};
      addTearDown(
        () => appdata.settings[TranslationSources.detectorKey] = previous,
      );
      final alternative = TranslationSources.detectorPresets.values.first;
      installFixture(TranslationModels.detector);
      installFixture(alternative.component);
      await tester.pumpWidget(const MaterialApp(home: TranslationModelsPage()));
      await tester.tap(find.text('Model library'));
      await tester.pumpAndSettle();
      await details(tester, alternative.component);
      expect(TranslationModels.activeDetector, TranslationModels.detector);
      await tester.tap(find.text('My models'));
      await tester.pumpAndSettle();
      final picker = find.byKey(const ValueKey('active-detector'));
      await tester.tap(picker);
      await tester.pumpAndSettle();
      final wasBackgroundTask = App.isBackgroundTask;
      App.isBackgroundTask = true;
      try {
        await tester.tap(find.text('PP-OCRv6 small').hitTestable().last);
        await tester.pumpAndSettle();
      } finally {
        App.isBackgroundTask = wasBackgroundTask;
      }
      expect(TranslationModels.activeDetector.id, alternative.component.id);
      expect(TranslationModels.detector.isInstalled, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'custom recognizers show language names and installed file sizes',
    (tester) async {
      const key = TranslationSources.settingKey;
      final previous = appdata.settings[key];
      addTearDown(() => appdata.settings[key] = previous);
      CustomSourceLanguage language(String code, String name, int bytes) {
        final source = CustomSourceLanguage(
          code: code,
          name: name,
          modelUrl: 'https://example.invalid/$code/rec.onnx',
          dictUrl: 'https://example.invalid/$code/dict.txt',
          sizeBytes: 9000000,
        );
        makeFile(source.component, 'rec.onnx', bytes);
        makeFile(source.component, 'dict.txt', 70);
        makeFile(source.component, ModelComponent.markerName, 0);
        return source;
      }

      final french = language('fr', 'Français', 230);
      final german = language('de', 'Deutsch', 420);
      appdata.settings[key] = [french.toJson(), german.toJson()];
      Finder inRow(CustomSourceLanguage source, Finder text) => find.descendant(
        of: find.byKey(ValueKey(source.engine)),
        matching: text,
      );
      await tester.pumpWidget(const MaterialApp(home: TranslationModelsPage()));
      expect(inRow(french, find.text('Français')), findsOneWidget);
      expect(inRow(german, find.text('Deutsch')), findsOneWidget);
      expect(inRow(french, find.textContaining('300 B')), findsOneWidget);
      expect(inRow(german, find.textContaining('490 B')), findsOneWidget);
      await details(tester, french.component);
      expect(
        inRow(french, find.textContaining('/fr/rec.onnx')),
        findsOneWidget,
      );
      expect(
        inRow(french, find.textContaining('/fr/dict.txt')),
        findsOneWidget,
      );

      await tester.tap(find.text('Model library'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(Tab, 'Text recognition'));
      await tester.pumpAndSettle();
      expect(inRow(french, find.textContaining('9.0 MB')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('one downloaded model can serve two editable source languages', (
    tester,
  ) async {
    final previous = appdata.settings[TranslationSources.settingKey];
    addTearDown(
      () => appdata.settings[TranslationSources.settingKey] = previous,
    );
    final latin = TranslationSources.recognitionPresets.values.first;
    CustomSourceLanguage source(String code, String name) =>
        CustomSourceLanguage(
          code: code,
          name: name,
          modelUrl: latin.modelUrl,
          dictUrl: latin.dictUrl,
        );
    appdata.settings[TranslationSources.settingKey] = [
      source('fr', 'Français').toJson(),
      source('de', 'Deutsch').toJson(),
    ];
    installFixture(latin.component);
    tester.view.physicalSize = const Size(320, 680);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: TranslationModelsPage(sourceLang: 'fr')),
    );
    await tester.tap(find.text('My models'));
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey(latin.engine));
    expect(row, findsOneWidget);
    expect(find.text('PP-OCRv6 small'), findsNothing);
    expect(find.text('Français (fr)'), findsNothing);
    await details(tester, latin.component);
    expect(find.text('Français (fr)'), findsOneWidget);
    expect(find.text('Deutsch (de)'), findsOneWidget);
    expect(find.text('Delete downloaded files'), findsNothing);
    await tester.tap(find.byTooltip('Remove Français'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Other languages keep using the shared model'),
      findsOneWidget,
    );
    final wasBackgroundTask = App.isBackgroundTask;
    App.isBackgroundTask = true;
    try {
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
    } finally {
      App.isBackgroundTask = wasBackgroundTask;
    }
    expect(TranslationSources.find('fr'), isNull);
    expect(TranslationSources.find('de')!.component.isInstalled, isTrue);
    expect(tester.takeException(), isNull);
  });

  test(
    'enhancement settings survive a restart and stay on this device',
    () async {
      appdata.settings[bubbleKey] = false;
      appdata.settings[formerStrokeKey] = true;
      await appdata.saveData(false);
      final sync = jsonDecode(
        File('${temp.path}/syncdata.json').readAsStringSync(),
      );
      expect(sync['settings'], isNot(contains(bubbleKey)));
      expect(sync['settings'], isNot(contains(formerStrokeKey)));
      appdata.settings[bubbleKey] = true;
      await appdata.doInit();
      expect(TranslationConfig.bubbleEnhancementEnabled, isFalse);
    },
  );

  test(
    'dialogue enhancement is optional and switching it off preserves its files',
    () async {
      const dialogue = TranslationModels.rtDetr;
      const stroke = TranslationModels.legacyTextStrokes;
      final store = TranslationModelStore.instance;
      installFixture(TranslationModels.detector);
      installFixture(TranslationModels.ocrEn);
      expect(TranslationModels.isReadyFor('en'), isTrue);
      expect(TranslationModels.enhancements, [dialogue]);
      expect(TranslationModels.find('rt_detr'), same(dialogue));
      expect(TranslationModels.all, contains(dialogue));
      expect(TranslationModels.find(stroke.id), isNull);
      expect(TranslationModels.requiredFor('en'), isNot(contains(dialogue)));
      expect(TranslationModels.requiredFor('en'), isNot(contains(stroke)));
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);

      final dialogueFile = dialogue.files.single;
      makeFile(dialogue, dialogueFile.name, dialogueFile.size!);
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);
      makeFile(dialogue, ModelComponent.markerName, 0);
      expect(
        TranslationModels.workerPaths('en').rtDetrModel,
        dialogue.filePath(dialogueFile.name),
      );

      appdata.settings[bubbleKey] = false;
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);
      expect(dialogue.isInstalled, isTrue);
      appdata.settings[bubbleKey] = true;
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNotNull);

      await store.delete(dialogue);
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);
      expect(TranslationModels.isReadyFor('en'), isTrue);
    },
  );

  test('a damaged RT-DETR download is removed and retryable', () async {
    const model = TranslationModels.rtDetr;
    final store = TranslationModelStore.instance;
    makeFile(model, model.files.single.name, model.files.single.size!);
    await store.download(model);
    expect(model.isInstalled, isFalse);
    expect(Directory(model.directory).existsSync(), isFalse);
    expect(
      store.stateOf(model).error,
      contains('Model file differs from the official release'),
    );
    expect(store.stateOf(model).downloading, isFalse);
    await store.delete(model);
  });

  test(
    'retired CTD never downloads and partial files can be removed',
    () async {
      const model = TranslationModels.legacyTextStrokes;
      final store = TranslationModelStore.instance;
      await store.download(model);
      expect(Directory(model.directory).existsSync(), isFalse);
      makeFile(model, 'comictextdetector.pt.onnx.part', 11);
      expect(model.isInstalled, isTrue);
      await store.delete(model);
      expect(Directory(model.directory).existsSync(), isFalse);
    },
  );

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets(
      'opens the bundled model notices before downloading in $locale',
      (tester) async {
        appdata.settings['language'] = locale;
        tester.view.physicalSize = const Size(360, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          const MaterialApp(home: TranslationModelsPage()),
        );
        expect(find.textContaining('PaddlePaddle · Apache-2.0'), findsNothing);
        await details(tester, TranslationModels.detector);
        expect(
          find.textContaining('PaddlePaddle · Apache-2.0'),
          findsOneWidget,
        );
        final path = locale == 'en-US'
            ? 'doc/model-notices.en.md'
            : 'doc/model-notices.zh.md';
        await tester.runAsync(() async {
          await tester.tap(find.byTooltip('Model sources and licenses'.tl));
          await tester.pump();
          await rootBundle.loadString(path);
        });
        await tester.pumpAndSettle();
        expect(
          tester.widget<GuidePage>(find.byType(GuidePage)).assetPath,
          path,
        );
        expect(
          find.textContaining('detector-v4-s_int8.onnx', findRichText: true),
          findsWidgets,
        );
        expect(find.text('Failed to load the guide'.tl), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('model sources and licenses appear at phone width in $locale', (
      tester,
    ) async {
      appdata.settings['language'] = locale;
      makeFile(
        TranslationModels.legacyTextStrokes,
        'comictextdetector.pt.onnx',
        1,
      );
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: TranslationModelsPage(sourceLang: 'en')),
      );
      await tester.tap(find.text('Model library'.tl));
      await tester.pumpAndSettle();
      final tab = find.widgetWithText(Tab, 'Optional enhancements'.tl);
      await tester.ensureVisible(tab);
      await tester.pumpAndSettle();
      await tester.tap(tab);
      await tester.pumpAndSettle();
      await details(tester, TranslationModels.rtDetr);
      expect(find.text('ogkalu/Comic Translate'), findsOneWidget);
      final title = switch (locale) {
        'zh-CN' => 'RT-DETR INT8 · 对白识别',
        'zh-TW' => 'RT-DETR INT8 · 對白辨識',
        _ => 'RT-DETR INT8 · Dialogue detection',
      };
      expect(find.text(title), findsOneWidget);
      expect(
        find.text(TranslationModels.legacyTextStrokes.displayName),
        findsNothing,
      );
      await tester.tap(find.text('My models'.tl));
      await tester.pumpAndSettle();
      await details(tester, TranslationModels.legacyTextStrokes);
      final oldTile = find.byKey(
        ValueKey(TranslationModels.legacyTextStrokes.id),
      );
      expect(
        find.descendant(
          of: oldTile,
          matching: find.byIcon(Icons.delete_outline),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: oldTile, matching: find.text('Download'.tl)),
        findsNothing,
      );
      expect(
        find.text(
          'This older model is no longer used. You can delete its files.'.tl,
        ),
        findsOneWidget,
      );
      expect(find.text('dmMaze/CTD'), findsOneWidget);
      expect(find.text('Model release'.tl), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('installed dialogue detection has a switch in $locale', (
      tester,
    ) async {
      appdata.settings['language'] = locale;
      for (final component in TranslationModels.enhancements) {
        makeFile(
          component,
          component.files.single.name,
          component.files.single.size!,
        );
        makeFile(component, ModelComponent.markerName, 0);
      }
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: TranslationModelsPage()));
      final bubbleLabel = switch (locale) {
        'zh-CN' => '启用对白识别增强',
        'zh-TW' => '啟用對白辨識增強',
        _ => 'Use dialogue detection enhancement',
      };
      final toggle = find.descendant(
        of: find.byTooltip(bubbleLabel),
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isTrue);
      if (locale == 'en-US') {
        await tester.scrollUntilVisible(
          toggle.hitTestable(),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        // Keep the settings write synchronous under the widget test's fake clock.
        final wasBackgroundTask = App.isBackgroundTask;
        App.isBackgroundTask = true;
        try {
          await tester.tap(toggle);
          await tester.pumpAndSettle();
        } finally {
          App.isBackgroundTask = wasBackgroundTask;
        }
        final stored = jsonDecode(
          File('${temp.path}/appdata.json').readAsStringSync(),
        )['settings'];
        expect(stored[bubbleKey], isFalse);
        expect(TranslationConfig.bubbleEnhancementEnabled, isFalse);
        expect(
          TranslationModels.enhancements.every((model) => model.isInstalled),
          isTrue,
        );
      }
      expect(
        find.text(TranslationModels.legacyTextStrokes.displayName),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}

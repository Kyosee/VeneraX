import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String oldPath;
  const bubbleKey = TranslationConfig.bubbleEnhancementKey;
  const formerStrokeKey = 'imageTranslationStrokeEnhancement';

  setUpAll(() async {
    await AppTranslation.init();
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
      for (final base in [
        TranslationModels.detector,
        TranslationModels.ocrEn,
      ]) {
        for (final f in base.files) {
          makeFile(base, f.name, 1);
        }
      }
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
      final scrollable = find.byType(Scrollable).first;
      await tester.scrollUntilVisible(
        find.text('Apache-2.0'),
        240,
        scrollable: scrollable,
      );
      expect(find.text(TranslationModels.rtDetr.displayName), findsOneWidget);
      expect(find.text('ogkalu/Comic Translate'), findsOneWidget);
      final title = switch (locale) {
        'zh-CN' => 'RT-DETR INT8 · 对白识别',
        'zh-TW' => 'RT-DETR INT8 · 對白辨識',
        _ => 'RT-DETR INT8 · Dialogue detection',
      };
      expect(find.text(title), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('GPL-3.0'),
        190,
        scrollable: scrollable,
      );
      expect(
        find.text(TranslationModels.legacyTextStrokes.displayName),
        findsOneWidget,
      );
      final oldTile = find.widgetWithText(
        ListTile,
        TranslationModels.legacyTextStrokes.displayName,
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
      final tile = find.widgetWithText(ListTile, bubbleLabel);
      await tester.scrollUntilVisible(
        tile,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      final toggle = find.descendant(of: tile, matching: find.byType(Switch));
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

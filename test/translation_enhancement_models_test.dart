import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/bubble_pop_model.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String oldPath;
  const bubbleKey = TranslationConfig.bubbleEnhancementKey;
  const strokeKey = TranslationConfig.strokeEnhancementKey;

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
    appdata.settings[strokeKey] = true;
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
      appdata.settings[strokeKey] = true;
      await appdata.saveData(false);
      final sync = jsonDecode(
        File('${temp.path}/syncdata.json').readAsStringSync(),
      );
      expect(sync['settings'], isNot(contains(bubbleKey)));
      expect(sync['settings'], isNot(contains(strokeKey)));
      appdata.settings[bubbleKey] = true;
      appdata.settings[strokeKey] = false;
      await appdata.doInit();
      expect(TranslationConfig.bubbleEnhancementEnabled, isFalse);
      expect(TranslationConfig.strokeEnhancementEnabled, isTrue);
    },
  );

  test(
    'optional models are independent of OCR readiness and each other',
    () async {
      const bubble = TranslationModels.bubblePop;
      const dialogue = TranslationModels.rtDetr;
      const stroke = TranslationModels.comicTextDetector;
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
      expect(TranslationModels.enhancements, [dialogue, stroke]);
      expect(TranslationModels.find('rt_detr'), same(dialogue));
      expect(TranslationModels.find('bubble_pop'), same(bubble));
      expect(TranslationModels.all, containsAll([dialogue, bubble, stroke]));
      expect(TranslationModels.requiredFor('en'), isNot(contains(dialogue)));
      expect(TranslationModels.requiredFor('en'), isNot(contains(bubble)));
      expect(TranslationModels.requiredFor('en'), isNot(contains(stroke)));
      expect(TranslationModels.workerPaths('en').bubbleModel, isNull);
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);
      expect(TranslationModels.strokeModelPath, isNull);

      final original = bubble.files.single;
      makeFile(bubble, original.name, original.size!);
      makeFile(bubble, ModelComponent.markerName, 0);
      expect(bubble.isInstalled, isFalse);
      makeFile(bubble, bubblePopRuntimeFileName, 1);
      expect(
        TranslationModels.workerPaths('en').bubbleModel,
        bubble.filePath(bubblePopRuntimeFileName),
      );
      final dialogueFile = dialogue.files.single;
      makeFile(dialogue, dialogueFile.name, dialogueFile.size!);
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);
      makeFile(dialogue, ModelComponent.markerName, 0);
      expect(
        TranslationModels.workerPaths('en').rtDetrModel,
        dialogue.filePath(dialogueFile.name),
      );
      expect(TranslationModels.workerPaths('en').bubbleModel, isNotNull);

      final file = stroke.files.single;
      makeFile(stroke, file.name, file.size! - 1);
      expect(TranslationModels.strokeModelPath, isNull);
      makeFile(stroke, file.name, file.size!);
      expect(TranslationModels.strokeModelPath, isNull);
      makeFile(stroke, ModelComponent.markerName, 0);
      expect(TranslationModels.strokeModelPath, stroke.filePath(file.name));

      appdata.settings[bubbleKey] = false;
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);
      expect(TranslationModels.workerPaths('en').bubbleModel, isNull);
      expect(TranslationModels.strokeModelPath, isNotNull);
      appdata.settings[strokeKey] = false;
      expect(TranslationModels.strokeModelPath, isNull);
      expect(
        [dialogue, bubble, stroke].every((model) => model.isInstalled),
        isTrue,
      );
      appdata.settings[bubbleKey] = true;
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNotNull);
      expect(TranslationModels.workerPaths('en').bubbleModel, isNotNull);
      expect(TranslationModels.strokeModelPath, isNull);
      appdata.settings[strokeKey] = true;
      expect(TranslationModels.strokeModelPath, isNotNull);

      await store.delete(bubble);
      expect(TranslationModels.workerPaths('en').bubbleModel, isNull);
      expect(dialogue.isInstalled, isTrue);
      await store.delete(dialogue);
      expect(TranslationModels.workerPaths('en').rtDetrModel, isNull);
      expect(stroke.isInstalled, isTrue);
      await store.delete(stroke);
      expect(TranslationModels.strokeModelPath, isNull);
      expect(TranslationModels.isReadyFor('en'), isTrue);
    },
  );

  for (final model in [TranslationModels.rtDetr, TranslationModels.bubblePop]) {
    test('a damaged ${model.id} download is removed and retryable', () async {
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
  }

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets('model sources and licenses appear at phone width in $locale', (
      tester,
    ) async {
      appdata.settings['language'] = locale;
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
        find.text(TranslationModels.comicTextDetector.displayName),
        findsOneWidget,
      );
      expect(find.text('dmMaze/CTD'), findsOneWidget);
      expect(find.text('Model release'.tl), findsOneWidget);
      await tester.drag(scrollable, const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(find.text('letmutex/BubblePop'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('installed enhancements have independent switches in $locale', (
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
      final (bubbleLabel, strokeLabel) = switch (locale) {
        'zh-CN' => ('启用对白识别增强', '启用文字笔画增强'),
        'zh-TW' => ('啟用對白辨識增強', '啟用文字筆畫增強'),
        _ => (
          'Use dialogue detection enhancement',
          'Use text stroke enhancement',
        ),
      };
      for (final label in [bubbleLabel, strokeLabel]) {
        final tile = find.widgetWithText(ListTile, label);
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
          expect(stored[strokeKey], label == bubbleLabel);
          expect(TranslationConfig.bubbleEnhancementEnabled, isFalse);
          expect(
            TranslationConfig.strokeEnhancementEnabled,
            label == bubbleLabel,
          );
          expect(
            TranslationModels.enhancements.every((model) => model.isInstalled),
            isTrue,
          );
        }
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final installed in [false, true]) {
    testWidgets('legacy BubblePop remains manageable (installed=$installed)', (
      tester,
    ) async {
      const model = TranslationModels.bubblePop;
      final store = TranslationModelStore.instance;
      if (installed) {
        makeFile(model, model.files.single.name, model.files.single.size!);
        makeFile(model, bubblePopRuntimeFileName, 1);
        makeFile(model, ModelComponent.markerName, 0);
      } else {
        store.stateOf(model).downloading = true;
        addTearDown(() => store.stateOf(model).downloading = false);
      }
      await tester.pumpWidget(
        const MaterialApp(home: TranslationModelsPage(sourceLang: 'en')),
      );
      await tester.scrollUntilVisible(
        find.text(model.displayName),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      final tile = find.widgetWithText(ListTile, model.displayName);
      expect(
        find.descendant(
          of: tile,
          matching: find.byIcon(installed ? Icons.delete_outline : Icons.close),
        ),
        findsOneWidget,
      );
      expect(find.text('letmutex/BubblePop'), findsOneWidget);
      if (installed) {
        await tester.scrollUntilVisible(
          find.text('Use dialogue detection enhancement'),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Use dialogue detection enhancement'), findsOneWidget);
      }
    });
  }
}

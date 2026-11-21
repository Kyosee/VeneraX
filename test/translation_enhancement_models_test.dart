import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/bubble_pop_model.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String oldPath;

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
    'optional models are independent of OCR readiness and each other',
    () async {
      const bubble = TranslationModels.bubblePop;
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
      expect(TranslationModels.requiredFor('en'), isNot(contains(bubble)));
      expect(TranslationModels.requiredFor('en'), isNot(contains(stroke)));
      expect(TranslationModels.workerPaths('en').bubbleModel, isNull);
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

      final file = stroke.files.single;
      makeFile(stroke, file.name, file.size! - 1);
      expect(TranslationModels.strokeModelPath, isNull);
      makeFile(stroke, file.name, file.size!);
      expect(TranslationModels.strokeModelPath, isNull);
      makeFile(stroke, ModelComponent.markerName, 0);
      expect(TranslationModels.strokeModelPath, stroke.filePath(file.name));

      await store.delete(bubble);
      expect(TranslationModels.workerPaths('en').bubbleModel, isNull);
      expect(stroke.isInstalled, isTrue);
      await store.delete(stroke);
      expect(TranslationModels.strokeModelPath, isNull);
      expect(TranslationModels.isReadyFor('en'), isTrue);
    },
  );

  test(
    'a same-size damaged download is removed and remains retryable',
    () async {
      const model = TranslationModels.bubblePop;
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
    },
  );

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
      expect(
        find.text(TranslationModels.bubblePop.displayName),
        findsOneWidget,
      );
      expect(find.text('letmutex/BubblePop'), findsOneWidget);
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
      expect(tester.takeException(), isNull);
    });
  }
}

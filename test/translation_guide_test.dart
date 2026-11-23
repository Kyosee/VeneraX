import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const comic = 'seaside';
  const source = 'sample';
  const home = ReaderSettings(translationOnly: true);
  const help = ReaderSettings(translationOnly: true, section: 'Help & cleanup');
  final card = find.byKey(const ValueKey('translation-guide-card'));
  final hide = find.byKey(const ValueKey('hide-translation-guide'));
  final guide = find.byType(TranslationGuidePage);
  final title = find.text('Translate your first manga page');
  final preference = find.widgetWithText(
    SwitchListTile,
    'Show translation guide automatically',
  );
  Finder comicSwitch() => find.descendant(
    of: find.widgetWithText(ListTile, 'Translate pages while reading'),
    matching: find.byType(Switch),
  );

  late Directory temporary;
  late String previousPath;
  late bool previousBackground;
  setUpAll(AppTranslation.init);
  setUp(() {
    previousPath = App.dataPath;
    previousBackground = App.isBackgroundTask;
    temporary = Directory.systemTemp.createTempSync('translation-guide-');
    App.dataPath = temporary.path;
    appdata.implicitData = {};
    appdata.settings['language'] = 'en-US';
    appdata.settings['deviceId'] = 'guide-test';
    appdata.settings['imageTranslationProviders'] = <dynamic>[];
    appdata.settings['imageTranslationSource'] = 'auto';
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    TranslationModels.invalidateReadyCache();
  });
  tearDown(() async {
    await appdata.saveData(false);
    TranslationModels.invalidateReadyCache();
    App.isBackgroundTask = previousBackground;
    App.dataPath = previousPath;
    await temporary.delete(recursive: true);
  });

  Future<void> show(WidgetTester tester, Widget content) async {
    // Use synchronous temp-file writes so widget fake time never waits on native I/O.
    App.isBackgroundTask = true;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(body: content),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  void size(WidgetTester tester, double width) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 850);
    addTearDown(tester.view.reset);
  }

  void configureFreeProvider() {
    appdata.settings['imageTranslationProviders'] = [
      {'id': 'demo', 'kind': LlmProviderKind.publicFree.token},
    ];
    appdata.settings['imageTranslationSource'] = 'en';
    expect(LlmTranslator.isConfigured, isTrue);
  }

  void installModelFixture(ModelComponent component) {
    Directory(component.directory).createSync(recursive: true);
    for (final spec in component.files) {
      final file = File(
        component.filePath(spec.name),
      ).openSync(mode: FileMode.write);
      try {
        file.truncateSync(spec.size ?? 1);
      } finally {
        file.closeSync();
      }
    }
    if (component.marker) {
      File(component.filePath(ModelComponent.markerName)).createSync();
    }
    TranslationModels.invalidateReadyCache();
  }

  test('automatic guide preference survives reloading device data', () async {
    await appdata.saveData(false);
    expect(TranslationGuidePage.showAutomatically, isTrue);
    await TranslationGuidePage.setShowAutomatically(false);
    appdata.implicitData = {};
    expect(TranslationGuidePage.showAutomatically, isTrue);
    await appdata.doInit();
    expect(TranslationGuidePage.showAutomatically, isFalse);

    final disabledData = Map<String, dynamic>.from(appdata.implicitData);
    await TranslationGuidePage.setShowAutomatically(true);
    appdata.implicitData = disabledData;
    await appdata.doInit();
    expect(TranslationGuidePage.showAutomatically, isTrue);
  });

  for (final (width, scale, language) in [
    (2088.0, 1.0, 'en-US'),
    (320.0, 1.0, 'zh-CN'),
    (320.0, 2.0, 'en-US'),
  ]) {
    testWidgets(
      'guide entry fits the settings list at ${width}px, ${scale}x',
      (tester) async {
        appdata.settings['language'] = language;
        size(tester, width);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await show(tester, home);

        final entry = tester.getRect(card);
        expect(
          tester.widget<Material>(card).color,
          Theme.of(tester.element(card)).colorScheme.primaryContainer,
        );
        final nextRow = tester.getRect(
          find.widgetWithText(
            SwitchListTile,
            'Enable device specific settings'.tl,
          ),
        );
        expect(entry.left, nextRow.left);
        expect(entry.right, nextRow.right);
        final prompt = tester.getRect(
          find.text('First time translating a comic?'.tl),
        );
        final open = find.widgetWithText(FilledButton, 'Tutorial'.tl);
        final skip = find.widgetWithText(TextButton, 'Skip'.tl);
        expect(open.hitTestable(), findsOneWidget);
        expect(skip.hitTestable(), findsOneWidget);
        final openRect = tester.getRect(open);
        final skipRect = tester.getRect(skip);
        expect(openRect.overlaps(skipRect), isFalse);
        for (final rect in [openRect, skipRect]) {
          expect(rect.height, greaterThanOrEqualTo(kMinInteractiveDimension));
          expect(rect.width, greaterThanOrEqualTo(kMinInteractiveDimension));
          expect(entry.contains(rect.center), isTrue);
        }
        if (scale == 1) {
          expect(entry.height, lessThanOrEqualTo(56));
          expect(openRect.center.dy, closeTo(prompt.center.dy, 1));
        } else {
          expect(openRect.top, greaterThanOrEqualTo(prompt.bottom));
        }
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(
        width > 1000 ? TargetPlatform.windows : TargetPlatform.android,
      ),
    );
  }

  for (final width in [390.0, 1050.0]) {
    testWidgets('guide can be dismissed and reopened manually at ${width}px', (
      tester,
    ) async {
      size(tester, width);
      await show(tester, home);
      expect(card, findsOneWidget);
      expect(comicSwitch(), findsNothing);
      await tap(tester, hide);
      expect(card, findsNothing);
      expect(TranslationGuidePage.showAutomatically, isFalse);

      await show(tester, help);
      expect(tester.widget<SwitchListTile>(preference).value, isFalse);
      final helpRow = find.widgetWithText(ListTile, 'How AI translation works');
      await tap(
        tester,
        find.descendant(of: helpRow, matching: find.text('Help')),
      );
      expect(title, findsOneWidget);
      expect(tester.widget<TranslationGuidePage>(guide).comicId, isNull);
      final sample = find.text('Next stop\nSeaside Station.');
      final original = find.text('次は\n海辺駅です。');
      expect(original, findsOneWidget);
      await tap(tester, find.text('Show translated'));
      expect(sample, findsOneWidget);
      await tap(tester, find.text('Show original'));
      expect(sample, findsNothing);
      expect(original, findsOneWidget);
      expect(ImageTranslationService.enabledComicKeys, isEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(preference, findsOneWidget);
      await tap(tester, preference);
      expect(TranslationGuidePage.showAutomatically, isTrue);
      await show(tester, home);
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('closing the service test discards a late result', (
    tester,
  ) async {
    size(tester, 390);
    appdata.settings['imageTranslationProviders'] = [
      {'id': 'delayed', 'kind': LlmProviderKind.customScript.token},
    ];
    final previousScripts = appdata.settings[LlmProviderStore.scriptsKey];
    appdata.settings[LlmProviderStore.scriptsKey] = {
      'delayed': 'function translate(input) { return {texts: input.texts}; }',
    };
    addTearDown(
      () => appdata.settings[LlmProviderStore.scriptsKey] = previousScripts,
    );
    await show(tester, const TranslationGuidePage());
    await tap(tester, find.text('Connect a translation service'));
    final testService = find.text('Test translation');
    await tester.ensureVisible(testService);
    await tester.pumpAndSettle();

    // Delay provider startup so the user can dismiss the test before it fails.
    final messenger = tester.binding.defaultBinaryMessenger;
    final response = Completer<ByteData?>();
    rootBundle.evict('assets/init.js');
    messenger.setMockMessageHandler('flutter/assets', (message) {
      expect(const StringCodec().decodeMessage(message), 'assets/init.js');
      return response.future;
    });
    addTearDown(() {
      messenger.setMockMessageHandler('flutter/assets', null);
      rootBundle.evict('assets/init.js');
    });
    await tester.tap(testService);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Testing translation'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    response.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Translation failed'), findsNothing);
    expect(testService.hitTestable(), findsOneWidget);
  });

  testWidgets('reader waits for setup and respects the per-device opt-out', (
    tester,
  ) async {
    size(tester, 390);
    await show(
      tester,
      const ReaderSettings(
        translationOnly: true,
        comicId: comic,
        comicSource: source,
      ),
    );
    await tap(tester, comicSwitch());
    expect(find.text('Connect a translation service'), findsOneWidget);
    final contextualGuide = tester.widget<TranslationGuidePage>(guide);
    expect(contextualGuide.comicId, comic);
    expect(contextualGuide.comicSource, source);
    expect(ImageTranslationService.enabledComicKeys, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(comicSwitch()).value, isFalse);

    await tap(tester, hide);
    await tap(tester, comicSwitch());
    expect(guide, findsNothing);
    expect(tester.widget<Switch>(comicSwitch()).value, isTrue);
    expect(ImageTranslationService.isEnabledForComic(comic, source), isTrue);
    expect(ImageTranslationService.isEnabledForComic('other', source), isFalse);
    expect(ImageTranslationService.isEnabledForComic(comic, 'other'), isFalse);
    await tap(tester, comicSwitch());
    expect(ImageTranslationService.enabledComicKeys, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'first-time setup adds a provider directly and only saves on confirmation',
    (tester) async {
      size(tester, 390);
      await show(tester, home);
      await tap(tester, find.text('Tutorial'));
      await tap(tester, find.text('Add provider'));
      expect(find.byType(LlmProvidersPage), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('LLM API Key'), findsNothing);
      await tap(tester, find.text('Cancel'));
      expect(LlmProviderStore.active, isNull);
      expect(TranslationGuidePage.showAutomatically, isTrue);
      await tap(tester, find.text('Add provider'));
      await tap(tester, find.text('Save'));
      expect(LlmProviderStore.active?.kind, LlmProviderKind.publicFree);
      expect(find.text('Test translation'), findsOneWidget);
      await tap(tester, find.text('Continue'));
      expect(find.text('Model management'), findsOneWidget);
      expect(ImageTranslationService.enabledComicKeys, isEmpty);
    },
  );

  testWidgets(
    'guide edits the comic language in place and refreshes model readiness',
    (tester) async {
      size(tester, 390);
      configureFreeProvider();
      installModelFixture(TranslationModels.detector);
      installModelFixture(TranslationModels.ocrEn);
      appdata.settings.setEnabledComicSpecificSettings(comic, source, true);
      appdata.settings.setReaderSetting(
        comic,
        source,
        'imageTranslationSource',
        'ja',
      );
      final changes = <String>[];
      await show(
        tester,
        ReaderSettings(
          translationOnly: true,
          comicId: comic,
          comicSource: source,
          onChanged: changes.add,
        ),
      );
      await tap(tester, comicSwitch());
      expect(find.text('Model management'), findsOneWidget);
      expect(find.text('Continue'), findsNothing);
      await tap(tester, find.text('Source language'));
      await tap(tester, find.text('English').last);
      expect(
        appdata.settings.getReaderSetting(
          comic,
          source,
          'imageTranslationSource',
        ),
        'en',
      );
      expect(changes, contains('imageTranslationSource'));
      expect(guide, findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(ImageTranslationService.enabledComicKeys, isEmpty);
    },
  );

  testWidgets(
    'a configured service opens the missing model step and waits for consent',
    (tester) async {
      size(tester, 390);
      configureFreeProvider();
      await show(
        tester,
        const ReaderSettings(
          translationOnly: true,
          comicId: comic,
          comicSource: source,
        ),
      );
      await tap(tester, comicSwitch());
      expect(find.text('Model management'), findsOneWidget);
      expect(find.text('LLM providers'), findsNothing);
      expect(ImageTranslationService.enabledComicKeys, isEmpty);

      await tap(tester, find.text('Model management'));
      expect(find.byType(TranslationModelsPage), findsOneWidget);
      installModelFixture(TranslationModels.ocrEn);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(TranslationModels.isReadyFor('en'), isFalse);
      await tap(tester, find.text('Enable translation for this comic'));
      expect(find.text('Enable AI translation'), findsNothing);
      await tap(tester, find.text('Set up'));
      expect(find.text('Model management'), findsOneWidget);
      expect(ImageTranslationService.enabledComicKeys, isEmpty);

      await tap(tester, find.text('Model management'));
      installModelFixture(TranslationModels.detector);
      expect(find.byType(TranslationModelsPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(TranslationModels.isReadyFor('en'), isTrue);
      expect(guide, findsOneWidget);
      await tap(tester, find.text('Continue'));
      expect(ImageTranslationService.enabledComicKeys, isEmpty);
      await tap(tester, find.text('Enable AI translation'));
      expect(guide, findsNothing);
      expect(tester.widget<Switch>(comicSwitch()).value, isTrue);
      expect(ImageTranslationService.enabledComicKeys, {'$comic@$source'});
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ready models bypass the guide only for the supported source language',
    (tester) async {
      size(tester, 390);
      configureFreeProvider();
      installModelFixture(TranslationModels.detector);
      installModelFixture(TranslationModels.ocrEn);
      const japaneseComic = 'japanese-edition';
      appdata.settings.setEnabledComicSpecificSettings(
        japaneseComic,
        source,
        true,
      );
      appdata.settings.setReaderSetting(
        japaneseComic,
        source,
        'imageTranslationSource',
        'ja',
      );

      await show(
        tester,
        const ReaderSettings(
          translationOnly: true,
          comicId: comic,
          comicSource: source,
        ),
      );
      expect(TranslationGuidePage.showAutomatically, isTrue);
      await tap(tester, comicSwitch());
      expect(guide, findsNothing);
      expect(tester.widget<Switch>(comicSwitch()).value, isTrue);
      expect(ImageTranslationService.enabledComicKeys, {'$comic@$source'});

      await show(
        tester,
        const ReaderSettings(
          translationOnly: true,
          comicId: japaneseComic,
          comicSource: source,
        ),
      );
      expect(tester.widget<Switch>(comicSwitch()).value, isFalse);
      await tap(tester, comicSwitch());
      expect(tester.widget<TranslationGuidePage>(guide).comicId, japaneseComic);
      expect(find.text('Model management'), findsOneWidget);
      expect(ImageTranslationService.enabledComicKeys, {'$comic@$source'});
      expect(tester.takeException(), isNull);
    },
  );
}

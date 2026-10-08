import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('settings-scope-');
    App.dataPath = temporary.path;
    await AppTranslation.init();
  });
  tearDownAll(() async {
    await appdata.saveData(false);
    temporary.deleteSync(recursive: true);
  });
  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['deviceId'] = 'scope-test';
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['readerMode'] = 'continuousTopToBottom';
    appdata.settings['showChapterComments'] = true;
  });

  test(
    'resetting one override restores inheritance and keeps other overrides',
    () {
      final settings = appdata.settings;
      settings.setEnabledDeviceSpecificSettings(true);
      settings.setDeviceReaderSetting('readerMode', 'galleryLeftToRight');
      settings.setEnabledComicSpecificSettings('comic', 'source', true);
      settings.setReaderSetting(
        'comic',
        'source',
        'readerMode',
        'galleryRightToLeft',
      );
      settings.setReaderSetting(
        'comic',
        'source',
        'showChapterComments',
        false,
      );
      settings.resetComicReaderSetting('comic', 'source', 'readerMode');
      expect(
        settings.getReaderSetting('comic', 'source', 'readerMode'),
        'galleryLeftToRight',
      );
      expect(
        settings.hasComicReaderSetting(
          'comic',
          'source',
          'showChapterComments',
        ),
        isTrue,
      );
      expect(
        settings.getReaderSetting('comic', 'source', 'showChapterComments'),
        isFalse,
      );
      settings.resetDeviceReaderSetting('readerMode');
      expect(
        settings.getReaderSetting('comic', 'source', 'readerMode'),
        'continuousTopToBottom',
      );
      expect(settings.isDeviceSpecificSettingsEnabled(), isTrue);
      expect(
        settings.isComicSpecificSettingsEnabled('comic', 'source'),
        isTrue,
      );
    },
  );

  testWidgets('chapter-end options follow device mode instead of global mode', (
    tester,
  ) async {
    appdata.settings.setEnabledDeviceSpecificSettings(true);
    appdata.settings.setDeviceReaderSetting('readerMode', 'galleryLeftToRight');
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ReaderSettings())),
    );
    await tester.pumpAndSettle();
    final display = find.text('Display settings');
    await tester.scrollUntilVisible(
      display,
      400,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(display);
    await tester.pumpAndSettle();
    expect(find.text('Show Comments at Chapter End'), findsOneWidget);
  });

  test(
    'translation summary follows device defaults without changing global settings',
    () {
      appdata.settings['imageTranslationSource'] = 'auto';
      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setDeviceReaderSetting('imageTranslationSource', 'ja');
      expect(TranslationConfig.device.sourceLang, 'ja');
      expect(TranslationConfig.of('comic', 'source').sourceLang, 'ja');
      expect(TranslationConfig.global.sourceLang, 'auto');
      appdata.settings.setDeviceReaderSetting('imageTranslationSource', '');
      expect(TranslationConfig.device.sourceLang, 'auto');
      expect(TranslationConfig.of('comic', 'source').sourceLang, 'auto');
    },
  );

  testWidgets(
    'restoring an individual control updates its value and source label',
    (tester) async {
      appdata.settings['enablePageAnimation'] = true;
      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setDeviceReaderSetting('enablePageAnimation', false);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ReaderSettings())),
      );
      await tester.pumpAndSettle();
      final row = find.widgetWithText(ListTile, 'Page animation');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      final toggle = find.descendant(of: row, matching: find.byType(Switch));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      final reset = find.descendant(
        of: row,
        matching: find.byTooltip('Use inherited value'),
      );
      await tester.runAsync(() async {
        await tester.tap(reset);
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(
        find.descendant(of: row, matching: find.text('Inherited from global')),
        findsOneWidget,
      );
      expect(
        appdata.settings.hasDeviceReaderSetting('enablePageAnimation'),
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

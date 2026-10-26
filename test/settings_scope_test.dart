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

  test('effective writes land in the scope reads come from', () {
    final settings = appdata.settings;
    addTearDown(() => settings['autoScrollSpeed'] = 15);
    settings.setEffectiveReaderSetting('comic', 'source', 'autoScrollSpeed', 4);
    expect(settings['autoScrollSpeed'], 4);

    settings.setEnabledDeviceSpecificSettings(true);
    settings.setEffectiveReaderSetting('comic', 'source', 'autoScrollSpeed', 8);
    expect(settings['autoScrollSpeed'], 4);
    expect(settings.getDeviceReaderSetting('autoScrollSpeed'), 8);

    settings.setEnabledComicSpecificSettings('comic', 'source', true);
    settings.setEffectiveReaderSetting(
      'comic',
      'source',
      'autoScrollSpeed',
      20,
    );
    expect(settings.getDeviceReaderSetting('autoScrollSpeed'), 8);
    expect(settings.getReaderSetting('comic', 'source', 'autoScrollSpeed'), 20);
    expect(settings.getReaderSetting('other', 'source', 'autoScrollSpeed'), 8);
  });

  testWidgets('scroll mode swaps the turning interval for a scroll speed', (
    tester,
  ) async {
    addTearDown(() => appdata.settings['autoPageTurningMode'] = 'page');
    appdata.settings['autoPageTurningMode'] = 'scroll';
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ReaderSettings())),
    );
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Auto scroll speed'),
      200,
      scrollable: scrollable,
    );
    expect(find.text('Auto page turning mode'), findsOneWidget);
    expect(
      find.text('Auto page turning interval', skipOffstage: false),
      findsNothing,
    );

    // Gallery pages can't scroll: back to the interval, no mode choice.
    appdata.settings['readerMode'] = 'galleryLeftToRight';
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ReaderSettings())),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Auto page turning interval'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Auto page turning mode', skipOffstage: false),
      findsNothing,
    );
    expect(find.text('Auto scroll speed', skipOffstage: false), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}

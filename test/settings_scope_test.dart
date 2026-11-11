import 'dart:async';
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
    appdata.settings['adaptiveReading'] = false;
    appdata.settings['showChapterComments'] = true;
  });

  for (final scope in ['global', 'device', 'comic']) {
    testWidgets('manual mode disables adaptive reading only in $scope scope', (
      tester,
    ) async {
      appdata.settings['adaptiveReading'] = true;
      if (scope == 'device') {
        appdata.settings.setEnabledDeviceSpecificSettings(true);
      } else if (scope == 'comic') {
        appdata.settings.setEnabledComicSpecificSettings(
          'comic',
          'source',
          true,
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderSettings(
              comicId: scope == 'comic' ? 'comic' : null,
              comicSource: scope == 'comic' ? 'source' : null,
              section: 'Page layout',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final mode = find.byWidgetPredicate(
        (widget) =>
            widget is SelectSetting && widget.settingKey == 'readerMode',
      );
      await tester.ensureVisible(mode);
      await tester.tap(mode);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gallery (Right to Left)').last);
      await tester.pumpAndSettle();
      var saved = false;
      unawaited(appdata.saveData(false).then((_) => saved = true));
      for (var i = 0; i < 100 && !saved; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(saved, isTrue);
      expect(
        appdata.settings.getReaderSetting('comic', 'source', 'adaptiveReading'),
        isFalse,
      );
      expect(
        appdata.settings.getReaderSetting('comic', 'source', 'readerMode'),
        'galleryRightToLeft',
      );
      if (scope != 'global') {
        expect(appdata.settings['adaptiveReading'], isTrue);
      }
      expect(tester.takeException(), isNull);
    });
  }

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

  for (final (mode, hasEndSwitch) in [
    ('galleryLeftToRight', true),
    ('galleryRightToLeft', true),
    ('galleryTopToBottom', false),
    ('continuousTopToBottom', false),
    ('continuousLeftToRight', false),
    ('continuousRightToLeft', false),
  ]) {
    testWidgets('chapter-end options follow device mode $mode', (tester) async {
      appdata.settings['readerMode'] = hasEndSwitch
          ? 'continuousTopToBottom'
          : 'galleryLeftToRight';
      appdata.settings.setEnabledDeviceSpecificSettings(true);
      appdata.settings.setDeviceReaderSetting('readerMode', mode);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ReaderSettings(section: 'Display settings')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Show Chapter Comments'), findsOneWidget);
      expect(
        find.text('Show Comments at Chapter End'),
        hasEndSwitch ? findsOneWidget : findsNothing,
      );
    });
  }

  for (final (mode, first) in [
    ('galleryRightToLeft', 'Right half first'),
    ('continuousTopToBottom', 'Right half on top'),
  ]) {
    testWidgets('wide page split option is worded for $mode', (tester) async {
      appdata.settings['readerMode'] = mode;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ReaderSettings(section: 'Page layout')),
        ),
      );
      await tester.pumpAndSettle();
      final rows = tester.widgetList<SelectSetting>(
        find.byWidgetPredicate(
          (w) => w is SelectSetting && w.settingKey == 'splitWidePages',
        ),
      );
      expect(rows, hasLength(1));
      expect(rows.single.optionTranslation['rightFirst'], first);
    });
  }

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

  for (final comic in [false, true]) {
    testWidgets(
      'restoring the ${comic ? 'comic' : 'device'} reading mode calls back and resets gallery layout',
      (tester) async {
        final settings = appdata.settings;
        settings.setEnabledDeviceSpecificSettings(true);
        if (comic) {
          settings.setDeviceReaderSetting(
            'readerMode',
            'continuousTopToBottom',
          );
          settings.setEnabledComicSpecificSettings('comic', 'source', true);
        }
        void write(String key, Object value) {
          if (comic) {
            settings.setReaderSetting('comic', 'source', key, value);
          } else {
            settings.setDeviceReaderSetting(key, value);
          }
        }

        dynamic read(String key) => comic
            ? settings.getReaderSetting('comic', 'source', key)
            : settings.getDeviceReaderSetting(key);
        write('readerMode', 'galleryLeftToRight');
        write('readerScreenPicNumberForLandscape', 3);
        write('readerScreenPicNumberForPortrait', 2);
        final changed = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReaderSettings(
                comicId: comic ? 'comic' : null,
                comicSource: comic ? 'source' : null,
                onChanged: changed.add,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final reset = find.byTooltip('Use inherited value');
        expect(reset, findsOneWidget);
        await tester.ensureVisible(reset);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(reset);
          await appdata.saveData(false);
        });
        await tester.pumpAndSettle();
        expect(read('readerMode'), 'continuousTopToBottom');
        expect(read('readerScreenPicNumberForLandscape'), 1);
        expect(read('readerScreenPicNumberForPortrait'), 1);
        expect(changed, [
          'readerScreenPicNumberForLandscape',
          'readerScreenPicNumberForPortrait',
          'readerMode',
        ]);
        expect(
          comic
              ? settings.hasComicReaderSetting('comic', 'source', 'readerMode')
              : settings.hasDeviceReaderSetting('readerMode'),
          isFalse,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('scroll mode swaps the turning interval for a scroll speed', (
    tester,
  ) async {
    addTearDown(() => appdata.settings['autoPageTurningMode'] = 'page');
    appdata.settings['autoPageTurningMode'] = 'scroll';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ReaderSettings(section: 'Auto turning & preload')),
      ),
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
      const MaterialApp(
        home: Scaffold(body: ReaderSettings(section: 'Auto turning & preload')),
      ),
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

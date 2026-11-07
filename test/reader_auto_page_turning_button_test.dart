import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/reader/auto_page_turning_button.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  setUpAll(() async {
    temporary = Directory.systemTemp.createTempSync('reader-auto-turn-button-');
    App.dataPath = temporary.path;
    await AppTranslation.init();
  });
  tearDownAll(() async {
    await appdata.saveData(false);
    temporary.deleteSync(recursive: true);
  });
  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings['deviceId'] = 'auto-turn-test';
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['autoPageTurningMode'] = 'page';
  });

  Widget button({
    String readerMode = 'continuousTopToBottom',
    bool active = false,
    VoidCallback? onPressed,
    VoidCallback? onChanged,
  }) => ReaderAutoPageTurningButton(
    tooltip: 'Auto Page Turning',
    isSelected: active,
    readerMode: readerMode,
    comicId: 'comic',
    comicSource: 'source',
    onPressed: onPressed ?? () {},
    onChanged: onChanged ?? () {},
  );

  Future<void> open(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(alignment: Alignment.bottomLeft, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> longPress(WidgetTester tester) async {
    await tester.longPress(find.byType(IconButton));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'tap toggles, long press only opens, outside tap and Escape close',
    (tester) async {
      var taps = 0;
      var changes = 0;
      await open(
        tester,
        button(onPressed: () => taps++, onChanged: () => changes++),
      );
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(find.byType(MenuItemButton), findsNothing);
      await longPress(tester);
      expect(taps, 1);
      expect(changes, 0);
      expect(find.text('Turn pages'), findsOneWidget);
      expect(find.text('Scroll'), findsOneWidget);
      expect(appdata.settings['autoPageTurningMode'], 'page');
      await tester.tapAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      await longPress(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scope in ['global', 'device', 'comic']) {
    testWidgets('selection saves $scope mode and preserves active state', (
      tester,
    ) async {
      if (scope != 'global') {
        appdata.settings.setEnabledDeviceSpecificSettings(true);
      }
      if (scope == 'comic') {
        appdata.settings.setEnabledComicSpecificSettings(
          'comic',
          'source',
          true,
        );
      }
      var changes = 0;
      var toggles = 0;
      await open(
        tester,
        button(
          active: true,
          onPressed: () => toggles++,
          onChanged: () => changes++,
        ),
      );
      await longPress(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Scroll'));
        await tester.pump();
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(changes, 1);
      expect(toggles, 0);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).isSelected,
        isTrue,
      );
      expect(find.byType(MenuItemButton), findsNothing);
      expect(
        appdata.settings.getReaderSetting(
          'comic',
          'source',
          'autoPageTurningMode',
        ),
        'scroll',
      );
      expect(
        appdata.settings['autoPageTurningMode'],
        scope == 'global' ? 'scroll' : 'page',
      );
      expect(
        appdata.settings.getDeviceReaderSetting('autoPageTurningMode'),
        scope == 'comic' ? 'page' : 'scroll',
      );
      expect(
        appdata.settings.hasComicReaderSetting(
          'comic',
          'source',
          'autoPageTurningMode',
        ),
        scope == 'comic',
      );
      expect(
        appdata.settings.hasDeviceReaderSetting('autoPageTurningMode'),
        scope == 'device',
      );
      await longPress(tester);
      final selected = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Scroll'),
      );
      expect(selected.trailingIcon, isA<Icon>());
      await tester.tap(find.text('Scroll'));
      await tester.pumpAndSettle();
      expect(changes, 1);
      await longPress(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Turn pages'));
        await tester.pump();
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(changes, 2);
      expect(
        appdata.settings.getReaderSetting(
          'comic',
          'source',
          'autoPageTurningMode',
        ),
        'page',
      );
      expect(toggles, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'gallery disables scrolling and displays the effective page mode',
    (tester) async {
      appdata.settings['autoPageTurningMode'] = 'scroll';
      await open(tester, button(readerMode: 'galleryLeftToRight'));
      await longPress(tester);
      final scroll = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Scroll'),
      );
      final page = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Turn pages'),
      );
      expect(scroll.onPressed, isNull);
      expect(scroll.trailingIcon, isNull);
      expect(page.trailingIcon, isA<Icon>());
      expect(
        find.text('Scrolling is available in continuous reading modes'),
        findsOneWidget,
      );
      await tester.tap(find.text('Scroll'));
      await tester.pumpAndSettle();
      expect(appdata.settings['autoPageTurningMode'], 'scroll');
      expect(find.byType(MenuItemButton), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('system back closes the popup before leaving the reader', (
    tester,
  ) async {
    await open(tester, button());
    final navigator = Navigator.of(
      tester.element(find.byType(ReaderAutoPageTurningButton)),
    );
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => Scaffold(body: button())),
    );
    await tester.pumpAndSettle();
    await longPress(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MenuItemButton), findsNothing);
    expect(navigator.canPop(), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(navigator.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final key in [LogicalKeyboardKey.space, LogicalKeyboardKey.enter]) {
    testWidgets('menu consumes ${key.keyLabel} before reader shortcuts', (
      tester,
    ) async {
      final readerFocus = FocusNode();
      addTearDown(readerFocus.dispose);
      var readerKeys = 0;
      await open(
        tester,
        KeyboardListener(
          focusNode: readerFocus,
          autofocus: true,
          onKeyEvent: (event) {
            if (event is KeyDownEvent && event.logicalKey == key) readerKeys++;
          },
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) =>
                    Align(alignment: Alignment.bottomLeft, child: button()),
              ),
            ],
          ),
        ),
      );
      await longPress(tester);
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(find.byType(MenuItemButton), findsNothing);
      expect(readerKeys, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets('popup fits a narrow screen with enlarged text in $locale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      appdata.settings['language'] = locale;
      await open(tester, button(readerMode: 'galleryLeftToRight'));
      await longPress(tester);
      expect(find.text('Auto page turning mode'.tl), findsOneWidget);
      final bounds = tester.getRect(
        find.widgetWithText(MenuItemButton, 'Scroll'.tl),
      );
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(320));
      expect(bounds.bottom, lessThanOrEqualTo(568));
      expect(tester.takeException(), isNull);
    });
  }
}

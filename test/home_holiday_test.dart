import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/holiday_card.dart';
import 'package:venera/components/holiday_decorations.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late DateTime now;
  late Directory dataDir;
  final card = find.byType(HolidayCard);
  final entry = find.byTooltip('Open holiday card');
  final bank = find.byType(HolidaySnowbank);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    dataDir = Directory.systemTemp.createTempSync('venera-holiday-');
    App.dataPath = dataDir.path;
  });

  setUp(() {
    appdata.settings['holidayEffects'] = true;
    appdata.settings['dismissedHoliday'] = '';
    appdata.settings['searchSources'] = <String>[];
    appdata.settings['homeSections'] = [
      for (final section in kHomeSections) {'id': section.id, 'visible': false},
    ];
  });

  tearDownAll(() => dataDir.deleteSync(recursive: true));

  Future<void> home(WidgetTester tester, {double width = 390}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 800);
    addTearDown(tester.view.reset);
    final navigator = GlobalKey<NavigatorState>();
    App.mainNavigatorKey = navigator;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: NaviPane(
          navigatorKey: navigator,
          observer: NaviObserver(),
          paneItems: [
            PaneItemEntry(
              label: 'Home',
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
            ),
          ],
          paneActions: const [],
          pageBuilder: (_) => HomePage(now: () => now),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openCard(WidgetTester tester) async {
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(card, findsOneWidget);
  }

  testWidgets(
    'Christmas arrives and expires on screen without shifting the toolbar',
    (tester) async {
      now = DateTime(2026, 12, 23, 23, 59, 59);
      await home(tester, width: 320);
      final field = find.byType(AppSearchField);
      final edit = find.byTooltip('Edit Home');
      final originalField = tester.getRect(field);
      final originalEdit = tester.getRect(edit);
      expect(entry, findsNothing);
      now = DateTime(2026, 12, 24);
      await tester.pump(const Duration(seconds: 1));
      expect(entry, findsOneWidget);
      expect(bank, findsOneWidget);
      expect(tester.getRect(field), originalField);
      expect(tester.getRect(edit), originalEdit);
      expect(tester.getBottomLeft(bank).dy, 800);

      await tester.tap(edit);
      await tester.pump();
      expect(find.text('Done'), findsOneWidget);
      final searchHit = tester.getTopLeft(field) + const Offset(65, 4);
      await tester.tapAt(searchHit);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(SearchPage), findsOneWidget);
      App.mainNavigatorKey!.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      now = DateTime(2026, 12, 25, 23, 59, 55);
      await openCard(tester);
      expect(find.text('Merry Christmas'), findsOneWidget);
      now = DateTime(2026, 12, 25, 23, 59, 59);
      await tester.pump(const Duration(seconds: 4));
      expect(card, findsOneWidget);
      now = DateTime(2026, 12, 26);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(card, findsNothing);
      expect(entry, findsNothing);
      expect(bank, findsNothing);
      expect(find.text('Done'), findsOneWidget);
    },
  );

  testWidgets(
    'ticket keeps the incoming year at midnight, and expiry preserves other routes',
    (tester) async {
      now = DateTime(2026, 12, 31, 23, 59, 59);
      await home(tester);
      await openCard(tester);
      expect(tester.widget<HolidayCard>(card).year, 2027);
      expect(bank, findsNothing);
      now = DateTime(2027, 1, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<HolidayCard>(card).year, 2027);

      final navigator = App.rootNavigatorKey.currentState!;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Reading')),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = DateTime(2027, 1, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Reading'), findsOneWidget);
      expect(find.byType(HolidayCard, skipOffstage: false), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(entry, findsNothing);
      now = DateTime(2027, 12, 31);
      await tester.pump(const Duration(minutes: 1));
      await openCard(tester);
      expect(tester.widget<HolidayCard>(card).year, 2028);
      await tester.tap(find.text('Back to home'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(entry, findsOneWidget);
    },
  );

  testWidgets(
    'dismissing one occurrence and disabling all holidays survive reopening',
    (tester) async {
      now = DateTime(2026, 12, 31);
      await home(tester, width: 1080);
      await openCard(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('Turn off effects for this holiday'));
        await appdata.saveData(false);
      });
      await tester.pump();
      expect(entry, findsNothing);
      expect(card, findsNothing);
      final settingsFile = File('${dataDir.path}/appdata.json');
      final saved = jsonDecode(settingsFile.readAsStringSync())['settings'];
      expect(saved['dismissedHoliday'], 'newYear-2027');
      await tester.pumpWidget(const SizedBox.shrink());
      now = DateTime(2027, 1, 1);
      await home(tester);
      expect(entry, findsNothing);
      now = DateTime(2027, 12, 31);
      await tester.pump(const Duration(minutes: 1));
      await openCard(tester);
      expect(tester.widget<HolidayCard>(card).year, 2028);
      appdata.settings['holidayEffects'] = false;
      await tester.runAsync(() => appdata.saveData(false));
      await tester.pump();
      expect(card, findsNothing);
      expect(entry, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      final disabled = jsonDecode(settingsFile.readAsStringSync())['settings'];
      expect(disabled['holidayEffects'], false);
      await home(tester);
      expect(entry, findsNothing);
      appdata.settings['holidayEffects'] = true;
      await tester.pump();
      expect(entry, findsOneWidget);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/main_page.dart';
import 'package:venera/pages/tasks_page.dart';
import 'package:venera/utils/handle_notification_route.dart';
import 'package:venera/utils/translations.dart';

Future<GlobalKey<NavigatorState>> _pumpMainPage(WidgetTester tester) async {
  final mainNavigatorKey = GlobalKey<NavigatorState>();
  App.mainNavigatorKey = mainNavigatorKey;
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: Navigator(
        key: mainNavigatorKey,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('main-home')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return mainNavigatorKey;
}

class _EntryA extends StatelessWidget {
  const _EntryA();

  @override
  Widget build(BuildContext context) => const Text('entry-a');
}

class _EntryB extends StatelessWidget {
  const _EntryB();

  @override
  Widget build(BuildContext context) => const Text('entry-b');
}

void _pushRoot(String label) {
  App.rootNavigatorKey.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(label))),
  );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  tearDown(() {
    App.mainNavigatorKey = null;
    AuthPage.isActive = false;
  });

  test('download notifications open the queue, or the library once done', () {
    // Route strings are shared with the Android and HarmonyOS notifications.
    expect(pageForRoute('downloading'), isA<DownloadingPage>());
    expect(pageForRoute('local'), isA<LocalComicsPage>());
    expect(pageForRoute('unknown'), isNull);
  });

  testWidgets(
    'notification routes stay inside the safe-area navigator (#168)',
    (tester) async {
      final mainNavigatorKey = await _pumpMainPage(tester);

      await openNotificationRoute('tasks');
      await tester.pumpAndSettle();

      expect(find.byType(TasksPage), findsOneWidget);
      expect(mainNavigatorKey.currentState!.canPop(), isTrue);
      expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    },
  );

  testWidgets('a page over the main navigator is closed first', (
    tester,
  ) async {
    final mainNavigatorKey = await _pumpMainPage(tester);
    _pushRoot('reader');
    await tester.pumpAndSettle();

    await openNotificationRoute('tasks');
    await tester.pumpAndSettle();

    expect(find.text('reader'), findsNothing);
    expect(find.byType(TasksPage), findsOneWidget);
    expect(mainNavigatorKey.currentState!.canPop(), isTrue);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('a cold-start tap waits for the main navigator', (tester) async {
    await tester.pumpWidget(
      MaterialApp(navigatorKey: App.rootNavigatorKey, home: const Text('init')),
    );

    var done = false;
    openNotificationRoute('tasks').then((_) => done = true);
    // Longer than the old one-shot 200ms wait that dropped the tap.
    await tester.pump(const Duration(seconds: 1));
    expect(done, isFalse);

    await _pumpMainPage(tester);
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(find.byType(TasksPage), findsOneWidget);
  });

  testWidgets('a tap behind the lock screen waits for unlock', (tester) async {
    await _pumpMainPage(tester);
    AuthPage.isActive = true;
    _pushRoot('lock');
    await tester.pumpAndSettle();

    var done = false;
    openNotificationRoute('tasks').then((_) => done = true);
    await tester.pump(const Duration(seconds: 1));
    expect(done, isFalse);
    expect(find.text('lock'), findsOneWidget);

    App.rootNavigatorKey.currentState!.pop();
    AuthPage.isActive = false;
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(find.byType(TasksPage), findsOneWidget);
  });

  testWidgets('a repeated tap does not stack the same page twice', (
    tester,
  ) async {
    final mainNavigatorKey = await _pumpMainPage(tester);

    await openNotificationRoute('tasks');
    await tester.pumpAndSettle();
    await openNotificationRoute('tasks');
    await tester.pumpAndSettle();

    mainNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(mainNavigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('entry pages sit right above the main page, one copy each', (
    tester,
  ) async {
    final mainNavigatorKey = await _pumpMainPage(tester);
    final navigator = mainNavigatorKey.currentState!;

    showEntryPage(navigator, const _EntryA());
    await tester.pumpAndSettle();
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => const Text('details')),
    );
    await tester.pumpAndSettle();
    // The open copy comes back and what was opened from it closes.
    showEntryPage(navigator, const _EntryA());
    await tester.pumpAndSettle();
    expect(find.text('details'), findsNothing);
    expect(find.text('entry-a'), findsOneWidget);

    // Another entry page replaces it instead of stacking on top.
    showEntryPage(navigator, const _EntryB());
    await tester.pumpAndSettle();
    expect(find.text('entry-b'), findsOneWidget);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('main-home'), findsOneWidget);
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('the favorites shortcut switches to the favorites tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final mainNavigatorKey = GlobalKey<NavigatorState>();
    App.mainNavigatorKey = mainNavigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: NaviPane(
          paneItems: [
            for (final label in ['Home', 'Favorites'])
              PaneItemEntry(
                label: label,
                icon: Icons.circle_outlined,
                activeIcon: Icons.circle,
              ),
          ],
          paneActions: const [],
          pageBuilder: (index) => Text('tab-$index'),
          observer: NaviObserver(),
          navigatorKey: mainNavigatorKey,
        ),
      ),
    );
    await tester.pumpAndSettle();
    mainNavigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('details')),
    );
    _pushRoot('reader');
    await tester.pumpAndSettle();

    await openNotificationRoute('favorites');
    await tester.pumpAndSettle();

    expect(find.text('tab-${MainPage.favoritesIndex}'), findsOneWidget);
    expect(find.text('details'), findsNothing);
    expect(find.text('reader'), findsNothing);
    expect(mainNavigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('only the latest of several waiting taps navigates', (
    tester,
  ) async {
    final mainNavigatorKey = await _pumpMainPage(tester);
    AuthPage.isActive = true;

    final first = openNotificationRoute('tasks');
    final second = openNotificationRoute('tasks');
    await tester.pump(const Duration(milliseconds: 300));
    AuthPage.isActive = false;
    await tester.pumpAndSettle();
    await first;
    await second;

    mainNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(mainNavigatorKey.currentState!.canPop(), isFalse);
  });
}

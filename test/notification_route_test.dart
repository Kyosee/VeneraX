import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/auth_page.dart';
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

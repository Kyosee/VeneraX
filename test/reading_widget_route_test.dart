import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/reading_widget_route.dart';
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
  late Directory directory;
  late String originalDataPath;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    directory = Directory.systemTemp.createTempSync('venera-widget-routes-');
    originalDataPath = App.dataPath;
    App.dataPath = directory.path;
    await appdata.init();
    await LocalFavoritesManager().init();
  });

  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings[FollowUpdateScope.allFoldersKey] = true;
    appdata.settings[FollowUpdateScope.foldersKey] = <String>[];
    AuthPage.isActive = false;
  });

  tearDown(() {
    App.mainNavigatorKey = null;
    AuthPage.isActive = false;
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    App.dataPath = originalDataPath;
    directory.deleteSync(recursive: true);
  });

  testWidgets('a widget tap waits behind the lock until unlock', (
    tester,
  ) async {
    final mainNavigatorKey = await _pumpMainPage(tester);
    AuthPage.isActive = true;
    _pushRoot('lock');
    await tester.pumpAndSettle();

    bool? handled;
    final navigation = handleReadingWidgetLink(
      Uri.parse('venerax://reading-widget/following'),
    ).then((value) => handled = value);
    await tester.pump(const Duration(seconds: 1));

    expect(handled, isNull);
    expect(find.text('lock'), findsOneWidget);
    expect(find.byType(FollowUpdatesPage, skipOffstage: false), findsNothing);
    expect(mainNavigatorKey.currentState!.canPop(), isFalse);

    App.rootNavigatorKey.currentState!.pop();
    AuthPage.isActive = false;
    await tester.pumpAndSettle();
    await navigation;

    expect(handled, isTrue);
    expect(find.byType(FollowUpdatesPage), findsOneWidget);
    expect(mainNavigatorKey.currentState!.canPop(), isTrue);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('following and updates headers open their respective lists', (
    tester,
  ) async {
    final mainNavigatorKey = await _pumpMainPage(tester);

    expect(
      await handleReadingWidgetLink(
        Uri.parse('venerax://reading-widget/following'),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<FollowUpdatesPage>(find.byType(FollowUpdatesPage)).showAll,
      isTrue,
    );
    expect(find.text('No comics'), findsOneWidget);
    expect(find.byType(TabBarView), findsNothing);

    mainNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(
      await handleReadingWidgetLink(
        Uri.parse('venerax://reading-widget/updates'),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<FollowUpdatesPage>(find.byType(FollowUpdatesPage)).showAll,
      isFalse,
    );
    expect(find.text('No updates found'), findsOneWidget);
    expect(find.byType(TabBarView), findsOneWidget);
    expect(mainNavigatorKey.currentState!.canPop(), isTrue);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
  });

  testWidgets('a widget tap removes the root reader and pushes inside main', (
    tester,
  ) async {
    final mainNavigatorKey = await _pumpMainPage(tester);
    _pushRoot('reader');
    await tester.pumpAndSettle();

    expect(
      await handleReadingWidgetLink(
        Uri.parse('venerax://reading-widget/updates'),
      ),
      isTrue,
    );
    await tester.pumpAndSettle();

    expect(find.text('reader', skipOffstage: false), findsNothing);
    expect(find.byType(FollowUpdatesPage), findsOneWidget);
    expect(mainNavigatorKey.currentState!.canPop(), isTrue);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);

    mainNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('main-home'), findsOneWidget);
    expect(mainNavigatorKey.currentState!.canPop(), isFalse);
  });
}

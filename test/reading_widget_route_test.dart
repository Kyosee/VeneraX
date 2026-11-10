import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/reading_widget.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/reading_widget_route.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'reading_widget_route_test';

ComicSource _source(LoadComicFunc loadDetails) => ComicSource(
  'Widget route test',
  _sourceKey,
  null,
  null,
  null,
  null,
  const [],
  null,
  null,
  loadDetails,
  null,
  null,
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

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
    await HistoryManager().init();
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
    HistoryManager().close();
    App.dataPath = originalDataPath;
    directory.deleteSync(recursive: true);
  });

  testWidgets('an online comic widget opens the reader above the main shell', (
    tester,
  ) async {
    // Keep details pending so navigation is tested without reader image IO.
    final details = Completer<Res<ComicDetails>>();
    final requestedIds = <String>[];
    ComicSourceManager().add(
      _source((id) {
        requestedIds.add(id);
        return details.future;
      }),
    );
    addTearDown(() => ComicSourceManager().remove(_sourceKey));
    final history = History.fromMap({
      'id': 'online-comic',
      'type': _sourceKey.hashCode,
      'title': 'Online comic',
      'ep': 6,
      'page': 29,
    });
    HistoryManager().addHistory(history);
    addTearDown(() => HistoryManager().remove(history.id, history.type));
    final mainNavigatorKey = await _pumpMainPage(tester);

    expect(
      await handleReadingWidgetLink(Uri.parse(readingWidgetComicUri(history))),
      isTrue,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final reader = find.byType(ReaderWithLoading);
    expect(reader, findsOneWidget);
    expect(requestedIds, ['online-comic']);
    expect(
      ModalRoute.of(tester.element(reader))!.navigator,
      same(App.rootNavigatorKey.currentState),
    );
    expect(App.rootNavigatorKey.currentState!.canPop(), isTrue);
    expect(mainNavigatorKey.currentState!.canPop(), isFalse);

    App.rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(ReaderWithLoading, skipOffstage: false), findsNothing);
    expect(find.text('main-home'), findsOneWidget);
    expect(mainNavigatorKey.currentState!.canPop(), isFalse);
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

  testWidgets(
    'a background widget tap waits for foreground before navigating',
    (tester) async {
      final mainNavigatorKey = await _pumpMainPage(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      bool? handled;
      final navigation = handleReadingWidgetLink(
        Uri.parse('venerax://reading-widget/following'),
      ).then((value) => handled = value);
      await tester.pump(const Duration(milliseconds: 200));
      expect(handled, isNull);
      expect(mainNavigatorKey.currentState!.canPop(), isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await navigation;
      expect(handled, isTrue);
      expect(find.byType(FollowUpdatesPage), findsOneWidget);
    },
  );

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

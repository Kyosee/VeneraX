import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/history_tasks.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/tasks_page.dart';
import 'package:venera/utils/translations.dart';

const _sourceKey = 'favorite_refresh_test';
const _folder = 'Reading';

class _Source extends Fake implements ComicSource {
  _Source(this.loadComicInfo);

  @override
  final LoadComicFunc loadComicInfo;
  @override
  String get key => _sourceKey;
  @override
  String get name => 'Test source';
  @override
  String get filePath => '';
  @override
  FavoriteData? get favoriteData => null;
  @override
  bool get enableTagsTranslate => false;
}

Res<ComicDetails> _response(String id) => Res(
  ComicDetails.fromJson({
    'comicId': id,
    'sourceKey': _sourceKey,
    'title': 'New $id',
    'cover': 'new-cover',
    'tags': {
      'author': ['New author'],
      'genre': ['Adventure'],
    },
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final favorites = LocalFavoritesManager();
  final type = ComicType.fromKey(_sourceKey);
  late HistoryRefreshTaskManager tasks;
  late Directory temp;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('favorite-refresh-task-');
    App.dataPath = temp.path;
    App.cachePath = temp.path;
    await appdata.init();
    await AppTranslation.init();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await JsEngine().init();
      await ComicSourceManager().init();
      await LocalManager().init();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
    await HistoryManager().init();
    await favorites.init();
    appdata.settings['language'] = 'en-US';
    tasks = HistoryRefreshTaskManager.instance;
  });

  setUp(() {
    favorites.createFolder(_folder);
  });

  tearDown(() async {
    ComicSourceManager().remove(_sourceKey);
    favorites.deleteFolder(_folder);
    tasks.clearHistory();
    await appdata.saveData(false);
  });

  tearDownAll(() {
    favorites.close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    App.mainNavigatorKey = null;
    temp.deleteSync(recursive: true);
  });

  void add(String id, {ComicType? comicType}) => favorites.addComic(
    _folder,
    FavoriteItem(
      id: id,
      name: 'Old $id',
      type: comicType ?? type,
      coverPath: 'file://${File('assets/app_icon.png').absolute.path}',
      author: 'Old author',
      tags: const [],
      favoriteTime: DateTime(2024),
    ),
  );

  Future<void> finished(HistoryRefreshTask task) async {
    final done = Completer<void>();
    void check() {
      if (task.finishedAt != null && !done.isCompleted) done.complete();
    }

    tasks.addListener(check);
    try {
      check();
      await done.future.timeout(const Duration(seconds: 5));
    } finally {
      tasks.removeListener(check);
    }
  }

  test(
    'repeated starts share a task and cancel discards the late response',
    () async {
      final started = Completer<void>();
      final response = Completer<Res<ComicDetails>>();
      final requested = <String>[];
      ComicSourceManager().add(
        _Source((id) async {
          requested.add(id);
          if (requested.length == 4) started.complete();
          return response.future;
        }),
      );
      for (var i = 0; i < 5; i++) {
        add('book$i');
      }
      final task = tasks.startFavoriteFolder(_folder);
      await started.future.timeout(const Duration(seconds: 5));
      expect(tasks.startFavoriteFolder(_folder), same(task));
      tasks.cancel(task.id);
      expect(tasks.currentTasks, isEmpty);
      expect(
        tasks.historyTasks.single.status,
        HistoryRefreshTaskStatus.canceled,
      );
      response.complete(_response(requested.first));
      await Future<void>.delayed(Duration.zero);
      expect(requested, hasLength(4));
      expect(task.checked, 0);
      for (final item in favorites.getFolderComics(_folder)) {
        expect(item.name, 'Old ${item.id}');
      }
    },
  );

  test('an empty folder finishes at full progress', () async {
    final task = tasks.startFavoriteFolder(_folder);
    await finished(task);
    expect(task.status, HistoryRefreshTaskStatus.completed);
    expect(task.total, 0);
    expect(task.progress, 1);
  });

  test('retries failures and counts local comics as skipped', () async {
    final requests = <String, int>{};
    ComicSourceManager().add(
      _Source((id) async {
        final attempt = requests.update(
          id,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
        if (id == 'failed' || attempt == 1) return const Res.error('offline');
        return _response(id);
      }),
    );
    add('retry');
    add('failed');
    add('local', comicType: ComicType.local);
    final domain = DomainDatabase();
    await domain.init(temp.path);
    addTearDown(domain.close);
    final repository = ComicStateRepository(domain: domain);
    final comicId = repository.mirrorComic(
      favorites.getComic(_folder, 'retry', type),
    );
    domain.ensureWorkForComic(comicId: comicId);
    final task = tasks.startFavoriteFolder(_folder);
    await finished(task);
    expect(requests, {'retry': 2, 'failed': 3});
    expect(
      [task.total, task.checked, task.success, task.failed, task.skipped],
      [3, 3, 1, 1, 1],
    );
    expect(task.sources[_sourceKey]!.failed, 1);
    expect(task.sources['local']!.skipped, 1);
    expect(task.errors.single, contains('offline'));
    final saved = favorites.getComic(_folder, 'retry', type);
    expect(saved.name, 'New retry');
    repository.mirrorComic(saved);
    expect(repository.displayInfoFor(saved).title, 'New retry');
    expect(saved.coverPath, 'new-cover');
    expect(saved.author, 'New author');
    expect(saved.tags, ['genre:Adventure']);
    expect(saved.time, '2024-01-01 00:00:00');
    expect(favorites.getComic(_folder, 'failed', type).name, 'Old failed');
    final entry = appdata.implicitData['history_refresh_task_history'].single;
    expect(HistoryRefreshTask.fromJson(entry).favoriteFolder, _folder);
    expect(
      HistoryRefreshTask.fromJson(
        {...entry}..remove('favoriteFolder'),
      ).favoriteFolder,
      isNull,
    );
  });

  testWidgets(
    'the folder menu backgrounds the update and Tasks shows its result',
    (tester) async {
      final started = Completer<void>();
      final response = Completer<Res<ComicDetails>>();
      ComicSourceManager().add(
        _Source((_) {
          started.complete();
          return response.future;
        }),
      );
      add('one');
      appdata.implicitData['favoriteFolder'] = {
        'name': _folder,
        'isNetwork': false,
      };
      App.mainNavigatorKey = App.rootNavigatorKey;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const Scaffold(body: FavoritesPage()),
        ),
      );
      await tester.pump();
      final menu = find.byWidgetPredicate(
        (widget) =>
            widget is MenuButton &&
            widget.entries.any((entry) => entry.text == 'Update Comics Info'),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update Comics Info'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Let isolate and file IO complete between simulated frames.
      Future<void> pumpUntil(bool Function() ready) async {
        final elapsed = Stopwatch()..start();
        while (!ready() && elapsed.elapsed < const Duration(seconds: 5)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(ready(), isTrue);
      }

      await pumpUntil(() => started.isCompleted);
      expect(find.text('0/1'), findsOneWidget);
      await tester.tap(find.text('Background'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Background'), findsNothing);
      await tester.pumpWidget(const MaterialApp(home: TasksPage()));
      await tester.pump();
      expect(find.text('Current (1)'), findsOneWidget);
      expect(find.text('Update Comics Info'), findsOneWidget);
      final task = tasks.currentTasks.single;
      response.complete(_response('one'));
      await pumpUntil(() => !task.isRunning);
      expect(task.status, HistoryRefreshTaskStatus.completed);
      expect(favorites.getComic(_folder, 'one', type).name, 'New one');
      expect(find.text('Current (0)'), findsOneWidget);
      await tester.tap(find.text('History (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Update Comics Info'), findsOneWidget);
      expect(find.textContaining(_folder), findsOneWidget);
      expect(tester.takeException(), isNull);
      var writesFinished = false;
      unawaited(appdata.saveData(false).then((_) => writesFinished = true));
      await pumpUntil(() => writesFinished);
    },
  );
}

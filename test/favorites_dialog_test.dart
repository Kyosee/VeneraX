import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

const _comic = Comic(
  'A comic to keep',
  '',
  'favorite-dialog-comic',
  null,
  null,
  '',
  'favorite_dialog_test',
  null,
  null,
);

class _FavoriteSource implements ComicSource {
  _FavoriteSource({
    required this.favoriteData,
    this.loadComicInfo,
    this.isLogged = true,
  });

  @override
  final FavoriteData favoriteData;
  @override
  final LoadComicFunc? loadComicInfo;
  @override
  final bool isLogged;
  @override
  String get key => _comic.sourceKey;
  @override
  String get name => 'Cloud source';
  @override
  String get filePath => '';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FavoriteData _networkFavorites({
  Future<Res<Map<String, String>>> Function([String? comicId])? loadFolders,
  required AddOrDelFavFunc change,
  bool singleFolder = false,
}) => FavoriteData(
  key: _comic.sourceKey,
  title: 'Cloud favorites',
  multiFolder: loadFolders != null,
  loadComic: null,
  loadNext: null,
  loadFolders: loadFolders,
  addOrDelFavorite: change,
  singleFolderForSingleComic: singleFolder,
);

void main() {
  late Directory directory;
  late String originalDataPath;
  late String originalCachePath;
  final manager = LocalFavoritesManager();
  final comicType = ComicType.fromKey(_comic.sourceKey);

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    directory = Directory.systemTemp.createTempSync('venera-favorite-dialog-');
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    await appdata.init();
    await manager.init();
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    manager.close();
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    App.mainNavigatorKey = null;
    directory.deleteSync(recursive: true);
  });

  setUp(() {
    ComicSourceManager().remove(_comic.sourceKey);
    appdata.settings['language'] = 'en-US';
    appdata.settings['localFavoritesFirst'] = true;
    appdata.settings['autoCloseFavoritePanel'] = false;
    appdata.settings['quickFavorite'] = null;
    for (final folder in manager.folderNames) {
      if (manager.existsFolder(folder)) manager.deleteFolder(folder);
    }
    manager.createFolder('Alpha');
    manager.createFolder('Beta');
  });

  tearDown(() => ComicSourceManager().remove(_comic.sourceKey));

  Future<void> openDialog(
    WidgetTester tester, {
    Comic comic = _comic,
    Size size = const Size(390, 780),
    double textScale = 1,
    EdgeInsets padding = EdgeInsets.zero,
    List<Comic>? comics,
    WidgetBuilder? panel,
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    App.mainNavigatorKey = App.rootNavigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            padding: padding,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: TextButton(
            onPressed: () => panel == null
                ? addFavorite(comics ?? [comic])
                : showDialog(context: App.rootContext, builder: panel),
            child: const Text('Open favorites'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open favorites'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Finder folder(String name) => find.widgetWithText(CheckboxListTile, name);

  bool isSelected(WidgetTester tester, String name) =>
      tester.widget<CheckboxListTile>(folder(name)).value!;

  Future<void> tapFolder(WidgetTester tester, String name) async {
    await tester.ensureVisible(folder(name));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(folder(name));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
  }

  testWidgets('one dialog adds multiple folders and removes only one', (
    tester,
  ) async {
    appdata.settings['autoCloseFavoritePanel'] = true;
    await openDialog(tester);

    expect(folder('Alpha'), findsOneWidget);
    expect(folder('Beta'), findsOneWidget);
    expect(isSelected(tester, 'Alpha'), isFalse);
    await tapFolder(tester, 'Alpha');
    await tapFolder(tester, 'Beta');
    expect(manager.find(_comic.id, comicType), containsAll(['Alpha', 'Beta']));
    expect(isSelected(tester, 'Alpha'), isTrue);
    expect(isSelected(tester, 'Beta'), isTrue);

    await tapFolder(tester, 'Alpha');
    expect(manager.find(_comic.id, comicType), ['Beta']);
    expect(isSelected(tester, 'Alpha'), isFalse);
    expect(isSelected(tester, 'Beta'), isTrue);
    expect(find.text('Done').hitTestable(), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(folder('Beta'), findsNothing);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new folder is selectable without reopening the dialog', (
    tester,
  ) async {
    await openDialog(tester);
    await tester.tap(find.widgetWithText(TextButton, 'New Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Gamma');
    await tester.runAsync(() async {
      await tester.tap(find.text('Create'));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();

    await tapFolder(tester, 'Gamma');
    expect(manager.find(_comic.id, comicType), ['Gamma']);
    expect(find.text('Done').hitTestable(), findsOneWidget);
  });

  testWidgets('network folders keep other selections when one is removed', (
    tester,
  ) async {
    final requests = <(String, String, bool, String?)>[];
    ComicSourceManager().add(
      _FavoriteSource(
        favoriteData: _networkFavorites(
          loadFolders: ([id]) async => const Res(
            {'one': 'Cloud One', 'two': 'Cloud Two'},
            subData: ['one'],
          ),
          change: (id, folder, adding, favoriteId) async {
            requests.add((id, folder, adding, favoriteId));
            return const Res(true);
          },
        ),
      ),
    );
    appdata.settings['autoCloseFavoritePanel'] = true;
    await openDialog(tester);
    expect(isSelected(tester, 'Cloud One'), isTrue);
    expect(isSelected(tester, 'Cloud Two'), isFalse);

    await tapFolder(tester, 'Cloud Two');
    await tapFolder(tester, 'Cloud One');
    expect(isSelected(tester, 'Cloud One'), isFalse);
    expect(isSelected(tester, 'Cloud Two'), isTrue);
    expect(requests, [
      (_comic.id, 'two', true, null),
      (_comic.id, 'one', false, null),
    ]);
    expect(find.text('Done').hitTestable(), findsOneWidget);
  });

  testWidgets('a source can restrict a comic to one network folder', (
    tester,
  ) async {
    ComicSourceManager().add(
      _FavoriteSource(
        favoriteData: _networkFavorites(
          singleFolder: true,
          loadFolders: ([id]) async => const Res(
            {'one': 'Cloud One', 'two': 'Cloud Two'},
            subData: ['one'],
          ),
          change: (_, __, ___, ____) async => const Res(true),
        ),
      ),
    );
    appdata.settings['localFavoritesFirst'] = false;
    await openDialog(tester);
    expect(
      tester.getTopLeft(folder('Cloud One')).dy,
      lessThan(tester.getTopLeft(folder('Alpha')).dy),
    );
    expect(
      tester.widget<CheckboxListTile>(folder('Cloud Two')).onChanged,
      isNull,
    );
    await tapFolder(tester, 'Cloud One');
    expect(
      tester.widget<CheckboxListTile>(folder('Cloud Two')).onChanged,
      isNotNull,
    );
    await tapFolder(tester, 'Cloud Two');
    expect(isSelected(tester, 'Cloud Two'), isTrue);
    expect(
      tester.widget<CheckboxListTile>(folder('Cloud One')).onChanged,
      isNull,
    );
  });

  testWidgets(
    'ungrouped network favorites load state and forward favorite ID',
    (tester) async {
      final requests = <(String, String, bool, String?)>[];
      final comic = Comic.fromJson({
        ..._comic.toJson(),
        'favoriteId': 'saved-record',
      }, _comic.sourceKey);
      ComicSourceManager().add(
        _FavoriteSource(
          loadComicInfo: (id) async => Res(
            ComicDetails.fromJson({
              'title': _comic.title,
              'cover': '',
              'sourceKey': _comic.sourceKey,
              'comicId': id,
              'tags': <String, List<String>>{},
              'isFavorite': true,
            }),
          ),
          favoriteData: _networkFavorites(
            change: (id, folder, adding, favoriteId) async {
              requests.add((id, folder, adding, favoriteId));
              return const Res(true);
            },
          ),
        ),
      );
      await openDialog(tester, comic: comic);
      expect(isSelected(tester, 'Cloud source'), isTrue);
      await tapFolder(tester, 'Cloud source');
      expect(isSelected(tester, 'Cloud source'), isFalse);
      await tapFolder(tester, 'Cloud source');
      expect(isSelected(tester, 'Cloud source'), isTrue);
      expect(requests, [
        (_comic.id, '', false, 'saved-record'),
        (_comic.id, '', true, 'saved-record'),
      ]);
    },
  );

  testWidgets(
    'network load errors can retry while local folders remain usable',
    (tester) async {
      var attempts = 0;
      ComicSourceManager().add(
        _FavoriteSource(
          favoriteData: _networkFavorites(
            loadFolders: ([id]) async {
              if (attempts++ == 0) return const Res.error('Offline');
              return const Res({'one': 'Cloud One'}, subData: ['one']);
            },
            change: (_, __, ___, ____) async => const Res(true),
          ),
        ),
      );
      await openDialog(tester);
      expect(find.text('Offline'), findsOneWidget);
      await tapFolder(tester, 'Alpha');
      expect(manager.find(_comic.id, comicType), ['Alpha']);
      await tester.ensureVisible(find.text('Retry'));
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Offline'), findsNothing);
      expect(isSelected(tester, 'Cloud One'), isTrue);
    },
  );

  testWidgets('failed network changes preserve selection and allow retry', (
    tester,
  ) async {
    var attempts = 0;
    ComicSourceManager().add(
      _FavoriteSource(
        favoriteData: _networkFavorites(
          loadFolders: ([id]) async =>
              const Res({'one': 'Cloud One'}, subData: ['one']),
          change: (_, __, ___, ____) async {
            attempts++;
            if (attempts == 1) return const Res.error('Offline');
            if (attempts == 2) throw StateError('Offline');
            return const Res(true);
          },
        ),
      ),
    );
    await openDialog(tester);
    for (var i = 0; i < 2; i++) {
      await tapFolder(tester, 'Cloud One');
      expect(isSelected(tester, 'Cloud One'), isTrue);
      expect(
        tester.widget<CheckboxListTile>(folder('Cloud One')).onChanged,
        isNotNull,
      );
      await tester.pump(const Duration(seconds: 4));
    }
    await tapFolder(tester, 'Cloud One');
    expect(isSelected(tester, 'Cloud One'), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending network changes block duplicates and survive dismissal',
    (tester) async {
      final pending = Completer<Res<bool>>();
      var requests = 0;
      ComicSourceManager().add(
        _FavoriteSource(
          favoriteData: _networkFavorites(
            loadFolders: ([id]) async =>
                const Res({'one': 'Cloud One', 'two': 'Cloud Two'}),
            change: (_, __, ___, ____) {
              requests++;
              return pending.future;
            },
          ),
        ),
      );
      await openDialog(tester);
      await tester.ensureVisible(folder('Cloud One'));
      await tester.tap(folder('Cloud One'));
      await tester.pump();
      expect(
        tester.widget<CheckboxListTile>(folder('Cloud One')).onChanged,
        isNull,
      );
      expect(
        tester.widget<CheckboxListTile>(folder('Cloud Two')).onChanged,
        isNull,
      );
      expect(requests, 1);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      pending.complete(const Res(true));
      await tester.pumpAndSettle();
      expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a folder load can finish after the dialog is dismissed', (
    tester,
  ) async {
    final pending = Completer<Res<Map<String, String>>>();
    ComicSourceManager().add(
      _FavoriteSource(
        favoriteData: _networkFavorites(
          loadFolders: ([id]) => pending.future,
          change: (_, __, ___, ____) async => const Res(true),
        ),
      ),
    );
    await openDialog(tester, settle: false);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    pending.completeError(StateError('Offline'));
    await tester.pumpAndSettle();
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('logged out sources leave local favorites available', (
    tester,
  ) async {
    ComicSourceManager().add(
      _FavoriteSource(
        isLogged: false,
        favoriteData: _networkFavorites(
          loadFolders: ([id]) async => throw StateError('Must not load'),
          change: (_, __, ___, ____) async =>
              throw StateError('Must not change'),
        ),
      ),
    );
    await openDialog(tester);
    expect(find.text('Network Favorites'), findsNothing);
    await tapFolder(tester, 'Beta');
    expect(manager.find(_comic.id, comicType), ['Beta']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the detail list still respects automatic closing', (
    tester,
  ) async {
    appdata.settings['autoCloseFavoritePanel'] = true;
    bool? localFavorite;
    await openDialog(
      tester,
      panel: (_) => Dialog(
        child: SizedBox(
          width: 520,
          height: 600,
          child: ComicFavoriteList(
            cid: _comic.id,
            type: comicType,
            isFavorite: false,
            onFavorite: (local, _) => localFavorite = local,
            favoriteItem: FavoriteItem(
              id: _comic.id,
              name: _comic.title,
              coverPath: '',
              author: '',
              type: comicType,
              tags: const [],
            ),
            comicSource: null,
            hasNetwork: false,
            localFolders: manager.folderNames,
            added: const [],
          ),
        ),
      ),
    );
    await tapFolder(tester, 'Alpha');
    expect(localFavorite, isTrue);
    expect(manager.find(_comic.id, comicType), ['Alpha']);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multiple comics retain the selected local batch destination', (
    tester,
  ) async {
    final other = Comic.fromJson({
      ..._comic.toJson(),
      'id': 'other-comic',
    }, _comic.sourceKey);
    appdata.settings['quickFavorite'] = 'Beta';
    await openDialog(tester, comics: [_comic, other]);
    expect(find.text('Select a folder'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Confirm'));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(manager.find(_comic.id, comicType), ['Beta']);
    expect(manager.find(other.id, comicType), ['Beta']);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    await tester.pump(const Duration(seconds: 4));
  });

  for (final layout in [
    (const Size(320, 480), 1.0),
    (const Size(568, 320), 1.4),
    (const Size(320, 568), 2.5),
    (const Size(1280, 800), 2.0),
  ]) {
    testWidgets('long folder lists fit ${layout.$1} at scale ${layout.$2}', (
      tester,
    ) async {
      const lastFolder = 'A long nested folder name that wraps onto two lines';
      for (var i = 0; i < 20; i++) {
        manager.createFolder('Folder $i');
      }
      manager.createFolder(lastFolder);
      manager.moveFolder('Beta', 'Alpha');
      manager.moveFolder('Folder 0', 'Beta');
      manager.moveFolder(lastFolder, 'Folder 0');
      await openDialog(
        tester,
        size: layout.$1,
        textScale: layout.$2,
        padding: const EdgeInsets.only(top: 24, bottom: 24),
      );
      final done = tester.getRect(find.text('Done'));
      expect(done.bottom, lessThanOrEqualTo(layout.$1.height - 24));
      expect(find.byTooltip('Close').hitTestable(), findsOneWidget);

      await tapFolder(tester, lastFolder);
      expect(manager.find(_comic.id, comicType), [lastFolder]);
      expect(tester.getRect(find.text('Done')), done);
      expect(find.text('Done').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}

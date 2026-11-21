import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/tv_platform.dart';
import 'package:venera/init.dart' show deferredInitCompleter;
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

/// The server only lists and stores bytes. DataSync owns both archive operations.
class _DavFixture {
  final files = <String, List<int>>{};
  final reads = <String>[];
  final writes = <String>[];

  Future<void> serve(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    try {
      if (request.method == 'PUT' && path.endsWith('.venera')) {
        files[path] = await request.fold<List<int>>(
          [],
          (bytes, chunk) => bytes..addAll(chunk),
        );
        writes.add(path);
        response.statusCode = HttpStatus.created;
        return;
      }
      await request.drain<void>();
      if (request.method == 'PROPFIND' && path == '/') {
        final entries = {
          '/': null,
          for (final file in files.entries) file.key: file.value.length,
        };
        response
          ..statusCode = HttpStatus.multiStatus
          ..headers.contentType = ContentType('application', 'xml')
          ..write('<d:multistatus xmlns:d="DAV:">');
        for (final entry in entries.entries) {
          response.write(
            '<d:response><d:href>${entry.key}</d:href><d:propstat><d:prop>'
            '<d:resourcetype>${entry.value == null ? '<d:collection/>' : ''}</d:resourcetype>'
            '<d:getcontentlength>${entry.value ?? 0}</d:getcontentlength>'
            '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
          );
        }
        response.write('</d:multistatus>');
      } else if (request.method == 'GET' && files.containsKey(path)) {
        reads.add(path);
        response
          ..headers.contentType = ContentType.binary
          ..contentLength = files[path]!.length
          ..add(files[path]!);
      } else if (request.method == 'OPTIONS') {
        response.headers.set('DAV', '1');
      } else {
        response.statusCode = HttpStatus.notFound;
      }
    } finally {
      await response.close();
    }
  }
}

const _id = 'shared-42';

Future<FavoriteItem> _installComic(String key) async {
  final source = await ComicSourceParser().createAndParse('''
class FixtureSource extends ComicSource {
  name = "$key";
  key = "$key";
  version = "1.0.0";
  minAppVersion = "0.0.0";
  comic = {};
  search = {};
}''', '$key.js');
  expect(ComicSourceManager().add(source), isTrue);
  return FavoriteItem(
    id: _id,
    type: ComicType.fromKey(key),
    name: 'Title $key',
    author: 'Author $key',
    coverPath: '/cover/$key',
    tags: ['tag,$key', '漫画'],
    authors: ['Author $key', 'Artist $key'],
    status: 'complete',
    updateTimeMeta: '2026-10-31',
    extraMeta: {'edition': key, 'language': 'ja'},
    favoriteTime: DateTime.utc(2026, 10, 31),
  );
}

History _progress(FavoriteItem comic, int group, int page) => History.fromMap({
  'id': comic.id,
  'type': comic.type.value,
  'title': comic.name,
  'subtitle': comic.author,
  'cover': comic.coverPath,
  'time': 1767225600000 + group,
  'chapter_group': group,
  'ep': group + 1,
  'page': page,
  'max_page': page + 9,
  'readEpisode': ['$group-1', '$group-${group + 1}'],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'TV restores a filtered WebDAV backup with per-source history and folder metadata',
    () async {
      enableTvApp();
      final root = await Directory.systemTemp.createTemp('venera-tv-webdav-');
      addTearDown(() => root.delete(recursive: true));
      final data = await Directory('${root.path}/data').create();
      App.dataPath = data.path;
      App.cachePath = (await Directory('${root.path}/cache').create()).path;
      final comics = await Directory('${root.path}/comics').create();
      await File('${data.path}/local_path').writeAsString(comics.path);
      App.isBackgroundTask = true;
      await appdata.init();
      await AppTranslation.init();
      SingleInstanceCookieJar('${data.path}/cookie.db');
      addTearDown(() {
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
      });
      await JsEngine().init();
      addTearDown(JsEngine().dispose);
      await ComicSourceManager().init();
      final history = HistoryManager();
      final favorites = LocalFavoritesManager();
      await history.init();
      addTearDown(history.close);
      await favorites.init();
      addTearDown(favorites.close);
      await App.readLater.init();
      addTearDown(App.readLater.close);
      await LocalManager().init();
      addTearDown(LocalManager().close);
      await App.domain.init(data.path);
      addTearDown(App.domain.close);
      await TranslationStore().init();
      addTearDown(TranslationStore().close);
      if (!deferredInitCompleter.isCompleted) deferredInitCompleter.complete();

      final dav = _DavFixture();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen(dav.serve);
      final config = ['http://127.0.0.1:${server.port}', 'fixture', 'fixture'];
      final sync = DataSync();
      appdata.settings['webdav'] = config;
      appdata.settings['webdavUseProxy'] = false;
      appdata.settings['syncLocalComics'] = false;
      appdata.settings['syncLocalComicImages'] = false;
      appdata.settings['disableSyncFields'] = 'color,@searchHistory';
      appdata.settings['color'] = 'blue';
      appdata.settings['deviceId'] = 'sender';
      appdata.settings['comicTileScale'] = 1.25;
      appdata.settings['readerScrollSpeed'] = 2.5;
      appdata.searchHistory = ['sender-only'];
      final initial = await sync.downloadData();
      expect(initial.errorMessage, isNull);
      expect(appdata.implicitData['hasCompletedInitialSync'], isTrue);

      final first = await _installComic('fixture_a');
      final second = await _installComic('fixture_b');
      final progress = [_progress(first, 2, 7), _progress(second, 4, 11)];
      for (final item in progress) {
        await history.addHistoryAsync(item);
      }
      final folders = {
        'Shared': [first, second],
        'Archived': [second],
      };
      for (final entry in folders.entries) {
        favorites.createFolder(entry.key);
        for (final item in entry.value) {
          expect(favorites.addComic(entry.key, item), isTrue);
        }
      }

      final uploaded = await sync.uploadData(force: true);
      expect(uploaded.errorMessage, isNull);
      final path = dav.writes.single;
      final version = appdata.settings['dataVersion'];
      expect(version, greaterThan(0));
      final archive = ZipDecoder().decodeBytes(dav.files[path]!);
      for (final name in [
        'history.db',
        'local_favorite.db',
        'comic_source/fixture_a.js',
        'comic_source/fixture_b.js',
      ]) {
        expect(archive.findFile(name)?.content, isNotEmpty, reason: name);
      }
      final snapshot =
          jsonDecode(utf8.decode(archive.findFile('appdata.json')!.content))
              as Map;
      final settings = snapshot['settings'] as Map;
      for (final key in ['color', 'deviceId', 'webdav', 'disableSyncFields']) {
        expect(settings.containsKey(key), isFalse, reason: key);
      }
      expect(snapshot.containsKey('searchHistory'), isFalse);
      expect(settings['comicTileScale'], 1.25);
      expect(settings['readerScrollSpeed'], 2.5);

      // Remove sender records before pulling into the simulated receiver.
      for (final item in progress) {
        history.remove(item.id, item.type);
      }
      for (final folder in folders.keys) {
        favorites.deleteFolder(folder);
      }
      expect(history.getAll(), isEmpty);
      expect(folders.keys.where(favorites.existsFolder), isEmpty);
      appdata.settings['deviceId'] = 'receiver';
      appdata.settings['color'] = 'green';
      appdata.searchHistory = ['receiver-only'];
      appdata.settings['readerScrollSpeed'] = 0.5;
      appdata.settings['comicTileScale'] = 0.75;
      appdata.settings['disableSyncFields'] = 'comicTileScale';
      appdata.settings['dataVersion'] = 0;
      await appdata.saveData(false);

      final restored = await sync.downloadData();
      expect(restored.errorMessage, isNull);
      expect(appdata.settings['dataVersion'], version);
      expect(dav.reads, [path]);
      expect(dav.writes, [path]);
      expect(history.getAll(), hasLength(2));
      for (final expected in progress) {
        final item = history.find(_id, expected.type)!;
        expect(
          item.sourceKey,
          expected.type == first.type ? 'fixture_a' : 'fixture_b',
        );
        expect(
          (item.group, item.ep, item.page, item.maxPage),
          (expected.group, expected.ep, expected.page, expected.maxPage),
        );
        expect(item.readEpisode, expected.readEpisode);
        expect(item.time, expected.time);
      }
      for (final entry in folders.entries) {
        expect(
          favorites.getFolderComics(entry.key).map((c) => c.type),
          unorderedEquals(entry.value.map((c) => c.type)),
        );
        for (final expected in entry.value) {
          final item = favorites.getComic(entry.key, _id, expected.type);
          expect(item.toJson(), expected.toJson());
          expect(item.time, expected.time);
        }
      }
      expect(appdata.settings['readerScrollSpeed'], 2.5);
      expect(appdata.settings['comicTileScale'], 0.75);
      expect(appdata.settings['color'], 'green');
      expect(appdata.settings['deviceId'], 'receiver');
      expect(appdata.settings['disableSyncFields'], 'comicTileScale');
      expect(appdata.settings['webdav'], config);
      expect(appdata.searchHistory, ['receiver-only']);
    },
  );
}

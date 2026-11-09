import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/webdav_upload.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

const _sourceKey = 'ohos_backup_probe';
const _sourceName = '鸿蒙备份探针';
const _comicId = 'probe_漫画_1';
const _folder = '备份探针收藏';
const _remotePath = '/probe.venera';
const _cover = 'http://127.0.0.1/probe-cover.png';
const _sourceData = {'probeSetting': '简体中文', 'pageSize': 17};
const _settings = {
  'theme_mode': 'dark',
  'color': 'blue',
  'comicDisplayMode': 'brief',
  'comicTileScale': 1.25,
};
const _searchHistory = ['备份往返', 'Unicode 漫画'];

String _script(String name) =>
    '''
class OhosBackupProbe extends ComicSource {
  name = "$name";
  key = "$_sourceKey";
  version = "1.0.0";
  minAppVersion = "0.0.0";
  url = "http://127.0.0.1/backup-probe.js";
  search = {
    load: async (keyword, options, page) => ({
      comics: [{ id: "$_comicId", title: "备份恢复后的脚本", cover: "$_cover" }],
      maxPage: 1
    })
  };
  comic = {
    loadInfo: async (id) => ({
      title: "备份恢复后的脚本",
      subtitle: "本地自制内容",
      cover: "$_cover",
      tags: {},
      chapters: { chapter_1: "第一章" }
    }),
    loadEp: async (id, ep) => ({ images: ["$_cover"] })
  };
}
''';

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void _same(Object? actual, Object? expected, String field) {
  _check(jsonEncode(actual) == jsonEncode(expected), 'Changed field: $field');
}

History _history({bool changed = false}) => History.fromMap({
  'type': ComicType.fromKey(_sourceKey).value,
  'id': _comicId,
  'title': changed ? 'Changed history' : '历史：鸿蒙漫画',
  'subtitle': '第二卷',
  'cover': _cover,
  'time': 1767225600000,
  'ep': 3,
  'page': changed ? 1 : 7,
  'readEpisode': ['2-1', '2-2', '2-3'],
  'max_page': 19,
  'chapter_group': 2,
});

Map<String, Object?> _historyFields(History history) => {
  'id': history.id,
  'type': history.type.value,
  'title': history.title,
  'subtitle': history.subtitle,
  'cover': history.cover,
  'time': history.time.millisecondsSinceEpoch,
  'ep': history.ep,
  'page': history.page,
  'maxPage': history.maxPage,
  'group': history.group,
  'readEpisode': history.readEpisode.toList()..sort(),
};

FavoriteItem _favorite() => FavoriteItem(
  id: _comicId,
  name: '收藏：鸿蒙漫画',
  author: '测试作者',
  type: ComicType.fromKey(_sourceKey),
  coverPath: _cover,
  tags: ['测试', '含,逗号', 'unicode-漫画'],
  favoriteTime: DateTime.utc(2026, 1, 1),
  authors: ['测试作者', '第二作者'],
  status: '连载中',
  updateTimeMeta: '2026-01-01',
  extraMeta: {'language': 'zh', 'fixture': 'backup'},
);

Future<File> _webdavRoundTrip(
  File archive,
  Directory root,
  void Function(String) record,
) async {
  final expected = await archive.readAsBytes();
  _check(
    expected.length > 4 && expected.length < 8 * 1024 * 1024,
    'Unexpected probe archive size',
  );
  _check(expected[0] == 0x50 && expected[1] == 0x4b, 'Archive is not ZIP');
  final stored = File('${root.path}/server-probe.venera');
  final downloaded = File('${root.path}/downloaded-probe.venera');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final methods = <String, int>{};
  final errors = <String>[];
  final handlers = <Future<void>>{};
  final authorization = 'Basic ${base64Encode(utf8.encode('probe:probe'))}';
  var challenged = false;

  Future<void> serve(HttpRequest request) async {
    try {
      final path = request.uri.path;
      _check(
        !request.uri.hasQuery && (path == '/' || path == _remotePath),
        'Unexpected request path',
      );
      methods.update(request.method, (count) => count + 1, ifAbsent: () => 1);
      if (request.headers.value(HttpHeaders.authorizationHeader) !=
          authorization) {
        await request.drain<void>();
        challenged = true;
        request.response.statusCode = HttpStatus.unauthorized;
        request.response.headers.set(
          HttpHeaders.wwwAuthenticateHeader,
          'Basic realm="venera-probe"',
        );
        return;
      }
      switch (request.method) {
        case 'OPTIONS':
          await request.drain<void>();
          request.response.headers.set('DAV', '1, 2');
          request.response.headers.set('Allow', 'OPTIONS, PUT, GET');
          request.response.statusCode = HttpStatus.ok;
        case 'PUT':
          _check(path == _remotePath, 'Wrong PUT path');
          _check(request.contentLength == expected.length, 'Wrong PUT length');
          final bytes = BytesBuilder(copy: false);
          await for (final chunk in request) {
            _check(
              bytes.length + chunk.length <= expected.length,
              'PUT exceeded the archive size',
            );
            bytes.add(chunk);
          }
          final received = bytes.takeBytes();
          _check(listEquals(received, expected), 'PUT bytes differ');
          await stored.writeAsBytes(received, flush: true);
          request.response.statusCode = HttpStatus.created;
          record('HTTP PUT verified ${received.length} bytes');
        case 'GET':
          _check(
            path == _remotePath && await stored.exists(),
            'Missing upload',
          );
          await request.drain<void>();
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType.binary
            ..contentLength = await stored.length();
          await request.response.addStream(stored.openRead());
          record('HTTP GET sent ${expected.length} bytes');
        default:
          throw StateError('Unexpected method: ${request.method}');
      }
    } catch (error) {
      errors.add(error.toString());
      request.response.statusCode = HttpStatus.internalServerError;
    } finally {
      await request.response.close();
    }
  }

  server.listen((request) {
    final work = serve(request).catchError((Object error) {
      errors.add(error.toString());
    });
    handlers.add(work);
    unawaited(work.then((_) => handlers.remove(work)));
  }, onError: (Object error) => errors.add(error.toString()));
  final client = webdav.newClient(
    'http://127.0.0.1:${server.port}',
    user: 'probe',
    password: 'probe',
    adapter: RHttpAdapter(
      enableProxy: false,
      timeout: const Duration(seconds: 20),
    ),
  )..setReceiveTimeout(20000);
  var uploadProgress = 0;
  var downloadProgress = 0;
  try {
    await writeFileStreamed(
      client,
      archive,
      _remotePath,
      onProgress: (count, total) {
        _check(
          total == expected.length && count <= total,
          'Invalid upload progress',
        );
        uploadProgress = count;
      },
    );
    await client.read2File(
      _remotePath,
      downloaded.path,
      onProgress: (count, total) {
        _check(
          total == expected.length && count <= total,
          'Invalid download progress',
        );
        downloadProgress = count;
      },
    );
    _check(errors.isEmpty, 'Server errors: $errors');
    _check(
      challenged && (methods['OPTIONS'] ?? 0) > 0,
      'The real WebDAV authentication/options flow did not run',
    );
    _check(
      methods['PUT'] == 1 && methods['GET'] == 1,
      'Wrong HTTP request counts',
    );
    _same(uploadProgress, expected.length, 'upload progress');
    _same(downloadProgress, expected.length, 'download progress');
    _check(
      listEquals(await downloaded.readAsBytes(), expected),
      'GET bytes differ',
    );
    record(
      'PASS HTTP: WebDAV + RHttpAdapter, auth, PUT/GET, bytes and progress',
    );
    return downloaded;
  } finally {
    client.c.close(force: true);
    await server.close(force: true);
    await Future.wait(handlers.toList());
  }
}

Future<String> _runBackupProbe(void Function(String) record) async {
  _check(App.isOhos, 'Requires a HarmonyOS device');
  // Refuse an already running application; cached stores may point at user data.
  _check(
    !App.isInitialized &&
        !HistoryManager().isInitialized &&
        !LocalFavoritesManager().isInitialized &&
        !App.readLater.isInitialized &&
        !LocalManager().isInitialized &&
        !App.domain.isInitialized &&
        SingleInstanceCookieJar.instance == null &&
        ComicSource.all().isEmpty,
    'This probe requires a cold standalone entrypoint',
  );
  final temporary = await getTemporaryDirectory();
  final root = await Directory(temporary.path).createTemp('backup_probe_');
  final data = await Directory('${root.path}/data').create();
  final cache = await Directory('${root.path}/cache').create();
  App.dataPath = data.path;
  App.cachePath = cache.path;
  App.isInitialized = true;
  record('ISOLATED ${root.path}');
  late final Map<String, Object> result;

  try {
    appdata.settings['proxy'] = 'direct';
    appdata.settings['enableDnsOverrides'] = false;
    appdata.settings['webdav'] = <String>[];
    appdata.settings['disableSyncFields'] = '';
    appdata.implicitData['webdavAutoSync'] = false;
    await appdata.saveData(false);
    await appdata.init();
    await AppTranslation.init();
    // createInstance() otherwise uses the real application support directory.
    final cookies = SingleInstanceCookieJar('${data.path}/cookie.db');
    _same(cookies.path, '${data.path}/cookie.db', 'cookie isolation');
    await App.domain.init(data.path);
    await nativeInitRhttp();
    await JsEngine().init();
    await ComicSourceManager().init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    await App.readLater.init();
    await LocalManager().init();
    _check(coreDataStoresReady, 'Some isolated stores failed to initialize');
    _check(
      LocalManager().path.startsWith('${data.path}/'),
      'Local storage escaped',
    );

    final source = await ComicSourceParser().createAndParse(
      _script(_sourceName),
      'backup-probe.js',
    );
    _check(ComicSourceManager().add(source), 'Could not register source');
    source.data.addAll(_sourceData);
    await source.saveData();
    for (final setting in _settings.entries) {
      appdata.settings[setting.key] = setting.value;
    }
    appdata.searchHistory = List.of(_searchHistory);
    final expectedHistory = _historyFields(_history());
    await HistoryManager().addHistoryAsync(_history());
    final favorites = LocalFavoritesManager();
    favorites.createFolder(_folder);
    final favorite = _favorite();
    _check(favorites.addComic(_folder, favorite), 'Could not create favorite');
    _same(
      favorites.getComic(_folder, _comicId, favorite.type).tags,
      favorite.tags,
      'favorite tags immediately after insertion',
    );
    final expectedFavorite = favorite.toJson();
    final expectedFavoriteTime = favorite.time;
    cookies.saveFromResponse(Uri.parse(_cover), [
      Cookie('backup_probe', 'fixture-only')..path = '/',
    ]);
    await appdata.saveData(false);
    record(
      'FIXTURE: source, settings, search history, reading position, favorite, cookie',
    );

    final archive = await exportAppData(
      sync: false,
      includeTranslations: false,
    );
    _check(
      archive.path.startsWith('${cache.path}/'),
      'Archive escaped probe cache',
    );
    record('EXPORT ${await archive.length()} bytes');
    final downloaded = await _webdavRoundTrip(archive, root, record);

    // Prove restoration by changing each fixture after export, within this root.
    await File(source.filePath).writeAsString(_script('Changed source'));
    source.data['probeSetting'] = 'changed';
    await source.saveData();
    await ComicSourceManager().reload();
    _same(
      ComicSource.find(_sourceKey)?.name,
      'Changed source',
      'source mutation',
    );
    appdata.settings['theme_mode'] = 'light';
    appdata.settings['color'] = 'red';
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['comicTileScale'] = 0.75;
    appdata.searchHistory = ['changed'];
    await HistoryManager().addHistoryAsync(_history(changed: true));
    favorites.deleteFolder(_folder);
    favorites.createFolder('changed_folder');
    cookies.deleteAll();
    await appdata.saveData(false);
    _same(
      HistoryManager().find(_comicId, favorite.type)?.page,
      1,
      'history mutation',
    );
    _check(!favorites.existsFolder(_folder), 'Favorite mutation failed');
    record('MUTATED: isolated fixture data now differs from the archive');

    final outcome = await DataSync().applyBackup(
      () => importAppData(
        downloaded,
        mergeTranslations: false,
        userRestore: true,
        onProgress: (phase, message, bytes) {
          record('IMPORT ${phase.name} ${message ?? ''} ${bytes ?? ''}');
        },
      ),
    );
    _check(!outcome.translationsOnly, 'Wrong import type');
    await appdata.saveData(false);

    final restored = ComicSource.find(_sourceKey);
    _check(restored != null, 'Source was not restored');
    _same(restored!.name, _sourceName, 'source name');
    _same(restored.key, _sourceKey, 'source key');
    _same(restored.version, '1.0.0', 'source version');
    _same(restored.url, 'http://127.0.0.1/backup-probe.js', 'source URL');
    _same(
      await File(restored.filePath).readAsString(),
      _script(_sourceName),
      'script bytes',
    );
    for (final entry in _sourceData.entries) {
      _same(restored.data[entry.key], entry.value, 'source data ${entry.key}');
    }
    final search = await restored.searchPageData!.loadPage!('probe', 1, []);
    _check(
      !search.error && search.data.single.id == _comicId,
      'Restored source is not executable',
    );
    for (final entry in _settings.entries) {
      _same(appdata.settings[entry.key], entry.value, 'setting ${entry.key}');
    }
    _same(appdata.searchHistory, _searchHistory, 'search history');
    final history = HistoryManager().find(_comicId, favorite.type);
    _check(history != null, 'History was not restored');
    final actualHistory = _historyFields(history!);
    for (final entry in expectedHistory.entries) {
      _same(actualHistory[entry.key], entry.value, 'history ${entry.key}');
    }
    _check(favorites.existsFolder(_folder), 'Favorite folder was not restored');
    _check(
      !favorites.existsFolder('changed_folder'),
      'Post-export folder survived',
    );
    final restoredFavorite = favorites.getComic(
      _folder,
      _comicId,
      favorite.type,
    );
    final actualFavorite = restoredFavorite.toJson();
    for (final entry in expectedFavorite.entries) {
      _same(actualFavorite[entry.key], entry.value, 'favorite ${entry.key}');
    }
    _same(restoredFavorite.time, expectedFavoriteTime, 'favorite time');
    final restoredCookies = cookies.loadForRequest(Uri.parse(_cover));
    _check(
      restoredCookies.any(
        (cookie) =>
            cookie.name == 'backup_probe' && cookie.value == 'fixture-only',
      ),
      'Cookie was not restored',
    );
    _same(App.dataPath, data.path, 'data directory');
    _same(App.cachePath, cache.path, 'cache directory');
    _same(appdata.settings['webdav'], <String>[], 'sync remains unconfigured');
    result = {
      'result': 'PASS',
      'root': root.path,
      'archiveBytes': await archive.length(),
      'checks': [
        'source script/data/execution',
        'settings',
        'search history',
        'history fields',
        'favorite fields/folder',
        'cookie',
        'real WebDAV auth/PUT/GET through RHttpAdapter',
      ],
    };
  } catch (error) {
    await File('${root.path}/result.json').writeAsString(
      jsonEncode({
        'result': 'FAIL',
        'root': root.path,
        'error': error.toString(),
      }),
    );
    rethrow;
  } finally {
    await DatabaseGateway.instance.runExclusive(() async {
      if (HistoryManager().isInitialized) HistoryManager().close();
      if (LocalFavoritesManager().isInitialized) {
        LocalFavoritesManager().close();
      }
      if (App.readLater.isInitialized) App.readLater.close();
      if (LocalManager().isInitialized) LocalManager().close();
      if (App.domain.isInitialized) App.domain.close();
      SingleInstanceCookieJar.instance?.dispose();
    });
    // Sources retain JavaScript callbacks until the standalone process exits.
    Log.flush();
    // Keep all paths isolated until process exit, including delayed callbacks.
  }
  await File('${root.path}/result.json').writeAsString(jsonEncode(result));
  record('PASS ${jsonEncode(result)}');
  return 'PASS：.venera 导出/导入、WebDAV 字节往返及关键记录逐字段验证\n${root.path}';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _BackupProbe()));
}

class _BackupProbe extends StatefulWidget {
  const _BackupProbe();

  @override
  State<_BackupProbe> createState() => _BackupProbeState();
}

class _BackupProbeState extends State<_BackupProbe> {
  String status = '正在隔离目录中验证备份…';
  final messages = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        status = await _runBackupProbe(record);
      } catch (error, stack) {
        status = 'FAIL：$error';
        debugPrint('OHOS_BACKUP $status\n$stack');
      }
      if (mounted) setState(() {});
    });
  }

  void record(String message) {
    debugPrint('OHOS_BACKUP $message');
    if (!mounted) return;
    setState(() => messages.add(message));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('鸿蒙备份探针')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        SelectableText(status),
        const Text('自动运行；重新启动探针会使用新的临时目录。'),
        const Divider(),
        for (final message in messages) SelectableText(message),
      ],
    ),
  );
}

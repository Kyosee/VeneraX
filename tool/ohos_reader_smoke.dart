import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/image.dart' as pixels;
import 'package:venera/utils/translations.dart';

const _sourceKey = 'ohos_reader_probe';
const _chapter = 'chapter_1';
const _title = '鸿蒙本地测试漫画';
const _width = 32;
const _height = 16;

class _ProbeDeadline {
  _ProbeDeadline(this.timeout);

  final Duration timeout;
  final Stopwatch _clock = Stopwatch()..start();
  bool _expired = false;

  Future<T> step<T>(
    String name,
    Future<T> Function() action, {
    Duration? limit,
  }) {
    final remaining = timeout - _clock.elapsed;
    if (_expired || remaining <= Duration.zero) {
      _expired = true;
      throw TimeoutException(
        'Reader probe deadline reached before $name',
        timeout,
      );
    }
    final wait = limit != null && limit < remaining ? limit : remaining;
    return action().timeout(
      wait,
      onTimeout: () {
        _expired = true;
        throw TimeoutException('Reader probe timed out during $name', wait);
      },
    );
  }
}

int _pixel(int page, int index) =>
    0xff000000 | ((index * 2654435761 + page * 0x123456) & 0xffffff);

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

String _script(String base) =>
    '''
class OhosReaderProbe extends ComicSource {
  name = "鸿蒙阅读探针";
  key = "$_sourceKey";
  version = "1.0.0";
  minAppVersion = "1.0.0";
  url = "$base/source.js";
  search = {
    load: async (keyword, options, page) => {
      const response = await Network.get(
        "$base/search?q=" + encodeURIComponent(keyword) + "&page=" + page
      );
      if (response.status !== 200) throw "Unexpected search response";
      return JSON.parse(response.body);
    }
  };
  comic = {
    loadInfo: async (id) => {
      const response = await Network.get("$base/comic/" + encodeURIComponent(id));
      if (response.status !== 200) throw "Unexpected details response";
      return JSON.parse(response.body);
    },
    loadEp: async (id, ep) => {
      const response = await Network.get(
        "$base/pages?id=" + encodeURIComponent(id) + "&ep=" + encodeURIComponent(ep)
      );
      if (response.status !== 200) throw "Unexpected chapter response";
      return JSON.parse(response.body);
    },
    onImageLoad: (url, id, ep) => ({
      url: url,
      headers: { "X-Venera-Probe": id + "/" + ep }
    })
  };
}
''';

Future<void> _checkImage(
  List<int> bytes,
  int page,
  _ProbeDeadline deadline,
) async {
  final image = await deadline.step(
    'decode image $page',
    () => pixels.Image.decodeImage(Uint8List.fromList(bytes)),
  );
  check(
    image.width == _width && image.height == _height,
    'Image dimensions changed.',
  );
  for (var index = 0; index < _width * _height; index++) {
    check(
      image.getPixelAtIndex(index).value == _pixel(page, index),
      'Page $page pixel $index changed.',
    );
  }
}

void _checkHistory(History? history, String comicId) {
  check(history != null, 'Reading progress missing for $comicId.');
  check(
    history!.id == comicId && history.title == _title,
    'History metadata changed.',
  );
  check(
    history.ep == 1 && history.page == 2 && history.maxPage == 2,
    'Reading position was not persisted.',
  );
  check(setEquals(history.readEpisode, {'1'}), 'Read chapter marks changed.');
}

Future<void> _checkOffline(
  LocalManager local,
  String comicId,
  _ProbeDeadline deadline,
) async {
  final type = ComicType.fromKey(_sourceKey);
  check(local.isDownloaded(comicId, type, 1), 'Downloaded chapter missing.');
  final pages = await deadline.step(
    'offline page list',
    () => local.getImages(comicId, type, _chapter),
  );
  check(pages.length == 2, 'Offline chapter has the wrong number of pages.');
  for (var page = 0; page < pages.length; page++) {
    check(pages[page].startsWith('file://'), 'Offline page is not local.');
    final bytes = await deadline.step(
      'read offline image $page',
      () => File.fromUri(Uri.parse(pages[page])).readAsBytes(),
    );
    await _checkImage(bytes, page, deadline);
  }
}

Future<void> _waitForDownload(
  LocalManager local,
  ImagesDownloadTask task,
  _ProbeDeadline deadline,
) async {
  final done = Completer<void>();
  void changed() {
    if (done.isCompleted) return;
    if (task.isError) {
      done.completeError(
        StateError('Chapter download failed: ${task.message}'),
      );
    } else if (!local.downloadingTasks.contains(task) &&
        local.find(task.id, task.comicType) != null) {
      done.complete();
    }
  }

  local.addListener(changed);
  task.addListener(changed);
  try {
    await deadline.step('chapter download', () {
      local.addTask(task);
      changed();
      return done.future;
    }, limit: const Duration(seconds: 30));
    await deadline.step(
      'save download queue',
      local.saveCurrentDownloadingTasks,
    );
  } finally {
    local.removeListener(changed);
    task.removeListener(changed);
    if (local.downloadingTasks.contains(task)) local.pauseTask(task);
  }
}

Future<String> runReaderProbe() async {
  final deadline = _ProbeDeadline(const Duration(seconds: 90));
  HttpServer? activeServer;
  var acceptingServer = true;
  try {
    await deadline.step('application paths', App.init);
    // All production managers below are redirected before their first open.
    App.dataPath = '${App.dataPath}/ohos_reader_probe';
    App.cachePath = '${App.cachePath}/ohos_reader_probe';
    await deadline.step(
      'data directory',
      () => Directory(App.dataPath).create(recursive: true),
    );
    await deadline.step(
      'cache directory',
      () => Directory(App.cachePath).create(recursive: true),
    );
    await deadline.step('settings', appdata.init);
    appdata.settings['proxy'] = 'direct';
    await deadline.step('translations', AppTranslation.init);
    await deadline.step('HTTP runtime', nativeInitRhttp);
    SingleInstanceCookieJar('${App.dataPath}/cookie.db');
    await deadline.step('domain database', () => App.domain.init(App.dataPath));
    await deadline.step('JavaScript runtime', JsEngine().init);
    await deadline.step('comic sources', ComicSourceManager().init);
    await deadline.step('history database', HistoryManager().init);
    await deadline.step('local library', LocalManager().init);
    // A previous failed probe must not resume requests to its old loopback port.
    if (LocalManager().downloadingTasks.isNotEmpty) {
      LocalManager().pauseAll();
      for (final task in LocalManager().downloadingTasks.toList()) {
        LocalManager().removeTask(task);
      }
      await deadline.step(
        'clear old queue',
        LocalManager().saveCurrentDownloadingTasks,
      );
    }
    await deadline.step('image cache', () => CacheManager().ready);

    final completedFile = File('${App.dataPath}/completed_runs');
    final completed =
        await deadline.step('launch counter lookup', completedFile.exists)
        ? int.parse(
            await deadline.step(
              'launch counter read',
              completedFile.readAsString,
            ),
          )
        : 0;
    if (completed > 0) {
      check(
        ComicSource.find(_sourceKey) != null,
        'Source did not survive restart.',
      );
      _checkHistory(
        HistoryManager().find(
          'probe_$completed',
          ComicType.fromKey(_sourceKey),
        ),
        'probe_$completed',
      );
      await _checkOffline(LocalManager(), 'probe_$completed', deadline);
    }

    final comicId = 'probe_${completed + 1}';
    final encoded = <Uint8List>[
      for (var page = 0; page < 2; page++)
        pixels.Image(
          Uint32List.fromList(
            List.generate(_width * _height, (index) => _pixel(page, index)),
          ),
          _width,
          _height,
        ).encodePng(),
    ];
    check(
      encoded.every((bytes) => bytes.length >= 100),
      'Fixture must pass the download pipeline tiny-response guard.',
    );
    final server = await deadline.step('bind fixture server', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // A bind completing after timeout must not leave an unowned listener.
      if (!acceptingServer) {
        await server.close(force: true);
        throw StateError('Reader probe already stopped');
      }
      activeServer = server;
      return server;
    });
    final base = 'http://127.0.0.1:${server.port}';
    final requests = <String, int>{};
    String? serverError;
    server.listen((request) async {
      try {
        final path = request.uri.path;
        requests[path] = (requests[path] ?? 0) + 1;
        request.response.headers.set(
          HttpHeaders.cacheControlHeader,
          'no-store',
        );
        Object? body;
        switch (path) {
          case '/source.js':
            request.response.headers.contentType = ContentType(
              'text',
              'javascript',
              charset: 'utf-8',
            );
            request.response.write(_script(base));
          case '/search':
            check(
              request.uri.queryParameters['q'] == '鸿蒙',
              'Search keyword was corrupted.',
            );
            check(
              request.uri.queryParameters['page'] == '1',
              'Search pagination changed.',
            );
            body = {
              'comics': [
                {
                  'id': comicId,
                  'title': _title,
                  'subtitle': '本地自制内容',
                  'cover': '$base/cover.png',
                },
              ],
              'maxPage': 1,
            };
          case final value when value == '/comic/$comicId':
            body = {
              'title': _title,
              'subtitle': '本地自制内容',
              'cover': '$base/cover.png',
              'description': 'Offline development fixture',
              'tags': {
                '类型': ['测试'],
              },
              'chapters': {_chapter: '第一章'},
              'maxPage': 2,
            };
          case '/pages':
            check(
              request.uri.queryParameters['id'] == comicId &&
                  request.uri.queryParameters['ep'] == _chapter,
              'Chapter identifiers changed.',
            );
            body = {
              'images': ['$base/0.png', '$base/1.png'],
            };
          case '/cover.png':
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(encoded[0]);
          case '/0.png':
          case '/1.png':
            check(
              request.headers.value('X-Venera-Probe') == '$comicId/$_chapter',
              'Image loading configuration header missing.',
            );
            request.response.headers.contentType = ContentType('image', 'png');
            request.response.add(encoded[path == '/0.png' ? 0 : 1]);
          default:
            throw StateError('Unexpected request: $path');
        }
        if (body != null) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(body));
        }
      } catch (error) {
        serverError = error.toString();
        request.response.statusCode = HttpStatus.internalServerError;
      } finally {
        await request.response.close();
      }
    });

    final prior = ComicSource.find(_sourceKey);
    if (prior != null) {
      ComicSourceManager().remove(_sourceKey);
      await deadline.step(
        'replace old source',
        () => File(prior.filePath).delete(),
      );
    }
    final client = AppDio();
    late final String script;
    try {
      final response = await deadline.step(
        'download source',
        () => client.get<String>('$base/source.js'),
      );
      script = response.data!;
    } finally {
      client.close(force: true);
    }
    final imported = await deadline.step(
      'parse source',
      () => ComicSourceParser().createAndParse(script, 'probe.js'),
    );
    check(ComicSourceManager().add(imported), 'Source registration failed.');
    check(
      await deadline.step(
            'verify source file',
            () => File(imported.filePath).readAsString(),
          ) ==
          _script(base),
      'Source file changed.',
    );
    await deadline.step('reload source', ComicSourceManager().reload);
    final source = ComicSource.find(_sourceKey);
    check(source != null, 'Imported source could not reload from disk.');
    final search = await deadline.step(
      'search comics',
      () => source!.searchPageData!.loadPage!('鸿蒙', 1, []),
    );
    check(!search.error, 'Search failed: ${search.errorMessage}');
    check(
      search.data.single.id == comicId &&
          search.data.single.title == _title &&
          search.subData == 1,
      'Search response changed.',
    );
    final details = await deadline.step(
      'comic details',
      () => source!.loadComicInfo!(comicId),
    );
    check(!details.error, 'Details failed: ${details.errorMessage}');
    check(
      details.data.chapters!.allChapters[_chapter] == '第一章',
      'Chapter map changed.',
    );
    final pages = await deadline.step(
      'chapter pages',
      () => source!.loadComicPages!(comicId, _chapter),
    );
    check(
      !pages.error && pages.data.length == 2,
      'Chapter page loading failed.',
    );
    // Read only page one here; the download must fetch page two itself.
    final progress = await deadline.step(
      'reader image stream',
      () => ImageDownloader.loadComicImage(
        pages.data[0],
        _sourceKey,
        comicId,
        _chapter,
      ).last,
    );
    check(progress.imageBytes != null, 'Reader image stream had no data.');
    await _checkImage(progress.imageBytes!, 0, deadline);

    final history = History.fromModel(
      model: details.data,
      ep: 1,
      page: 2,
      readChapters: {'1'},
    )..maxPage = 2;
    await deadline.step(
      'write history',
      () => HistoryManager().addHistoryAsync(history),
    );
    HistoryManager().close();
    await deadline.step('reopen history', HistoryManager().init);
    _checkHistory(HistoryManager().find(comicId, history.type), comicId);

    final task = ImagesDownloadTask(
      source: source!,
      comicId: comicId,
      chapters: [_chapter],
    );
    await _waitForDownload(LocalManager(), task, deadline);
    check(serverError == null, 'Fixture server failed: $serverError');
    for (final path in [
      '/source.js',
      '/search',
      '/comic/$comicId',
      '/pages',
      '/cover.png',
      '/0.png',
      '/1.png',
    ]) {
      check((requests[path] ?? 0) > 0, 'Real pipeline skipped $path.');
    }
    await server.close(force: true);
    activeServer = null;
    LocalManager().close();
    await deadline.step('reopen local library', LocalManager().init);
    await _checkOffline(LocalManager(), comicId, deadline);
    await deadline.step(
      'write launch counter',
      () => completedFile.writeAsString('${completed + 1}', flush: true),
    );
    return 'PASS: reader source import/reload, QuickJS HTTP search/details/chapters, '
        'image headers/stream/pixels, background history write and database reopen, '
        'queued chapter download and offline reopen. Completed runs: ${completed + 1}; '
        'prior-launch persistence: ${completed > 0 ? "verified" : "restart to verify"}.';
  } finally {
    acceptingServer = false;
    try {
      if (LocalManager().isInitialized) LocalManager().pauseAll();
    } finally {
      try {
        ImageDownloader.cancelAllLoadingImages();
      } finally {
        await activeServer?.close(force: true);
      }
    }
    // Sources retain JS callbacks for the app lifetime, as in the main app.
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String result;
  try {
    result = await runReaderProbe();
  } catch (error, stack) {
    result = 'FAIL: $error\n$stack';
  }
  debugPrint(result);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(result),
          ),
        ),
      ),
    ),
  );
}

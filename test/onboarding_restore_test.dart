import 'dart:convert';
import 'dart:io';

// Native integration tests need desktop plugin libraries on the loader path.

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/data_sync_tasks.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/init.dart' show deferredInitCompleter;
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

final class _FailPendingCompletion extends IOOverrides {
  bool failed = false;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('implicitData.json.tmp')
        ? _PendingFile(file, this)
        : file;
  }
}

class _PendingFile implements File {
  _PendingFile(this.file, this.failure);
  final File file;
  final _FailPendingCompletion failure;

  @override
  void writeAsStringSync(String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) {
    final data = jsonDecode(contents) as Map;
    if (!failure.failed &&
        data['hasCompletedInitialSync'] == true &&
        data['webdavSetupRestorePending'] != true) {
      failure.failed = true;
      throw const FileSystemException('fixture completion write failed');
    }
    file.writeAsStringSync(contents, mode: mode, encoding: encoding, flush: flush);
  }

  @override
  File renameSync(String newPath) => file.renameSync(newPath);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String oldDataPath;
  late String oldCachePath;
  late bool oldBackground;

  setUpAll(AppTranslation.init);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venerax-setup-restore-');
    oldDataPath = App.dataPath;
    oldCachePath = App.cachePath;
    oldBackground = App.isBackgroundTask;
    App.dataPath = directory.path;
    App.cachePath = (await Directory('${directory.path}/cache').create()).path;
    App.isBackgroundTask = true;
    appdata.settings['webdav'] = <String>[];
    appdata.implicitData.clear();
    await OnboardingStore.instance.load(directory.path);
    await OnboardingStore.instance.accept('en-US');
  });

  tearDown(() async {
    await appdata.saveData(false);
    App.dataPath = oldDataPath;
    App.cachePath = oldCachePath;
    App.isBackgroundTask = oldBackground;
    await directory.delete(recursive: true);
  });

  Future<File> backup() async {
    final foreignAcceptance = {
      'setupCompleted': true,
      'acceptedVersion': 999,
      'acceptedAt': '2026-11-10T00:00:00.000Z',
      'acceptedLanguage': 'zh-TW',
    };
    final archive = Archive();
    void entry(String path, Object value) {
      final bytes = utf8.encode(jsonEncode(value));
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    entry('appdata.json', {
      'settings': {
        'webdav': [
          'https://example.invalid/backups',
          'reader',
          'fixture-password',
        ],
        'disclaimerConsented': true,
        'dataVersion': 4,
      },
      'searchHistory': ['restored search'],
    });
    entry('implicitData.json', foreignAcceptance);
    entry('onboarding.json', foreignAcceptance);
    final file = File('${directory.path}/fixture.venera');
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  test('setup import keeps credentials and acceptance device-local', () async {
    final record = File('${directory.path}/onboarding.json');
    final acceptedBefore = await record.readAsString();
    final file = await backup();
    appdata.implicitData['webdavSetupRestorePending'] = true;

    await DataSync().applyBackup(
      () => importAppData(file, userRestore: true, restoreWebdavConfig: false),
    );
    await appdata.saveData(false);

    expect(appdata.searchHistory, ['restored search']);
    expect(appdata.settings['webdav'], isEmpty);
    expect(DataSync().initialRestoreDeferred, isTrue);
    expect(await record.readAsString(), acceptedBefore);
    await OnboardingStore.instance.load(directory.path);
    expect(OnboardingStore.instance.state.acceptedLanguage, 'en-US');
    expect(OnboardingStore.instance.state.setupCompleted, isFalse);
    expect(OnboardingStore.instance.state.acceptedVersion, isNot(999));
  });

  test(
    'normal imports retain the existing credential restore behavior',
    () async {
      final file = await backup();
      await DataSync().applyBackup(
        () => importAppData(file, userRestore: true),
      );
      await appdata.saveData(false);

      expect(appdata.settings['webdav'], [
        'https://example.invalid/backups',
        'reader',
        'fixture-password',
      ]);
    },
  );

  test(
    'immediate and deferred WebDAV restores align versions without publishing',
    () async {
      final archive = await backup();
      final bytes = await archive.readAsBytes();
      final requests = <String>[];
      var rejectDownload = false;
      var rejectUpload = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final root = 'http://127.0.0.1:${server.port}';
      server.listen((request) async {
        requests.add(request.method);
        await request.drain<void>();
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.headers.contentType = ContentType(
            'application',
            'xml',
          );
          request.response.write('''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
<d:response><d:href>/20767-4.win.venera</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>${bytes.length}</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
        } else if (request.method == 'OPTIONS') {
          request.response.headers.set('DAV', '1, 2');
          request.response.headers.set('Allow', 'OPTIONS, PROPFIND, GET, HEAD');
        } else if (request.method == 'HEAD') {
          request.response.contentLength = bytes.length;
        } else if (request.method == 'GET') {
          if (rejectDownload) {
            request.response.statusCode = 500;
          } else {
            request.response.add(bytes);
          }
        } else if (request.method == 'PUT') {
          request.response.statusCode = rejectUpload ? 500 : 201;
        } else {
          request.response.statusCode = 405;
        }
        await request.response.close();
      });
      try {
        final comics = await Directory('${directory.path}/comics').create();
        await File('${directory.path}/local_path').writeAsString(comics.path);
        await appdata.init();
        SingleInstanceCookieJar('${directory.path}/cookie.db');
        await JsEngine().init();
        await ComicSourceManager().init();
        await HistoryManager().init();
        await LocalFavoritesManager().init();
        await App.readLater.init();
        await LocalManager().init();
        await App.domain.init(App.dataPath);
        await TranslationStore().init();
        if (!deferredInitCompleter.isCompleted) {
          deferredInitCompleter.complete();
        }
        appdata.settings['webdav'] = [root, 'reader', 'fixture-password'];
        appdata.settings['webdavUseProxy'] = false;
        appdata.settings['dataVersion'] = 100;
        appdata.implicitData['webdavSetupRestorePending'] = true;
        appdata.implicitData['hasCompletedInitialSync'] = false;
        appdata.searchHistory = ['local data'];
        await DataSync().setSyncMode(WebdavSyncMode.manual, settle: false);

        final result = await DataSync().downloadData(userRestore: true);
        expect(result.errorMessage, isNull, reason: requests.toString());
        expect(appdata.searchHistory, ['restored search']);
        expect(appdata.settings['dataVersion'], 4);
        expect(DataSync().initialRestoreDeferred, isFalse);
        expect(requests, containsAll(['PROPFIND', 'GET']));

        // Complete setup, then restore the connection saved for later in Settings.
        await OnboardingStore.instance.completeSetup();
        appdata.settings['dataVersion'] = 100;
        appdata.implicitData['webdavSetupRestorePending'] = true;
        appdata.implicitData['hasCompletedInitialSync'] = false;
        appdata.searchHistory = ['local data'];
        rejectDownload = true;
        final failed = await DataSync().downloadSpecificBackup('20767-4.win.venera');
        expect(failed.error, isTrue);
        expect(DataSync().initialRestoreDeferred, isTrue);
        expect(appdata.settings['dataVersion'], 100);
        expect(appdata.searchHistory, ['local data']);

        rejectDownload = false;
        for (final specific in [false, true]) {
          appdata.settings['dataVersion'] = 100;
          final failure = _FailPendingCompletion();
          final failedCompletion = await IOOverrides.runWithIOOverrides(
            () => specific
                ? DataSync().downloadSpecificBackup('20767-4.win.venera')
                : DataSync().downloadData(userRestore: true),
            failure,
          );
          expect(failure.failed, isTrue);
          expect(failedCompletion.error, isTrue);
          expect(DataSync().initialRestoreDeferred, isTrue);
          expect(appdata.settings['dataVersion'], 4);
          final disk = jsonDecode(await File(
            '${directory.path}/implicitData.json',
          ).readAsString()) as Map;
          expect(disk['webdavSetupRestorePending'], isTrue);
        }
        final restored = await DataSync().downloadSpecificBackup('20767-4.win.venera');
        expect(restored.errorMessage, isNull);
        expect(appdata.searchHistory, ['restored search']);
        expect(appdata.settings['dataVersion'], 4);
        expect(DataSync().initialRestoreDeferred, isFalse);
        expect([
          ...DataSyncTaskManager.instance.currentTasks,
          ...DataSyncTaskManager.instance.historyTasks,
        ].where((task) => task.type == DataSyncTaskType.upload), isEmpty);
        expect(
          requests.where((method) => method == 'PUT' || method == 'DELETE'),
          isEmpty,
        );

        // A later explicit upload can choose the local backup instead of pulling.
        appdata.implicitData['webdavSetupRestorePending'] = true;
        appdata.implicitData['hasCompletedInitialSync'] = false;
        appdata.searchHistory = ['chosen local data'];
        final requestCount = requests.length;
        final automatic = await DataSync().uploadData();
        expect(automatic.error, isTrue);
        expect(requests, hasLength(requestCount));
        rejectUpload = true;
        final rejected = await DataSync().uploadData(force: true);
        expect(rejected.error, isTrue);
        expect(DataSync().initialRestoreDeferred, isTrue);
        expect(appdata.settings['dataVersion'], 4);
        rejectUpload = false;
        final published = await DataSync().uploadData(force: true);
        expect(published.errorMessage, isNull);
        expect(DataSync().initialRestoreDeferred, isFalse);
        expect(appdata.settings['dataVersion'], 5);
        expect(appdata.searchHistory, ['chosen local data']);
        expect(requests.skip(requestCount), contains('PUT'));
        expect(requests.skip(requestCount), isNot(contains('GET')));
      } finally {
        await server.close(force: true);
        HistoryManager().close();
        LocalFavoritesManager().close();
        App.readLater.close();
        LocalManager().close();
        App.domain.close();
        TranslationStore().close();
        SingleInstanceCookieJar.instance?.dispose();
        SingleInstanceCookieJar.instance = null;
        JsEngine().dispose();
      }
    },
  );
}

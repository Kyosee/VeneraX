import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/session_guard.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  var uploads = 0;
  var failUpload = false;
  Completer<void>? holdUpload;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('sync-cadence-');
    App.dataPath = directory.path;
    App.cachePath = (await Directory('${directory.path}/cache').create()).path;
    appdata.settings['webdav'] = <String>[];
    appdata.settings['followUpdatesFolders'] = <String>[];
    appdata.settings['followUpdatesAllFolders'] = false;
    appdata.settings['syncLocalComicImages'] = false;
    appdata.settings['webdavUseProxy'] = false;
    await AppTranslation.init();
    await appdata.init();
    await OnboardingStore.instance.load(directory.path);
    await OnboardingStore.instance.accept('en-US');
    await OnboardingStore.instance.completeSetup();
    await LocalFavoritesManager().init();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      if (request.method == 'PROPFIND') {
        request.response.statusCode = 207;
        request.response.headers.contentType = ContentType(
          'application',
          'xml',
        );
        request.response.write(
          '''<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>''',
        );
      } else if (request.method == 'PUT') {
        uploads++;
        await holdUpload?.future;
        request.response.statusCode = failUpload ? 500 : 201;
      } else {
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
  });

  tearDownAll(() async {
    await server.close(force: true);
    LocalFavoritesManager().close();
    await directory.delete(recursive: true);
  });

  testWidgets(
    'realtime batches changes and preserves failures and newer edits',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final sync = DataSync();
      appdata.settings['webdav'] = [
        'http://127.0.0.1:${server.port}',
        'reader',
        'fixture',
      ];
      appdata.implicitData['hasCompletedInitialSync'] = true;
      appdata.implicitData['webdavSyncMode'] = 'realtime';
      Future<void> waitUntil(bool Function() done) async {
        for (var i = 0; i < 1000 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 1));
        }
        expect(done(), isTrue, reason: 'Network/export must finish');
      }

      Future<void> finishUpload(int count) =>
          waitUntil(() => uploads >= count && !sync.isUploading);
      try {
        // Safe mode holds every automatic sync back; nothing is left pending
        // to fire once it ends.
        SessionGuard.safeMode = true;
        sync.requestAutoUpload();
        await tester.pump(const Duration(seconds: 60));
        expect(sync.hasPendingChanges, isFalse);
        expect(uploads, 0);
        SessionGuard.safeMode = false;

        sync.requestAutoUpload();
        expect(sync.hasPendingChanges, isTrue);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(seconds: 5));
          sync.requestAutoUpload();
          expect(uploads, 0);
        }
        await tester.pump(const Duration(seconds: 5));
        await finishUpload(1);
        expect(sync.hasPendingChanges, isFalse);

        sync.requestAutoUpload();
        await tester.pump(const Duration(seconds: 14));
        expect(uploads, 1);
        await tester.pump(const Duration(seconds: 1));
        await finishUpload(2);

        holdUpload = Completer<void>();
        sync.requestAutoUpload();
        await tester.pump(const Duration(seconds: 15));
        await waitUntil(() => uploads == 3);
        sync.requestAutoUpload();
        holdUpload!.complete();
        holdUpload = null;
        await finishUpload(3);
        expect(
          sync.hasPendingChanges,
          isTrue,
          reason: 'Changes after export must remain pending',
        );
        await tester.pump(const Duration(seconds: 30));
        await finishUpload(4);
        expect(sync.hasPendingChanges, isFalse);

        failUpload = true;
        sync.requestAutoUpload();
        await tester.pump(const Duration(seconds: 15));
        await finishUpload(5);
        expect(sync.hasPendingChanges, isTrue);
        failUpload = false;
        await tester.pump(const Duration(seconds: 30));
        await finishUpload(6);
        expect(sync.hasPendingChanges, isFalse);

        sync.requestAutoUpload();
        sync.didChangeAppLifecycleState(AppLifecycleState.paused);
        await finishUpload(7);
        expect(sync.hasPendingChanges, isFalse);

        sync.requestAutoUpload();
        unawaited(sync.setSyncMode(WebdavSyncMode.manual, settle: false));
        await tester.pump(const Duration(minutes: 31));
        sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
        expect(uploads, 7);
        expect(sync.hasPendingChanges, isTrue);

        unawaited(sync.setSyncMode(WebdavSyncMode.dataSaver));
        await finishUpload(8);
        sync.requestAutoUpload();
        await tester.pump(const Duration(seconds: 31));
        expect(uploads, 8);
        sync.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await finishUpload(9);
        expect(sync.hasPendingChanges, isFalse);
      sync.requestAutoUpload();
      await tester.pump(const Duration(minutes: 29));
      expect(uploads, 9);
      await tester.pump(const Duration(minutes: 1));
      await finishUpload(10);
      expect(sync.hasPendingChanges, isFalse);
      } finally {
        holdUpload?.complete();
        unawaited(sync.setSyncMode(WebdavSyncMode.manual, settle: false));
        appdata.settings['webdav'] = <String>[];
        var saved = false;
        unawaited(appdata.writeImplicitData().then((_) => saved = true));
        await waitUntil(() => saved && !sync.isUploading);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        WidgetsBinding.instance.removeObserver(sync);
        LocalFavoritesManager().removeListener(sync.onDataChanged);
        ComicSourceManager().removeListener(sync.onDataChanged);
        ReadLaterManager().removeListener(sync.onDataChanged);
        HistoryManager().removeListener(sync.onDataChanged);
        ImageFavoriteManager().removeListener(sync.onDataChanged);
        sync.dispose();
        DataSync.instance = null;
        debugDefaultTargetPlatformOverride = null;
      }
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

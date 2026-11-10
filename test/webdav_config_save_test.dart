import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

class _Sync extends ChangeNotifier implements DataSync {
  @override
  WebdavSyncMode syncMode = WebdavSyncMode.realtime;
  late final result = Completer<Res<bool>>();
  final settlements = <bool>[];
  int automaticUploads = 0;
  int syncs = 0;

  @override
  Future<void> setSyncMode(WebdavSyncMode mode, {bool settle = true}) async {
    syncMode = mode;
    settlements.add(settle);
    notifyListeners();
  }

  @override
  void requestAutoUpload() => automaticUploads++;

  @override
  Future<Res<bool>> syncData() async {
    syncs++;
    return result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Writes {
  final snapshots = <Map<String, dynamic>>[];
  final syncSnapshots = <Map<String, dynamic>>[];
  final implicitSnapshots = <Map<String, dynamic>>[];
  Completer<void>? gate;
  bool fail = false;
  bool failImplicit = false;
}

class _ConfigFile implements File {
  _ConfigFile(this.path, this.writes);
  @override
  final String path;
  final _Writes writes;

  @override
  bool existsSync() => false;

  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    if (path.endsWith('appdata.json.tmp')) {
      writes.snapshots.add(jsonDecode(contents));
    } else if (path.endsWith('syncdata.json.tmp')) {
      writes.syncSnapshots.add(jsonDecode(contents));
    } else if (path.endsWith('implicitData.json.tmp')) {
      writes.implicitSnapshots.add(jsonDecode(contents));
    }
    await writes.gate?.future;
    if (writes.fail ||
        (writes.failImplicit && path.endsWith('implicitData.json.tmp'))) {
      throw FileSystemException('fixture write failed', path);
    }
    return this;
  }

  @override
  Future<File> rename(String newPath) async => this;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Sync sync;
  late _Writes writes;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() {
    sync = _Sync();
    writes = _Writes();
    DataSync.instance = sync;
    appdata.settings['language'] = 'en-US';
    appdata.settings['webdav'] = <String>[];
    appdata.settings['disableSyncFields'] = '';
    appdata.settings['syncLocalComicImages'] = false;
  });

  tearDown(() {
    DataSync.instance = null;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (_, child) => OverlayWidget(child!),
        home: const Scaffold(body: DataSyncSettings(section: 'WebDAV Sync')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).at(0),
      'https://example.test/dav/',
    );
    await tester.enterText(find.byType(TextField).at(1), 'fixture');
    await tester.enterText(find.byType(TextField).at(2), 'fixture-password');
    await tester.ensureVisible(find.text('Save'));
    await tester.pumpAndSettle();
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    expect(tester.takeException(), isNull);
  }

  testWidgets('sync modes persist only in the device-local implicit snapshot', (
    tester,
  ) async {
    final previousImplicit = Map<String, dynamic>.from(appdata.implicitData);
    DataSync.instance = null;
    final actual = DataSync();
    try {
      await IOOverrides.runZoned(() async {
        for (final mode in WebdavSyncMode.values) {
          final savedMode = actual.setSyncMode(mode, settle: false);
          await tester.pumpAndSettle();
          await savedMode;
          expect(writes.implicitSnapshots.last['webdavSyncMode'], mode.name);
          expect(
            writes.implicitSnapshots.last['webdavAutoSync'],
            mode != WebdavSyncMode.manual,
          );
          final saved = appdata.saveData(false);
          await tester.pumpAndSettle();
          await saved;
          for (final snapshot in [
            writes.snapshots.last,
            writes.syncSnapshots.last,
          ]) {
            final settings = snapshot['settings'] as Map;
            expect(settings.containsKey('webdavSyncMode'), isFalse);
            expect(settings.containsKey('webdavAutoSync'), isFalse);
          }
        }
        writes.failImplicit = true;
        appdata.implicitData['webdavSetupRestorePending'] = true;
        await expectLater(
          actual.setSyncMode(WebdavSyncMode.manual, settle: false),
          throwsA(isA<FileSystemException>()),
        );
        final saved = appdata.saveData(false);
        await tester.pumpAndSettle();
        await saved;
        writes.failImplicit = false;
      }, createFile: (path) => _ConfigFile(path, writes));
    } finally {
      WidgetsBinding.instance.removeObserver(actual);
      LocalFavoritesManager().removeListener(actual.onDataChanged);
      ComicSourceManager().removeListener(actual.onDataChanged);
      ReadLaterManager().removeListener(actual.onDataChanged);
      HistoryManager().removeListener(actual.onDataChanged);
      ImageFavoriteManager().removeListener(actual.onDataChanged);
      actual.dispose();
      appdata.implicitData = previousImplicit;
      DataSync.instance = sync;
      sync.dispose();
    }
  });

  testWidgets('saves once and closes before initial sync finishes', (
    tester,
  ) async {
    await IOOverrides.runZoned(() async {
      await open(tester);
      final save = tester.widget<Button>(find.widgetWithText(Button, 'Save'));
      save.onPressed();
      save.onPressed();
      await tester.pumpAndSettle();

      expect(writes.snapshots, hasLength(1));
      expect(writes.snapshots.single['settings']['webdav'], [
        'https://example.test/dav/',
        'fixture',
        'fixture-password',
      ]);
      expect(find.text('Webdav'), findsNothing);
      expect(sync.result.isCompleted, isFalse);
      expect(sync.syncs, 1);
      expect(sync.automaticUploads, 0);
      expect(sync.settlements, [false]);

      sync.result.complete(const Res.error('fixture sync failed'));
      await finish(tester);
    }, createFile: (path) => _ConfigFile(path, writes));
  });

  testWidgets('waits for persistence before closing or starting sync', (
    tester,
  ) async {
    await IOOverrides.runZoned(() async {
      await open(tester);
      writes.gate = Completer<void>();
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.text('Webdav'), findsOneWidget);
      expect(sync.syncs, 0);
      expect(sync.settlements, isEmpty);

      writes.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Webdav'), findsNothing);
      expect(sync.syncs, 1);
      sync.result.complete(const Res(true));
      await finish(tester);
    }, createFile: (path) => _ConfigFile(path, writes));
  });

  testWidgets('write failure keeps the form open and allows retry', (
    tester,
  ) async {
    await IOOverrides.runZoned(() async {
      await open(tester);
      writes.fail = true;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Webdav'), findsOneWidget);
      expect(sync.syncs, 0);
      expect(sync.settlements, isEmpty);
      expect(appdata.settings['webdav'], isEmpty);
      expect(tester.takeException(), isNull);

      writes.fail = false;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Webdav'), findsNothing);
      expect(sync.syncs, 1);
      sync.result.complete(const Res(true));
      await finish(tester);
    }, createFile: (path) => _ConfigFile(path, writes));
  });

  testWidgets('manual mode saves without an initial sync', (tester) async {
    sync.syncMode = WebdavSyncMode.manual;
    await IOOverrides.runZoned(() async {
      await open(tester);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Webdav'), findsNothing);
      expect(writes.snapshots, hasLength(1));
      expect(sync.syncs, 0);
      expect(sync.automaticUploads, 0);
      expect(sync.settlements, [false]);
      await finish(tester);
    }, createFile: (path) => _ConfigFile(path, writes));
  });

  testWidgets('finishing a save after dismissing the form is safe', (
    tester,
  ) async {
    await IOOverrides.runZoned(() async {
      await open(tester);
      writes.gate = Completer<void>();
      await tester.tap(find.text('Save'));
      await tester.pump();
      App.rootNavigatorKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 300));
      writes.gate!.complete();
      await tester.pumpAndSettle();
      expect(sync.syncs, 1);
      sync.result.completeError(StateError('fixture sync exception'));
      await finish(tester);
    }, createFile: (path) => _ConfigFile(path, writes));
  });
}

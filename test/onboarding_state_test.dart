import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;
import 'package:venera/foundation/disclaimer_content.dart';
import 'package:venera/foundation/onboarding.dart';
import 'package:venera/foundation/sqlite_connection.dart';

void _createUsageDatabase(
  File file, {
  bool favorite = false,
  bool populated = false,
  String folder = 'Favorites',
}) {
  file.createSync();
  final db = openRawDatabase(file.path);
  try {
    final table = favorite ? '"${folder.replaceAll('"', '""')}"' : 'history';
    db.execute(
      favorite
          ? '''
          CREATE TABLE $table (
            id TEXT, name TEXT, author TEXT, type INT, tags TEXT,
            cover_path TEXT, time TEXT, display_order INT, translated_tags TEXT,
            authors TEXT, comic_status TEXT, update_time_meta TEXT,
            extra_meta TEXT, PRIMARY KEY (id, type)
          );
        '''
          : '''
          CREATE TABLE history (
            id TEXT, title TEXT, subtitle TEXT, cover TEXT, time INT,
            type INT, ep INT, page INT, readEpisode TEXT, max_page INT,
            chapter_group INT, hidden INT, PRIMARY KEY (id, type)
          );
        ''',
    );
    if (favorite) {
      db.execute('''
        CREATE TABLE folder_order (folder_name TEXT PRIMARY KEY, order_value INT);
        INSERT INTO folder_order VALUES ('Favorites', 0);
      ''');
    }
    if (populated) {
      db.execute('INSERT INTO $table (id, type) VALUES (?, ?);', [
        'fixture-comic',
        0,
      ]);
    }
  } finally {
    db.dispose();
  }
}

class _UnreadableOnboardingFile implements File {
  _UnreadableOnboardingFile(this.path);

  @override
  final String path;

  @override
  Future<bool> exists() async => true;

  @override
  Future<String> readAsString({Encoding encoding = utf8}) async {
    throw FileSystemException('Fixture read failure', path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late File record;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venerax_onboarding_');
    record = File('${directory.path}/${OnboardingStore.fileName}');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'a fresh installation requires agreement and the remaining setup',
    () async {
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.initialized, isTrue);
      expect(store.loadError, isNull);
      expect(store.state.setupCompleted, isFalse);
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);
      expect(await record.exists(), isTrue);
      await expectLater(store.completeSetup(), throwsStateError);
      expect(store.state.setupCompleted, isFalse);
    },
  );

  for (final marker in ['appdata.json', 'history.db', 'comic_source']) {
    test('existing $marker skips setup but still requires agreement', () async {
      if (marker == 'comic_source') {
        await Directory('${directory.path}/$marker').create();
      } else {
        await File('${directory.path}/$marker').create();
      }
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.state.setupCompleted, isTrue);
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);

      await store.accept('zh-CN');

      expect(store.state.setupCompleted, isTrue);
      expect(store.blocksAutomaticTasks, isFalse);
      expect(
        await FileSystemEntity.type('${directory.path}/$marker'),
        marker == 'comic_source'
            ? FileSystemEntityType.directory
            : FileSystemEntityType.file,
      );
    });
  }

  test(
    'unfinished setup stays new after initialization creates app data',
    () async {
      final firstLaunch = OnboardingStore();
      await firstLaunch.load(directory.path);
      await File('${directory.path}/appdata.json').writeAsString('{}');
      await File('${directory.path}/history.db').create();
      await Directory('${directory.path}/comic_source').create();

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);

      expect(nextLaunch.state.setupCompleted, isFalse);
      expect(nextLaunch.state.needsAgreement(), isTrue);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
    },
  );

  test(
    'existing usage repairs stale unfinished setup without accepting agreement',
    () async {
      final firstLaunch = OnboardingStore();
      await firstLaunch.load(directory.path);
      final appData = File('${directory.path}/appdata.json');
      final existingData = jsonEncode({
        'settings': <String, Object?>{},
        'searchHistory': ['fixture query'],
      });
      await appData.writeAsString(existingData);

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);

      expect(nextLaunch.state.setupCompleted, isTrue);
      expect(nextLaunch.state.acceptedVersion, 0);
      expect(nextLaunch.state.acceptedAt, isNull);
      expect(nextLaunch.state.acceptedLanguage, isNull);
      expect(nextLaunch.state.needsAgreement(), isTrue);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
      expect(await appData.readAsString(), existingData);
      expect(
        (jsonDecode(await record.readAsString()) as Map)['setupCompleted'],
        isTrue,
      );
    },
  );

  test(
    'empty initialized SQLite stores and folder metadata keep setup unfinished',
    () async {
      final firstLaunch = OnboardingStore();
      await firstLaunch.load(directory.path);
      final history = File('${directory.path}/history.db');
      final favorites = File('${directory.path}/local_favorite.db');
      _createUsageDatabase(history);
      _createUsageDatabase(favorites, favorite: true);
      final historyBytes = await history.readAsBytes();
      final favoriteBytes = await favorites.readAsBytes();

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);

      expect(nextLaunch.loadError, isNull);
      expect(nextLaunch.state.setupCompleted, isFalse);
      expect(nextLaunch.state.needsAgreement(), isTrue);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
      expect(await history.readAsBytes(), historyBytes);
      expect(await favorites.readAsBytes(), favoriteBytes);
    },
  );

  for (final favorite in [false, true]) {
    final name = favorite ? 'quoted favorite folder' : 'history';
    test('restored $name keeps setup unfinished', () async {
      final firstLaunch = OnboardingStore();
      await firstLaunch.load(directory.path);
      await firstLaunch.accept('zh-TW', version: kDisclaimerVersion + 1);
      final accepted = firstLaunch.state;
      final database = File(
        '${directory.path}/${favorite ? 'local_favorite.db' : 'history.db'}',
      );
      _createUsageDatabase(
        database,
        favorite: favorite,
        populated: true,
        folder: 'Reader\'s "shelf"; DROP TABLE folder_order; --',
      );
      final previousBytes = await database.readAsBytes();

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);

      expect(nextLaunch.loadError, isNull);
      expect(nextLaunch.state.setupCompleted, isFalse);
      expect(nextLaunch.state.acceptedVersion, accepted.acceptedVersion);
      expect(nextLaunch.state.acceptedAt, accepted.acceptedAt);
      expect(nextLaunch.state.acceptedLanguage, accepted.acceptedLanguage);
      expect(nextLaunch.state.needsAgreement(), isFalse);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
      expect(await database.readAsBytes(), previousBytes);
      expect(jsonDecode(await record.readAsString()), accepted.toJson());
    });
  }

  test('a busy usage database blocks setup and permits a safe retry', () async {
    final firstLaunch = OnboardingStore();
    await firstLaunch.load(directory.path);
    final previousRecord = await record.readAsString();
    final database = File('${directory.path}/history.db');
    _createUsageDatabase(database, populated: true);
    final nextLaunch = OnboardingStore();
    final locked = openRawDatabase(database.path);
    try {
      locked.execute('BEGIN EXCLUSIVE;');

      await nextLaunch.load(directory.path);

      expect(nextLaunch.loadError, isA<SqliteException>());
      expect((nextLaunch.loadError as SqliteException).resultCode, 5);
      expect(nextLaunch.state.setupCompleted, isFalse);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
      expect(await record.readAsString(), previousRecord);
      locked.execute('ROLLBACK;');
    } finally {
      locked.dispose();
    }

    await nextLaunch.load(directory.path);

    expect(nextLaunch.loadError, isNull);
    expect(nextLaunch.state.setupCompleted, isTrue);
    expect(nextLaunch.state.acceptedAt, firstLaunch.state.acceptedAt);
    expect(nextLaunch.state.acceptedLanguage, isNull);
    expect(nextLaunch.state.needsAgreement(), isTrue);
    expect(nextLaunch.blocksAutomaticTasks, isTrue);
    expect(
      (jsonDecode(await record.readAsString()) as Map)['setupCompleted'],
      isTrue,
    );
  });

  test(
    'acceptance persists its version, UTC time and language before setup',
    () async {
      final store = OnboardingStore();
      await store.load(directory.path);

      await store.accept('zh-TW');

      expect(store.state.acceptedVersion, kDisclaimerVersion);
      expect(store.state.acceptedLanguage, 'zh-TW');
      expect(DateTime.parse(store.state.acceptedAt!).isUtc, isTrue);
      expect(store.state.needsAgreement(), isFalse);
      expect(store.state.setupCompleted, isFalse);
      expect(store.blocksAutomaticTasks, isTrue);
      final saved = jsonDecode(await record.readAsString()) as Map;
      expect(saved['acceptedVersion'], kDisclaimerVersion);
      expect(saved['acceptedAt'], store.state.acceptedAt);
      expect(saved['acceptedLanguage'], 'zh-TW');
      expect(saved['setupCompleted'], isFalse);

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);
      expect(nextLaunch.state.acceptedAt, store.state.acceptedAt);
      expect(nextLaunch.state.acceptedLanguage, 'zh-TW');
      expect(nextLaunch.state.needsAgreement(), isFalse);
      expect(nextLaunch.state.setupCompleted, isFalse);
      expect(nextLaunch.blocksAutomaticTasks, isTrue);
    },
  );

  test('completed setup does not prompt again on the next launch', () async {
    final store = OnboardingStore();
    await store.load(directory.path);
    await store.accept('en-US');
    final acceptedAt = store.state.acceptedAt;

    await store.completeSetup();

    final nextLaunch = OnboardingStore();
    await nextLaunch.load(directory.path);
    expect(nextLaunch.state.setupCompleted, isTrue);
    expect(nextLaunch.state.needsAgreement(), isFalse);
    expect(nextLaunch.blocksAutomaticTasks, isFalse);
    expect(nextLaunch.state.acceptedAt, acceptedAt);
    expect(nextLaunch.state.acceptedLanguage, 'en-US');
  });

  test(
    'a higher agreement version needs acceptance without repeating setup',
    () async {
      final store = OnboardingStore();
      await store.load(directory.path);
      await store.accept('en-US');
      await store.completeSetup();
      final nextVersion = kDisclaimerVersion + 1;

      expect(store.state.needsAgreement(nextVersion), isTrue);
      expect(store.state.setupCompleted, isTrue);

      await store.accept('zh-CN', version: nextVersion);

      final nextLaunch = OnboardingStore();
      await nextLaunch.load(directory.path);
      expect(nextLaunch.state.acceptedVersion, nextVersion);
      expect(nextLaunch.state.needsAgreement(nextVersion), isFalse);
      expect(nextLaunch.state.needsAgreement(kDisclaimerVersion), isFalse);
      expect(nextLaunch.state.setupCompleted, isTrue);
      expect(nextLaunch.state.acceptedLanguage, 'zh-CN');
    },
  );

  for (final contents in ['{"acceptedVersion":', '[]', '{}']) {
    test(
      'damaged record $contents cannot authorize an existing installation',
      () async {
        final appData = File('${directory.path}/appdata.json');
        await appData.writeAsString('{"keep":"existing data"}');
        await record.writeAsString(contents);
        final store = OnboardingStore();

        await store.load(directory.path);

        expect(store.loadError, isNull);
        expect(store.state.setupCompleted, isTrue);
        expect(store.state.acceptedVersion, 0);
        expect(store.state.needsAgreement(), isTrue);
        expect(store.blocksAutomaticTasks, isTrue);
        expect(await appData.readAsString(), '{"keep":"existing data"}');
      },
    );
  }

  final invalidAcceptance = <String, Map<String, Object?>>{
    'missing version': {'acceptedVersion': null},
    'non-integer version': {'acceptedVersion': '$kDisclaimerVersion'},
    'zero version': {'acceptedVersion': 0},
    'missing time': {'acceptedAt': null},
    'invalid time': {'acceptedAt': 'not a date'},
    'missing language': {'acceptedLanguage': null},
    'empty language': {'acceptedLanguage': ''},
  };
  for (final entry in invalidAcceptance.entries) {
    test('${entry.key} cannot count as acceptance', () async {
      await record.writeAsString(
        jsonEncode({
          'setupCompleted': true,
          'acceptedVersion': kDisclaimerVersion,
          'acceptedAt': '2026-11-10T00:00:00.000Z',
          'acceptedLanguage': 'zh-CN',
          ...entry.value,
        }),
      );
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.state.setupCompleted, isTrue);
      expect(store.state.acceptedVersion, 0);
      expect(store.state.acceptedAt, isNull);
      expect(store.state.acceptedLanguage, isNull);
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);
    });
  }

  test(
    'a failed acceptance save preserves memory and the saved record',
    () async {
      final store = OnboardingStore();
      await store.load(directory.path);
      final previousState = store.state;
      final previousRecord = await record.readAsString();
      await Directory('${record.path}.tmp').create();

      await expectLater(
        store.accept('zh-CN'),
        throwsA(isA<FileSystemException>()),
      );

      expect(store.state, same(previousState));
      expect(store.state.needsAgreement(), isTrue);
      expect(store.blocksAutomaticTasks, isTrue);
      expect(await record.readAsString(), previousRecord);
    },
  );

  test('a failed completion save does not skip setup on restart', () async {
    final store = OnboardingStore();
    await store.load(directory.path);
    await store.accept('zh-CN');
    final previousState = store.state;
    await Directory('${record.path}.tmp').create();

    await expectLater(
      store.completeSetup(),
      throwsA(isA<FileSystemException>()),
    );

    expect(store.state, same(previousState));
    final nextLaunch = OnboardingStore();
    await nextLaunch.load(directory.path);
    expect(nextLaunch.state.needsAgreement(), isFalse);
    expect(nextLaunch.state.setupCompleted, isFalse);
    expect(nextLaunch.blocksAutomaticTasks, isTrue);
  });

  for (final source in ['appdata.json', 'implicitData.json']) {
    test('acceptance flags in $source do not authorize this device', () async {
      await File('${directory.path}/$source').writeAsString(
        jsonEncode({
          'disclaimerConsented': true,
          'settings': {'disclaimerConsented': true},
          'setupCompleted': true,
          'acceptedVersion': kDisclaimerVersion,
          'acceptedAt': '2026-11-10T00:00:00.000Z',
          'acceptedLanguage': 'zh-CN',
        }),
      );
      final store = OnboardingStore();

      await store.load(directory.path);

      expect(store.state.setupCompleted, isTrue);
      expect(store.state.acceptedVersion, 0);
      expect(store.state.acceptedAt, isNull);
      expect(store.state.acceptedLanguage, isNull);
      expect(store.blocksAutomaticTasks, isTrue);
    });
  }

  test(
    'a read failure blocks actions until the saved record can be retried',
    () async {
      final firstLaunch = OnboardingStore();
      await firstLaunch.load(directory.path);
      await firstLaunch.accept('en-US');
      await firstLaunch.completeSetup();
      final previousRecord = await record.readAsString();
      final store = OnboardingStore();

      await IOOverrides.runZoned(
        () => store.load(directory.path),
        createFile: (path) => _UnreadableOnboardingFile(path),
      );

      expect(store.initialized, isTrue);
      expect(store.loadError, isA<FileSystemException>());
      expect(store.blocksAutomaticTasks, isTrue);
      await expectLater(store.accept('zh-CN'), throwsStateError);
      await expectLater(store.completeSetup(), throwsStateError);
      expect(await record.readAsString(), previousRecord);

      await store.load(directory.path);

      expect(store.loadError, isNull);
      expect(store.state.setupCompleted, isTrue);
      expect(store.state.acceptedVersion, kDisclaimerVersion);
      expect(store.state.acceptedLanguage, 'en-US');
      expect(store.blocksAutomaticTasks, isFalse);
      expect(await record.readAsString(), previousRecord);
    },
  );
}

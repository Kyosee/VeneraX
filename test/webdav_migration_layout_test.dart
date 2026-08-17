import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/webdav_migration_tasks.dart';

// The WebDAV comic source browses a folder tree named by titles; these pure
// helpers map a local comic's obscure on-disk names onto that layout (#149).
// Only the naming logic is unit-tested — the upload itself is real network IO.
void main() {
  group('migrationUniqueFolderName', () {
    test('sanitizes illegal path chars', () {
      final used = <String>{};
      expect(
        migrationUniqueFolderName('a/b:c*d?', used),
        'a_b_c_d_',
      );
    });

    test('de-duplicates collisions with numeric suffixes', () {
      final used = <String>{};
      expect(migrationUniqueFolderName('Title', used), 'Title');
      expect(migrationUniqueFolderName('Title', used), 'Title (2)');
      expect(migrationUniqueFolderName('Title', used), 'Title (3)');
    });

    test('falls back to a non-empty name when title sanitizes to empty', () {
      final used = <String>{};
      final name = migrationUniqueFolderName('///', used);
      expect(name.isNotEmpty, isTrue);
    });

    test('trims trailing dots and collapses whitespace', () {
      final used = <String>{};
      expect(migrationUniqueFolderName('  a   b .. ', used), 'a b');
    });
  });

  group('migrationChapterFolderName', () {
    test('adds zero-padded numeric prefix when requested', () {
      final used = <String>{};
      // 12 chapters -> width 2.
      expect(
        migrationChapterFolderName('Prologue', 0, 12,
            numericPrefix: true, used: used),
        '01_Prologue',
      );
      expect(
        migrationChapterFolderName('Ch 10', 9, 12,
            numericPrefix: true, used: used),
        '10_Ch 10',
      );
    });

    test('omits prefix when not requested', () {
      final used = <String>{};
      expect(
        migrationChapterFolderName('Prologue', 0, 12,
            numericPrefix: false, used: used),
        'Prologue',
      );
    });

    test('prefix preserves order that titles alone would scramble', () {
      // Natural-sorted by folder name, "Chapter 1"/"Chapter 10"/"Chapter 2"
      // would order 1,10,2 without the prefix. With it, source order holds.
      final used = <String>{};
      final names = [
        migrationChapterFolderName('Chapter 1', 0, 3,
            numericPrefix: true, used: used),
        migrationChapterFolderName('Chapter 2', 1, 3,
            numericPrefix: true, used: used),
        migrationChapterFolderName('Chapter 10', 2, 3,
            numericPrefix: true, used: used),
      ];
      final sorted = [...names]..sort();
      expect(sorted, names); // lexical order matches reading order
    });

    test('de-duplicates same-titled chapters', () {
      final used = <String>{};
      expect(
        migrationChapterFolderName('Extra', 0, 2,
            numericPrefix: false, used: used),
        'Extra',
      );
      expect(
        migrationChapterFolderName('Extra', 1, 2,
            numericPrefix: false, used: used),
        'Extra (2)',
      );
    });
  });

  group('migrationImageName', () {
    test('zero-pads to at least width 3', () {
      expect(migrationImageName(0, 5, 'jpg'), '001.jpg');
      expect(migrationImageName(4, 5, 'png'), '005.png');
    });

    test('widens padding for large page counts', () {
      expect(migrationImageName(0, 1000, 'webp'), '0001.webp');
    });

    test('falls back to jpg when extension missing', () {
      expect(migrationImageName(0, 3, ''), '001.jpg');
      expect(migrationImageName(0, 3, '   '), '001.jpg');
    });
  });

  group('migrationExtOf', () {
    test('extracts lower-case extension', () {
      expect(migrationExtOf('/a/b/c.JPG'), 'jpg');
      expect(migrationExtOf('file:///x/y/1.webp'), 'webp');
    });

    test('handles windows separators', () {
      expect(migrationExtOf(r'C:\comics\1.PNG'), 'png');
    });

    test('returns empty when no extension', () {
      expect(migrationExtOf('/a/b/cover'), '');
      expect(migrationExtOf('/a/b/trailing.'), '');
    });
  });

  group('prepareWebdavMigrationUpload', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('venera_webdav_migration_');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    LocalComic comic({
      required ComicChapters chapters,
      required List<String> downloaded,
    }) => LocalComic(
      id: 'comic',
      title: 'Comic',
      subtitle: '',
      tags: const [],
      directory: tempDir.path,
      chapters: chapters,
      cover: 'cover.jpg',
      comicType: ComicType(0),
      downloadedChapters: downloaded,
      createdAt: DateTime(2026, 1, 1),
    );

    String path(String name) => '${tempDir.path}${Platform.pathSeparator}$name';

    test('reports every missing or empty downloaded chapter', () async {
      final goodDir = Directory(path('good'))..createSync();
      File(
        '${goodDir.path}${Platform.pathSeparator}1.jpg',
      ).writeAsStringSync('page');
      Directory(path('empty')).createSync();
      final local = comic(
        chapters: const ComicChapters({
          'good': 'Chapter 1',
          'missing': 'Chapter 2',
          'empty': 'Chapter 3',
        }),
        downloaded: const ['good', 'missing', 'empty'],
      );

      final plan = await prepareWebdavMigrationUpload(
        comic: local,
        comicDir: '/remote/Comic/',
        numericPrefix: false,
      );

      expect(plan.uploads, hasLength(1));
      expect(plan.uploads.single.chapterTitle, 'Chapter 1');
      expect(
        plan.failures.map((failure) => (failure.chapterTitle, failure.reason)),
        containsAll([
          ('Chapter 2', WebdavMigrationFailureReason.directoryMissing),
          ('Chapter 3', WebdavMigrationFailureReason.noImages),
        ]),
      );
    });

    test('includes the group name in a grouped chapter failure', () async {
      final goodDir = Directory(path('volume-1'))..createSync();
      File(
        '${goodDir.path}${Platform.pathSeparator}1.jpg',
      ).writeAsStringSync('page');
      final local = comic(
        chapters: const ComicChapters.grouped({
          'Volumes': {'volume-1': 'Volume 1', 'volume-2': 'Volume 2'},
        }),
        downloaded: const ['volume-1', 'volume-2'],
      );

      final plan = await prepareWebdavMigrationUpload(
        comic: local,
        comicDir: '/remote/Comic/',
        numericPrefix: true,
      );

      expect(plan.failures, hasLength(1));
      expect(plan.failures.single.chapterTitle, 'Volumes / Volume 2');
      expect(
        plan.failures.single.reason,
        WebdavMigrationFailureReason.directoryMissing,
      );
      final groupIndex = plan.remoteDirectories.indexOf(
        '/remote/Comic/1_Volumes/',
      );
      final chapterIndex = plan.remoteDirectories.indexOf(
        '/remote/Comic/1_Volumes/1_Volume 1/',
      );
      expect(groupIndex, greaterThanOrEqualTo(0));
      expect(chapterIndex, greaterThan(groupIndex));
    });
  });

  // The skip-existing choice and the comics it excluded must survive a restart:
  // the decision is made once and then frozen, so losing it would let a resume
  // re-decide against folders the task itself created (#160).
  group('WebdavMigrationTask persistence', () {
    WebdavMigrationTask newTask({required bool skipExisting}) =>
        WebdavMigrationTask(
          id: '1',
          comics: [
            MigrationComicRef(id: 'a', comicTypeValue: 0, title: 'A'),
          ],
          createdAt: DateTime(2026, 1, 1),
          numericPrefix: false,
          skipExisting: skipExisting,
          librarySourceKey: 'webdav_lib',
        );

    test('round-trips the skip choice and the skipped comics', () {
      final task = newTask(skipExisting: true);
      task.skippedKeys = {'a_0'};
      task.doneKeys.addAll(task.skippedKeys!);

      final restored = WebdavMigrationTask.fromJson(task.toJson());

      expect(restored.skipExisting, isTrue);
      expect(restored.skippedKeys, {'a_0'});
      expect(restored.skippedCount, 1);
      expect(restored.doneKeys, contains('a_0'));
    });

    test('round-trips structured failure details', () {
      final task = newTask(skipExisting: false)
        ..failedCount = 1
        ..doneKeys.add('a_0')
        ..failures.add(
          const WebdavMigrationFailure(
            comicKey: 'a_0',
            comicTitle: 'A',
            chapterTitle: 'Volume 2',
            reason: WebdavMigrationFailureReason.directoryMissing,
          ),
        );

      final restored = WebdavMigrationTask.fromJson(task.toJson());

      expect(restored.failedCount, 1);
      expect(restored.failures, hasLength(1));
      expect(restored.failures.single.comicTitle, 'A');
      expect(restored.failures.single.chapterTitle, 'Volume 2');
      expect(
        restored.failures.single.reason,
        WebdavMigrationFailureReason.directoryMissing,
      );
    });

    test('keeps an unresolved decision unresolved', () {
      final restored =
          WebdavMigrationTask.fromJson(newTask(skipExisting: true).toJson());

      expect(restored.skippedKeys, isNull);
      expect(restored.skippedCount, 0);
    });

    test('a task saved before the option existed still uploads everything', () {
      final json = newTask(skipExisting: true).toJson()
        ..remove('skipExisting')
        ..remove('skippedKeys');

      final restored = WebdavMigrationTask.fromJson(json);

      expect(restored.skipExisting, isFalse);
      expect(restored.skippedKeys, isNull);
    });

    test(
      'a task saved before failure details existed restores an empty list',
      () {
        final json = newTask(skipExisting: false).toJson()..remove('failures');

        final restored = WebdavMigrationTask.fromJson(json);

        expect(restored.failures, isEmpty);
      },
    );
  });
}

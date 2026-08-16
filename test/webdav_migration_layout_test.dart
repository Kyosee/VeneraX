import 'package:flutter_test/flutter_test.dart';
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
  });
}

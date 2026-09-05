import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/follow_updates.dart';

FavoriteItemWithUpdateInfo _comic(
  String id, {
  int? lastCheckTime,
  bool hasNewUpdate = false,
}) {
  return FavoriteItemWithUpdateInfo(
    FavoriteItem(
      id: id,
      name: id,
      coverPath: '',
      author: '',
      type: ComicType.local,
      tags: const [],
    ),
    null,
    hasNewUpdate,
    lastCheckTime,
  );
}

void main() {
  group('scope resolution', () {
    test('all folders covers whatever the store currently holds', () {
      expect(
        FollowUpdateScope.resolveFolders(
          allFolders: true,
          selected: const ['a'],
          existing: const ['a', 'b', 'c'],
        ),
        ['a', 'b', 'c'],
      );
    });

    test('selection keeps store order and drops deleted folders', () {
      expect(
        FollowUpdateScope.resolveFolders(
          allFolders: false,
          selected: const ['c', 'gone', 'a'],
          existing: const ['a', 'b', 'c'],
        ),
        ['a', 'c'],
      );
    });

    test('empty selection means nothing is followed', () {
      expect(
        FollowUpdateScope.resolveFolders(
          allFolders: false,
          selected: const [],
          existing: const ['a'],
        ),
        isEmpty,
      );
    });
  });

  group('check interval', () {
    final now = DateTime(2026, 9, 5, 12);

    test('a comic never checked is always due', () {
      expect(FollowUpdateScope.isDue(null, now: now, interval: 24), isTrue);
    });

    test('within the interval it is skipped', () {
      expect(
        FollowUpdateScope.isDue(
          now.subtract(const Duration(hours: 5)),
          now: now,
          interval: 6,
        ),
        isFalse,
      );
    });

    test('at and past the interval it is due again', () {
      expect(
        FollowUpdateScope.isDue(
          now.subtract(const Duration(hours: 6)),
          now: now,
          interval: 6,
        ),
        isTrue,
      );
      expect(
        FollowUpdateScope.isDue(
          now.subtract(const Duration(hours: 7)),
          now: now,
          interval: 6,
        ),
        isTrue,
      );
    });

    test('a shorter interval makes a recent check due', () {
      final lastCheck = now.subtract(const Duration(hours: 2));
      expect(
        FollowUpdateScope.isDue(lastCheck, now: now, interval: 24),
        isFalse,
      );
      expect(FollowUpdateScope.isDue(lastCheck, now: now, interval: 1), isTrue);
    });
  });

  group('cross-folder dedupe', () {
    test('a comic in several folders is checked once, written to all', () {
      var entries = dedupeFollowUpdateEntries({
        'first': [_comic('1'), _comic('2')],
        'second': [_comic('2'), _comic('3')],
      });
      expect(entries.map((e) => e.comic.id), ['1', '2', '3']);
      expect(entries.map((e) => e.folders), [
        ['first'],
        ['first', 'second'],
        ['second'],
      ]);
    });

    test('same id in different sources stays two comics', () {
      var shared = FavoriteItemWithUpdateInfo(
        FavoriteItem(
          id: '1',
          name: '1',
          coverPath: '',
          author: '',
          type: const ComicType(7),
          tags: const [],
        ),
        null,
        false,
        null,
      );
      var entries = dedupeFollowUpdateEntries({
        'first': [_comic('1'), shared],
      });
      expect(entries.length, 2);
    });

    test('no folders means nothing to check', () {
      expect(dedupeFollowUpdateEntries({}), isEmpty);
    });

    test('a duplicate records every folder it was found in', () {
      var entries = dedupeFollowUpdateEntries({
        'a': [_comic('1')],
        'b': [_comic('1')],
        'c': [_comic('1')],
      });
      expect(entries.length, 1);
      expect(entries.single.folders, ['a', 'b', 'c']);
    });
  });

  group('empty scope', () {
    // A fresh install follows no folder, and the page sorts whatever the store
    // returns. sort() throws on an unmodifiable list even when it is empty, so
    // an empty result must still be growable.
    test('an empty query result can be sorted', () {
      final db = sqlite3.openInMemory();
      final rows = LocalFavoritesManager.queryComicsWithUpdatesInfoIn(
        const [],
        db,
      );
      expect(rows, isEmpty);
      expect(() => rows.sort((a, b) => 0), returnsNormally);
      db.dispose();
    });

    test('a store that is down returns a growable list', () {
      // Never initialized in a unit test, so this takes the degraded path.
      final rows = LocalFavoritesManager().getComicsWithUpdatesInfoIn(const [
        'nope',
      ]);
      expect(rows, isEmpty);
      expect(() => rows.sort((a, b) => 0), returnsNormally);
    });

    test('a task restored without folders carries a growable list', () {
      final task = FollowUpdateTask.fromJson({'id': '1', 'sources': {}});
      expect(task.folders, isEmpty);
      expect(() => task.folders.add('later'), returnsNormally);
    });
  });

  group('fixed check time', () {
    test('an unset or malformed value never blocks a check', () {
      final now = DateTime(2026, 9, 5, 3);
      expect(FollowUpdateScope.isPastFixedTime('', now), isTrue);
      expect(FollowUpdateScope.isPastFixedTime('nonsense', now), isTrue);
      expect(FollowUpdateScope.isPastFixedTime('24:00', now), isTrue);
      expect(FollowUpdateScope.isPastFixedTime('08:60', now), isTrue);
    });

    test('checks wait until the time of day passes', () {
      expect(
        FollowUpdateScope.isPastFixedTime('08:30', DateTime(2026, 9, 5, 8, 29)),
        isFalse,
      );
      expect(
        FollowUpdateScope.isPastFixedTime('08:30', DateTime(2026, 9, 5, 8, 30)),
        isTrue,
      );
      expect(
        FollowUpdateScope.isPastFixedTime('08:30', DateTime(2026, 9, 5, 23)),
        isTrue,
      );
    });

    test('parsing accepts a valid time and rejects the rest', () {
      expect(FollowUpdateScope.parseFixedTime('00:00'), (hour: 0, minute: 0));
      expect(FollowUpdateScope.parseFixedTime('23:59'), (hour: 23, minute: 59));
      expect(FollowUpdateScope.parseFixedTime('7:5'), (hour: 7, minute: 5));
      expect(FollowUpdateScope.parseFixedTime('-1:00'), isNull);
      expect(FollowUpdateScope.parseFixedTime('12'), isNull);
      expect(FollowUpdateScope.parseFixedTime('12:00:00'), isNull);
    });
  });
}

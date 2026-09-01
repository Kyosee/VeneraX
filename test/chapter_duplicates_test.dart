import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/chapter_duplicates.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

void main() {
  group('findDuplicateTitleIndices', () {
    test('keeps the first occurrence and reports later repeats', () {
      final res = findDuplicateTitleIndices(
        count: 4,
        titleOf: (i) => ['第1话', '第2话', '第1话', '第2话'][i],
      );
      expect(res, {2, 3});
    });

    test('compares trimmed titles but never collapses blank ones', () {
      final res = findDuplicateTitleIndices(
        count: 4,
        titleOf: (i) => ['第1话', ' 第1话 ', '', '   '][i],
      );
      expect(res, {1});
    });

    test('scopes are independent: same title in two scopes is not a repeat', () {
      final res = findDuplicateTitleIndices(
        count: 4,
        titleOf: (i) => ['第1话', '第1话', '第1话', '第2话'][i],
        scopes: [
          [0, 1],
          [2, 3],
        ],
      );
      // index 1 repeats inside scope 0; index 2 is the first of scope 1.
      expect(res, {1});
    });

    test('indices covered by no scope are never reported', () {
      final res = findDuplicateTitleIndices(
        count: 3,
        titleOf: (i) => ['x', 'x', 'x'][i],
        scopes: [
          [0, 1],
        ],
      );
      expect(res, {1});
    });
  });

  group('ComicChapters.duplicateTitleIndices', () {
    test('flat chapters collapse repeats', () {
      final chapters = ComicChapters({
        'a': '第1话',
        'b': '第2话',
        'c': '第1话',
      });
      expect(chapters.duplicateTitleIndices(), {2});
    });

    test('a title shared across groups is left alone', () {
      final chapters = ComicChapters.grouped({
        '英文版': {'e1': '第一话', 'e2': '第二话'},
        '西班牙语': {'s1': '第一话', 's2': '第二话'},
      });
      expect(chapters.duplicateTitleIndices(), isEmpty);
    });

    test('repeats within one group are reported at flat indices', () {
      final chapters = ComicChapters.grouped({
        '英文版': {'e1': '第一话', 'e2': '第一话'},
        '西班牙语': {'s1': '第一话', 's2': '第二话', 's3': '第二话'},
      });
      // Flat order is group order: e1=0, e2=1, s1=2, s2=3, s3=4.
      expect(chapters.duplicateTitleIndices(), {1, 4});
    });

    test('a comic with no repeats reports nothing', () {
      final chapters = ComicChapters({'a': '第1话', 'b': '第2话'});
      expect(chapters.duplicateTitleIndices(), isEmpty);
    });
  });

  // The whole feature is display-only: every consumer (reader, download picker,
  // pre-translate) addresses chapters by their ORIGINAL flat index, so filtering
  // must remove entries without renumbering the survivors.
  group('visible-index mapping preserves original indices', () {
    test('hiding does not renumber the chapters that remain', () {
      final chapters = ComicChapters({
        'a': '第1话',
        'b': '第2话',
        'c': '第1话',
        'd': '第3话',
      });
      final hidden = chapters.duplicateTitleIndices();
      final visible = [
        for (var i = 0; i < chapters.length; i++)
          if (!hidden.contains(i)) i,
      ];
      expect(visible, [0, 1, 3]);
      // Display slot 2 must resolve to chapter 'd' at flat index 3, not 2.
      expect(chapters.ids.elementAt(visible[2]), 'd');
    });

    test('grouped: within-group positions survive the filter', () {
      final chapters = ComicChapters.grouped({
        '英文版': {'e1': '第一话', 'e2': '第一话', 'e3': '第二话'},
        '西班牙语': {'s1': '第一话'},
      });
      final hidden = chapters.duplicateTitleIndices();
      expect(hidden, {1});

      // Second group's offset is unaffected by hiding inside the first.
      const secondGroupOffset = 3;
      final group = chapters.getGroupByIndex(1);
      final visible = [
        for (var i = 0; i < group.length; i++)
          if (!hidden.contains(secondGroupOffset + i)) i,
      ];
      expect(visible, [0]);
      expect(group.keys.elementAt(visible[0]), 's1');
    });
  });

  group('nextVisibleChapter', () {
    // Ungrouped: one scope, so group edges never stop a skip.
    int? flat(int from, int step, Set<int> hidden, {int max = 6}) =>
        nextVisibleChapter(
          from: from,
          step: step,
          maxChapter: max,
          isHidden: hidden.contains,
          groupOf: (_) => 0,
        );

    test('returns the immediate neighbour when nothing is hidden', () {
      expect(flat(3, 1, {}), 4);
      expect(flat(3, -1, {}), 2);
    });

    test('skips a run of hidden chapters in both directions', () {
      expect(flat(1, 1, {2, 3, 4}), 5);
      expect(flat(6, -1, {5, 4, 3}), 2);
    });

    test('returns null past the ends', () {
      expect(flat(6, 1, {}), isNull);
      expect(flat(1, -1, {}), isNull);
    });

    test('returns null when every remaining chapter is hidden', () {
      expect(flat(4, 1, {5, 6}), isNull);
      expect(flat(3, -1, {1, 2}), isNull);
    });

    test('a hidden current chapter does not block leaving it', () {
      expect(flat(3, 1, {3}), 4);
    });

    // Grouped: chapters 1-3 in group 0, 4-6 in group 1.
    int? grouped(int from, int step, Set<int> hidden) => nextVisibleChapter(
      from: from,
      step: step,
      maxChapter: 6,
      isHidden: hidden.contains,
      groupOf: (c) => c <= 3 ? 0 : 1,
    );

    test('the first step may cross a group boundary', () {
      expect(grouped(3, 1, {}), 4);
      expect(grouped(4, -1, {}), 3);
    });

    test('skipping never crosses a second boundary', () {
      // 4 is hidden, so a skip would land in group 1 -> refuse instead.
      expect(grouped(3, 1, {4}), isNull);
      expect(grouped(4, -1, {3}), isNull);
    });

    test('skipping stays inside the starting group', () {
      // From 1, chapters 2-3 are hidden: 4 would be the next group -> refuse.
      expect(grouped(1, 1, {2, 3}), isNull);
      expect(grouped(6, -1, {5, 4}), isNull);
      // Within the group, skipping is fine.
      expect(grouped(1, 1, {2}), 3);
      expect(grouped(6, -1, {5}), 4);
    });
  });
}

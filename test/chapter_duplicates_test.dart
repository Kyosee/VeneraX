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
}

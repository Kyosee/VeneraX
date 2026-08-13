import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

List<String> apply(List<String> keys, dynamic stored) =>
    ComicSourceManager.sortedIndices(keys, stored).map((i) => keys[i]).toList();

void main() {
  group('stored arrangement', () {
    test('reorders registered sources into the stored order', () {
      expect(
        apply(['a', 'b', 'c'], ['c', 'a', 'b']),
        ['c', 'a', 'b'],
      );
    });

    test('keeps registration order when nothing is stored', () {
      expect(apply(['a', 'b', 'c'], null), ['a', 'b', 'c']);
      expect(apply(['a', 'b', 'c'], []), ['a', 'b', 'c']);
      expect(apply(['a', 'b', 'c'], 'not a list'), ['a', 'b', 'c']);
    });

    test('puts a newly installed source after the arranged ones', () {
      expect(
        apply(['a', 'b', 'new'], ['b', 'a']),
        ['b', 'a', 'new'],
      );
    });

    test('keeps several new sources in registration order', () {
      expect(
        apply(['x', 'a', 'y'], ['a']),
        ['a', 'x', 'y'],
      );
    });

    test('ignores stored keys whose source is gone', () {
      expect(
        apply(['a', 'c'], ['c', 'removed', 'a']),
        ['c', 'a'],
      );
    });

    test('tolerates a duplicated stored key', () {
      expect(
        apply(['a', 'b'], ['b', 'b', 'a']),
        ['b', 'a'],
      );
    });
  });

  group('merge', () {
    test('rearranges only the named keys, leaving others in place', () {
      // 'lib' is a native source the manage screen hides, so the UI never
      // names it; it must not be pushed to the end.
      expect(
        ComicSourceManager.mergeOrder(['a', 'lib', 'b'], ['b', 'a']),
        ['b', 'lib', 'a'],
      );
    });

    test('is a no-op when the named order is unchanged', () {
      expect(
        ComicSourceManager.mergeOrder(['a', 'b', 'c'], ['a', 'b', 'c']),
        ['a', 'b', 'c'],
      );
    });

    test('ignores names that are not registered', () {
      expect(
        ComicSourceManager.mergeOrder(['a', 'b'], ['b', 'ghost', 'a']),
        ['b', 'a'],
      );
    });
  });
}

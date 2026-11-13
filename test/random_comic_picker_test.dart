import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/random_comic_picker.dart';

FavoriteItem favorite(String id, int type) => FavoriteItem(
  id: id,
  name: 'Comic $id',
  coverPath: '',
  author: '',
  type: ComicType(type),
  tags: const [],
);

void main() {
  group('UniformRandomComicPicker', () {
    test('batch draws are distinct and do not mutate round exclusions', () {
      final picker = UniformRandomComicPicker(random: Random(4));
      final candidates = List.generate(5, (i) => favorite('$i', 1));
      final excluded = {randomComicIdentity(candidates.first)};

      final result = picker.pickMany(candidates, count: 3, excluded: excluded);

      expect(result, hasLength(3));
      expect(result.map(randomComicIdentity).toSet(), hasLength(3));
      expect(result, isNot(contains(candidates.first)));
      expect(excluded, {randomComicIdentity(candidates.first)});
    });

    test('batch stops at the end of the round without repeating comics', () {
      final picker = UniformRandomComicPicker(random: Random(4));
      final first = favorite('a', 1);
      final second = favorite('b', 1);

      expect(
        picker.pickMany(
          [first, first, second],
          count: 3,
          excluded: {randomComicIdentity(first)},
        ),
        [second],
      );
      expect(picker.pickMany(const [], count: 3), isEmpty);
      expect(picker.pickMany([first], count: 0), isEmpty);
    });

    test('batch can contain equal ids from different sources', () {
      final picker = UniformRandomComicPicker(random: Random(4));
      final candidates = [favorite('same', 1), favorite('same', 2)];

      expect(picker.pickMany(candidates, count: 3), unorderedEquals(candidates));
    });

    test('returns null for an empty selection', () {
      final picker = UniformRandomComicPicker(random: Random(1));

      expect(picker.pick(const []), isNull);
    });

    test('never returns an excluded comic', () {
      final picker = UniformRandomComicPicker(random: Random(1));
      final first = favorite('a', 1);
      final second = favorite('b', 1);

      expect(
        picker.pick([first, second], excluded: {randomComicIdentity(first)}),
        same(second),
      );
    });

    test('returns null when the whole selection was drawn', () {
      final picker = UniformRandomComicPicker(random: Random(1));
      final comic = favorite('a', 1);

      expect(
        picker.pick([comic], excluded: {randomComicIdentity(comic)}),
        isNull,
      );
    });

    test('identity distinguishes equal ids from different sources', () {
      final picker = UniformRandomComicPicker(random: Random(1));
      final firstSource = favorite('same', 1);
      final secondSource = favorite('same', 2);

      expect(
        picker.pick(
          [firstSource, secondSource],
          excluded: {randomComicIdentity(firstSource)},
        ),
        same(secondSource),
      );
    });

    test('seeded selection is deterministic and remains in the selection', () {
      final candidates = [favorite('a', 1), favorite('b', 1), favorite('c', 1)];
      final first = UniformRandomComicPicker(
        random: Random(42),
      ).pick(candidates);
      final second = UniformRandomComicPicker(
        random: Random(42),
      ).pick(candidates);

      expect(first, same(second));
      expect(candidates, contains(first));
    });
  });
}

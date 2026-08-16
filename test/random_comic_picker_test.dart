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

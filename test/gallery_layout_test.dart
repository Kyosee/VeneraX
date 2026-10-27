import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/gallery_layout.dart';

/// The fixed arithmetic the reader used before landscape images were
/// grouped on their own. Without any, the layout must agree with it, so
/// saved progress still opens on the same screen.
int _oldScreenCount(int n, int per, bool singleFirst) =>
    !singleFirst ? (n / per).ceil() : 1 + ((n - 1) / per).ceil();

(int, int) _oldImagesOf(int screen, int n, int per, bool singleFirst) {
  if (singleFirst) {
    if (screen == 1) return (0, 1);
    final start = (screen - 2) * per + 1;
    return (start, (start + per).clamp(0, n));
  }
  final start = (screen - 1) * per;
  return (start, (start + per).clamp(0, n));
}

int _oldScreenOfHistory(int page, int per, bool singleFirst) {
  if (per == 1) return page;
  return singleFirst ? ((page - 1) / per).ceil() + 1 : (page / per).ceil();
}

List<(int, int)> _screens(GalleryLayout layout) => [
  for (var s = 1; s <= layout.screenCount; s++) layout.imagesOf(s),
];

void main() {
  test('matches the fixed grouping when nothing is landscape', () {
    for (var n = 1; n <= 12; n++) {
      for (var per = 1; per <= 4; per++) {
        for (final singleFirst in [false, true]) {
          final layout = GalleryLayout(
            imageCount: n,
            imagesPerScreen: per,
            singleFirst: singleFirst,
          );
          final label = 'n=$n per=$per singleFirst=$singleFirst';
          expect(
            layout.screenCount,
            _oldScreenCount(n, per, singleFirst),
            reason: label,
          );
          for (var s = 1; s <= layout.screenCount; s++) {
            expect(
              layout.imagesOf(s),
              _oldImagesOf(s, n, per, singleFirst),
              reason: '$label screen=$s',
            );
          }
          for (var page = 1; page <= n; page++) {
            expect(
              layout.screenOf(page - 1),
              _oldScreenOfHistory(page, per, singleFirst),
              reason: '$label history page=$page',
            );
          }
        }
      }
    }
  });

  test('a landscape image stands alone and grouping restarts after it', () {
    final layout = GalleryLayout(imageCount: 8, imagesPerScreen: 2, wide: {3});
    expect(_screens(layout), [(0, 2), (2, 3), (3, 4), (4, 6), (6, 8)]);
    expect(layout.screenOf(3), 3);
    expect(layout.screenOf(5), 4);
  });

  test('a landscape image first in its pair does not take the next one', () {
    final layout = GalleryLayout(imageCount: 6, imagesPerScreen: 2, wide: {2});
    expect(_screens(layout), [(0, 2), (2, 3), (3, 5), (5, 6)]);
  });

  test('keeps the first image alone with landscape images about', () {
    final layout = GalleryLayout(
      imageCount: 7,
      imagesPerScreen: 2,
      singleFirst: true,
      wide: {1, 5},
    );
    expect(_screens(layout), [(0, 1), (1, 2), (2, 4), (4, 5), (5, 6), (6, 7)]);
  });

  test('groups several per screen around landscape images', () {
    final layout = GalleryLayout(imageCount: 9, imagesPerScreen: 3, wide: {4});
    expect(_screens(layout), [(0, 3), (3, 4), (4, 5), (5, 8), (8, 9)]);
  });

  test('out-of-range screens are empty', () {
    final layout = GalleryLayout(imageCount: 4, imagesPerScreen: 2);
    expect(layout.imagesOf(0), (0, 0));
    expect(layout.imagesOf(3), (4, 4));
    expect(GalleryLayout(imageCount: 0, imagesPerScreen: 2).screenCount, 0);
  });

  group('regroupedAround', () {
    test('a landscape image behind keeps the screen being read', () {
      final before = GalleryLayout(imageCount: 12, imagesPerScreen: 2);
      // Reading [6, 8); image 2 turns out to be landscape.
      final after = before.regroupedAround(before.screenOf(6), {2});

      expect(after.imagesOf(after.screenOf(6)), (6, 8));
      expect(_screens(after).sublist(0, 5), [
        (0, 2),
        (2, 3),
        (3, 5),
        (5, 6),
        (6, 8),
      ]);
      // Grouping afresh would have changed it under the reader.
      final fresh = GalleryLayout(
        imageCount: 12,
        imagesPerScreen: 2,
        wide: {2},
      );
      expect(fresh.imagesOf(fresh.screenOf(6)), (5, 7));
    });

    test('a landscape image ahead regroups only what follows', () {
      final before = GalleryLayout(imageCount: 10, imagesPerScreen: 2);
      final after = before.regroupedAround(2, {5});

      expect(after.imagesOf(2), (2, 4));
      expect(_screens(after), [
        (0, 2),
        (2, 4),
        (4, 5),
        (5, 6),
        (6, 8),
        (8, 10),
      ]);
    });

    test('a landscape image on the screen being read splits it there', () {
      final before = GalleryLayout(imageCount: 6, imagesPerScreen: 2);
      final after = before.regroupedAround(2, {3});

      expect(after.imagesOf(2), (2, 3));
      expect(after.imagesOf(3), (3, 4));
    });

    test('holds for any landscape set and any screen being read', () {
      const n = 10;
      for (var mask = 0; mask < 1 << n; mask++) {
        final wide = {
          for (var i = 0; i < n; i++)
            if (mask & (1 << i) != 0) i,
        };
        for (final singleFirst in [false, true]) {
          final before = GalleryLayout(
            imageCount: n,
            imagesPerScreen: 2,
            singleFirst: singleFirst,
          );
          for (var s = 1; s <= before.screenCount; s++) {
            final (start, end) = before.imagesOf(s);
            final after = before.regroupedAround(s, wide);
            final kept = after.imagesOf(after.screenOf(start));
            final reason = 'wide=$wide singleFirst=$singleFirst screen=$s';
            expect(kept.$1, start, reason: reason);
            final splits = [
              for (var i = start; i < end; i++)
                if (wide.contains(i)) i,
            ];
            if (splits.isEmpty) {
              expect(kept.$2, end, reason: reason);
            } else {
              expect(kept.$2, lessThanOrEqualTo(end), reason: reason);
            }
          }
        }
      }
    });

    test('past the last screen it regroups freely', () {
      final before = GalleryLayout(imageCount: 6, imagesPerScreen: 2);
      final after = before.regroupedAround(4, {2});

      expect(
        after.sameScreensAs(
          GalleryLayout(imageCount: 6, imagesPerScreen: 2, wide: {2}),
        ),
        isTrue,
      );
    });
  });
}

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

  group('cut landscape images', () {
    test('without landscape images nothing changes', () {
      for (var n = 0; n <= 8; n++) {
        for (var per = 1; per <= 3; per++) {
          final plain = GalleryLayout(imageCount: n, imagesPerScreen: per);
          final split = GalleryLayout(
            imageCount: n,
            imagesPerScreen: per,
            splitWide: true,
          );
          expect(split.sameScreensAs(plain), isTrue, reason: 'n=$n per=$per');
        }
      }
    });

    test('a landscape image takes two screens, one per half', () {
      final layout = GalleryLayout(
        imageCount: 4,
        imagesPerScreen: 1,
        splitWide: true,
        wide: {1},
      );

      expect(_screens(layout), [(0, 1), (1, 2), (1, 2), (2, 3), (3, 4)]);
      expect(layout.halfOf(1), isNull);
      expect(layout.halfOf(2), GalleryHalf.first);
      expect(layout.halfOf(3), GalleryHalf.second);
      expect(layout.halfOf(4), isNull);
      expect(layout.screenOf(1), 2);
      expect(layout.screenOf(1, GalleryHalf.second), 3);
      expect(layout.screenOf(2), 4);
      // An uncut image has one screen, whichever half is asked for.
      expect(layout.screenOf(2, GalleryHalf.second), 4);
    });

    test('first, last and neighbouring landscape images', () {
      final layout = GalleryLayout(
        imageCount: 4,
        imagesPerScreen: 1,
        splitWide: true,
        wide: {0, 1, 3},
      );

      expect(layout.screenCount, 7);
      expect(_screens(layout), [
        (0, 1),
        (0, 1),
        (1, 2),
        (1, 2),
        (2, 3),
        (3, 4),
        (3, 4),
      ]);
      expect(layout.halfOf(1), GalleryHalf.first);
      expect(layout.halfOf(2), GalleryHalf.second);
      expect(layout.halfOf(3), GalleryHalf.first);
      expect(layout.halfOf(7), GalleryHalf.second);
      expect(layout.screenOf(3), 6);
      expect(layout.screenOf(3, GalleryHalf.second), 7);
    });

    test('only cuts with one image per screen', () {
      final layout = GalleryLayout(
        imageCount: 4,
        imagesPerScreen: 2,
        splitWide: true,
        wide: {1},
      );

      expect(layout.splitWide, isFalse);
      expect(_screens(layout), [(0, 1), (1, 2), (2, 4)]);
      expect(layout.halfOf(2), isNull);
    });

    test('a landscape image behind keeps the half being read', () {
      final before = GalleryLayout(
        imageCount: 5,
        imagesPerScreen: 1,
        splitWide: true,
        wide: {3},
      );
      expect(before.halfOf(5), GalleryHalf.second);

      final after = before.regroupedAround(5, {1, 3});
      final screen = after.screenMatching(before, 5);

      expect(screen, 6);
      expect(after.imagesOf(screen), (3, 4));
      expect(after.halfOf(screen), GalleryHalf.second);
    });

    test('the image being read opens on its first half once cut', () {
      final before = GalleryLayout(
        imageCount: 4,
        imagesPerScreen: 1,
        splitWide: true,
      );
      final after = before.regroupedAround(2, {1});
      final screen = after.screenMatching(before, 2);

      expect(screen, 2);
      expect(after.imagesOf(screen), (1, 2));
      expect(after.halfOf(screen), GalleryHalf.first);
    });

    test('turned back to, an image opens on its later half once cut', () {
      final before = GalleryLayout(
        imageCount: 4,
        imagesPerScreen: 1,
        splitWide: true,
      );
      final after = before.regroupedAround(4, {3});
      final screen = after.screenMatching(before, 4, backward: true);

      expect(screen, 5);
      expect(after.halfOf(screen), GalleryHalf.second);
      // An image cut already keeps its half whichever way the reader came.
      final again = after.regroupedAround(screen, {1, 3});
      expect(again.screenMatching(after, screen), 6);
      expect(again.screenMatching(after, screen, backward: true), 6);
    });

    test('turning the cut off lands on the whole image', () {
      final cut = GalleryLayout(
        imageCount: 4,
        imagesPerScreen: 1,
        splitWide: true,
        wide: {1},
      );
      final whole = GalleryLayout(imageCount: 4, imagesPerScreen: 1, wide: {1});

      expect(whole.screenMatching(cut, 2), 2);
      expect(whole.screenMatching(cut, 3), 2);
      expect(whole.screenMatching(cut, 4), 3);
      expect(cut.screenMatching(whole, 3), 4);
    });

    test('regrouping keeps what is on screen for any landscape set', () {
      const n = 8;
      for (var mask = 0; mask < 1 << n; mask++) {
        final wide = {
          for (var i = 0; i < n; i++)
            if (mask & (1 << i) != 0) i,
        };
        final subsets = [<int>{}, wide.where((i) => i.isEven).toSet(), wide];
        for (final known in subsets) {
          final before = GalleryLayout(
            imageCount: n,
            imagesPerScreen: 1,
            splitWide: true,
            wide: known,
          );
          for (var s = 1; s <= before.screenCount; s++) {
            final after = before.regroupedAround(s, wide);
            final kept = after.screenMatching(before, s);
            final reason = 'wide=$wide known=$known screen=$s';
            expect(after.imagesOf(kept), before.imagesOf(s), reason: reason);
            expect(
              after.halfOf(kept) ?? GalleryHalf.first,
              before.halfOf(s) ?? GalleryHalf.first,
              reason: reason,
            );
          }
          expect(
            before.regroupedAround(1, wide).screenCount,
            n + wide.length,
            reason: 'wide=$wide known=$known',
          );
        }
      }
    });
  });

  group('shifted pairing', () {
    test('a shift starts a screen and pairing goes on from it', () {
      final layout = GalleryLayout(
        imageCount: 10,
        imagesPerScreen: 2,
        shifts: {3},
      );
      expect(_screens(layout), [
        (0, 2),
        (2, 3),
        (3, 5),
        (5, 7),
        (7, 9),
        (9, 10),
      ]);
      expect(layout.isShiftedAt(3), isTrue);
      expect(layout.isShiftedAt(2), isFalse);
      // History saves an image; it opens on the screen showing it.
      expect(layout.screenOf(4 - 1), 3);
      expect(layout.screenOf(6 - 1), 4);
    });

    test('shifting shows the next pair, and shifting there undoes it', () {
      final before = GalleryLayout(imageCount: 6, imagesPerScreen: 2);
      final (after, page) = before.shiftedAt(2, const {})!;
      expect(_screens(after), [(0, 2), (2, 3), (3, 5), (5, 6)]);
      expect(after.shifts, {3});
      expect(page, 3);
      final (undone, back) = after.shiftedAt(page, const {})!;
      expect(_screens(undone), _screens(before));
      expect(undone.shifts, isEmpty);
      expect(back, 2);
    });

    test('screens with one image cannot shift', () {
      final cover = GalleryLayout(
        imageCount: 5,
        imagesPerScreen: 2,
        singleFirst: true,
      );
      expect(cover.canShiftAt(1), isFalse);
      expect(cover.shiftedAt(1, const {}), isNull);
      expect(cover.canShiftAt(2), isTrue);
      expect(cover.canShiftAt(0), isFalse);
      expect(cover.canShiftAt(cover.screenCount + 1), isFalse);

      final landscape = GalleryLayout(
        imageCount: 6,
        imagesPerScreen: 2,
        wide: {2},
      );
      expect(_screens(landscape), [(0, 2), (2, 3), (3, 5), (5, 6)]);
      expect(landscape.canShiftAt(2), isFalse);
      expect(landscape.canShiftAt(4), isFalse);

      final single = GalleryLayout(
        imageCount: 4,
        imagesPerScreen: 1,
        shifts: {2},
      );
      expect(single.canShiftAt(2), isFalse);
      expect(single.isShiftedAt(3), isFalse);
    });

    test('shifts survive regrouping; out-of-range ones are dropped', () {
      final layout = GalleryLayout(
        imageCount: 6,
        imagesPerScreen: 2,
        shifts: {0, 3, 6, 40},
      );
      expect(layout.shifts, {3});
      final regrouped = layout.regroupedAround(3, {5});
      expect(regrouped.shifts, {3});
      expect(regrouped.isShiftedAt(regrouped.screenOf(3)), isTrue);
    });

    test('screens a regroup held in place stay put', () {
      // Finding landscape image 2 while on screen 3 held images 4 and 5.
      final held = GalleryLayout(
        imageCount: 10,
        imagesPerScreen: 2,
      ).regroupedAround(3, {2});
      expect(_screens(held), [(0, 2), (2, 3), (3, 4), (4, 6), (6, 8), (8, 10)]);
      final (after, page) = held.shiftedAt(5, {2})!;
      expect(_screens(after), [
        (0, 2),
        (2, 3),
        (3, 4),
        (4, 6),
        (6, 7),
        (7, 9),
        (9, 10),
      ]);
      expect(page, 6);
    });

    test('earlier screens stay put through a shift and its undo', () {
      const n = 7;
      for (final per in [2, 3]) {
        for (final singleFirst in [false, true]) {
          for (var mask = 0; mask < 1 << n; mask++) {
            final wide = {
              for (var i = 0; i < n; i++)
                if (mask & (1 << i) != 0) i,
            };
            final fresh = GalleryLayout(
              imageCount: n,
              imagesPerScreen: per,
              singleFirst: singleFirst,
              wide: wide,
            );
            final plain = GalleryLayout(
              imageCount: n,
              imagesPerScreen: per,
              singleFirst: singleFirst,
            );
            final layouts = [
              fresh,
              for (var r = 1; r <= plain.screenCount; r++)
                plain.regroupedAround(r, wide),
            ];
            for (final before in layouts) {
              final label =
                  'per=$per singleFirst=$singleFirst wide=$wide '
                  'screens=${_screens(before)}';
              for (var s = 1; s <= before.screenCount; s++) {
                final reason = '$label screen=$s';
                final (start, end) = before.imagesOf(s);
                final result = before.shiftedAt(s, wide);
                if (end - start < 2) {
                  expect(result, isNull, reason: reason);
                  continue;
                }
                final (after, page) = result!;
                final earlier = [
                  for (var k = 1; k < s; k++) before.imagesOf(k),
                ];
                expect(
                  [for (var k = 1; k < s; k++) after.imagesOf(k)],
                  earlier,
                  reason: reason,
                );
                expect(after.imagesOf(s), (start, start + 1), reason: reason);
                expect(after.imagesOf(page).$1, start + 1, reason: reason);
                expect(after.isShiftedAt(page), isTrue, reason: reason);

                final (undone, back) = after.shiftedAt(page, wide)!;
                expect(undone.shifts, isEmpty, reason: reason);
                expect(back, s, reason: reason);
                expect(
                  [for (var k = 1; k < s; k++) undone.imagesOf(k)],
                  earlier,
                  reason: reason,
                );
                expect(undone.imagesOf(s).$1, start, reason: reason);
                if (identical(before, fresh)) {
                  expect(_screens(undone), _screens(fresh), reason: reason);
                }
              }
            }
          }
        }
      }
    });
  });
}

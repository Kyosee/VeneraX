import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Builds a solid-colour RGBA page.
RgbaImage _solid(int w, int h, int r, int g, int b) {
  var px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = 255;
  }
  return RgbaImage(w, h, px);
}

int _lum(RgbaImage img, int x, int y) {
  var i = (y * img.width + x) * 4;
  return (0.299 * img.pixels[i] +
          0.587 * img.pixels[i + 1] +
          0.114 * img.pixels[i + 2])
      .round();
}

void main() {
  group('TextInpainter.erase', () {
    test('removes dark strokes on a light bubble', () {
      // A light bubble with a block of dark "text" in the middle.
      var img = _solid(60, 60, 245, 245, 245);
      for (var y = 24; y < 36; y++) {
        for (var x = 20; x < 40; x++) {
          var i = (y * 60 + x) * 4;
          img.pixels[i] = 20;
          img.pixels[i + 1] = 20;
          img.pixels[i + 2] = 20;
        }
      }

      TextInpainter.erase(img, [IntRect(18, 22, 42, 38)]);

      // Every previously-dark pixel is now close to the bubble colour.
      for (var y = 24; y < 36; y++) {
        for (var x = 20; x < 40; x++) {
          expect(
            _lum(img, x, y),
            greaterThan(200),
            reason: 'stroke pixel at $x,$y should be filled with background',
          );
        }
      }
    });

    test('removes light strokes on a dark bubble', () {
      var img = _solid(60, 60, 15, 15, 15);
      for (var y = 24; y < 36; y++) {
        for (var x = 20; x < 40; x++) {
          var i = (y * 60 + x) * 4;
          img.pixels[i] = 240;
          img.pixels[i + 1] = 240;
          img.pixels[i + 2] = 240;
        }
      }

      TextInpainter.erase(img, [IntRect(18, 22, 42, 38)]);

      for (var y = 24; y < 36; y++) {
        for (var x = 20; x < 40; x++) {
          expect(
            _lum(img, x, y),
            lessThan(60),
            reason:
                'stroke pixel at $x,$y should be filled with dark background',
          );
        }
      }
    });

    test('leaves a flat region with no text untouched', () {
      var img = _solid(40, 40, 200, 120, 80);
      var before = Uint8List.fromList(img.pixels);

      TextInpainter.erase(img, [IntRect(8, 8, 32, 32)]);

      expect(img.pixels, equals(before));
    });

    test('computeMask returns null for a near-uniform crop', () {
      var img = _solid(40, 40, 128, 128, 128);
      expect(TextInpainter.computeMask(img, IntRect(8, 8, 32, 32)), isNull);
    });

    test('computeMask marks the dark strokes only', () {
      var img = _solid(50, 50, 250, 250, 250);
      for (var y = 20; y < 30; y++) {
        for (var x = 20; x < 30; x++) {
          var i = (y * 50 + x) * 4;
          img.pixels[i] = 10;
          img.pixels[i + 1] = 10;
          img.pixels[i + 2] = 10;
        }
      }
      var m = TextInpainter.computeMask(img, IntRect(18, 18, 32, 32));
      expect(m, isNotNull);
      // The stroke centre is masked; a background corner of the window is not.
      var cx = 25 - m!.left, cy = 25 - m.top;
      expect(m.mask[cy * m.rw + cx], equals(1));
      expect(m.mask[0], equals(0));
    });

    test('does not erase high-contrast artwork outside the OCR rectangle', () {
      var img = _solid(60, 60, 245, 245, 245);
      // Source glyph inside the OCR rectangle.
      for (var y = 25; y < 35; y++) {
        for (var x = 25; x < 35; x++) {
          var i = (y * 60 + x) * 4;
          img.pixels[i] = img.pixels[i + 1] = img.pixels[i + 2] = 20;
        }
      }
      // Nearby line art is inside the sampling window, but outside the OCR box.
      for (var y = 20; y < 40; y++) {
        var i = (y * 60 + 12) * 4;
        img.pixels[i] = img.pixels[i + 1] = img.pixels[i + 2] = 20;
      }

      TextInpainter.erase(img, [IntRect(22, 22, 38, 38)]);

      expect(_lum(img, 30, 30), greaterThan(200));
      expect(_lum(img, 12, 30), lessThan(60));
    });

    test('erases dense lettering next to a page edge', () {
      var img = _solid(40, 20, 245, 245, 245);
      for (var y = 1; y < 17; y++) {
        for (var x = 1; x < 39; x++) {
          var i = (y * 40 + x) * 4;
          img.pixels[i] = img.pixels[i + 1] = img.pixels[i + 2] = 20;
        }
      }

      TextInpainter.erase(img, [IntRect(0, 0, 40, 20)]);

      expect(_lum(img, 20, 10), greaterThan(200));
    });

    test('skips tiny regions without error', () {
      var img = _solid(10, 10, 255, 255, 255);
      // A 2px rect is below the working-window minimum.
      expect(
        () => TextInpainter.erase(img, [IntRect(4, 4, 6, 6)]),
        returnsNormally,
      );
    });

    test('drops isolated speck noise, keeps a real stroke', () {
      // A light crop with one real stroke block plus a single stray dark pixel.
      // The speck is below the noise floor and must not be erased/counted.
      var img = _solid(60, 60, 245, 245, 245);
      for (var y = 24; y < 36; y++) {
        for (var x = 20; x < 40; x++) {
          var i = (y * 60 + x) * 4;
          img.pixels[i] = 20;
          img.pixels[i + 1] = 20;
          img.pixels[i + 2] = 20;
        }
      }
      // A lone dark speck far from the stroke.
      var si = (10 * 60 + 10) * 4;
      img.pixels[si] = 20;
      img.pixels[si + 1] = 20;
      img.pixels[si + 2] = 20;

      var m = TextInpainter.computeMask(img, IntRect(6, 6, 54, 54));
      expect(m, isNotNull);
      // The stroke centre survives filtering.
      var cx = 30 - m!.left, cy = 30 - m.top;
      expect(m.mask[cy * m.rw + cx], equals(1));
      // The lone speck was dropped as noise.
      var sx = 10 - m.left, sy = 10 - m.top;
      expect(m.mask[sy * m.rw + sx], equals(0));
    });
  });

  group('stroke boundaries', () {
    test(
      'erases 120 glyph pixels and preserves a separate 50 pixel line inside the OCR box',
      () {
        var img = _solid(144, 96, 245, 245, 245);
        for (var x in [35, 47, 59, 71, 83]) {
          for (var dx = 0; dx < 3; dx++) {
            for (var y = 30; y < 38; y++) {
              var i = (y * 144 + x + dx) * 4;
              img.pixels.fillRange(i, i + 3, 20);
            }
          }
        }
        for (var x = 37; x < 87; x++) {
          var i = (43 * 144 + x) * 4;
          img.pixels.fillRange(i, i + 3, 20);
        }
        TextInpainter.erase(img, [IntRect(30, 27, 94, 47)]);
        for (var x = 37; x < 87; x++) {
          expect(_lum(img, x, 43), 20);
        }
        for (var x in [35, 47, 59, 71, 83]) {
          for (var dx = 0; dx < 3; dx++) {
            for (var y = 30; y < 38; y++) {
              expect(_lum(img, x + dx, y), greaterThan(200));
            }
          }
        }
      },
    );

    test(
      'a matching compact CTD mask can exclude artwork inside the OCR box',
      () {
        var img = _solid(100, 64, 245, 245, 245);
        var bytes = Uint8List(50 * 32);
        for (var x in [26, 38, 50, 62, 74, 82]) {
          for (var dx = 0; dx < 4; dx++) {
            for (var y = 24; y < 36; y++) {
              var i = (y * 100 + x + dx) * 4;
              img.pixels.fillRange(i, i + 3, 20);
              if (x != 82) bytes[(y ~/ 2) * 50 + (x + dx) ~/ 2] = 255;
            }
          }
        }
        var roi = IntRect(24, 20, 90, 40);
        var rules = TextInpainter.computeMask(img, roi)!;
        var enhanced = TextInpainter.computeMask(
          img,
          roi,
          strokeMask: StrokeMask(50, 32, bytes),
        )!;
        int at(TextMask m, int x) => m.mask[(28 - m.top) * m.rw + x - m.left];
        expect(at(rules, 83), 1);
        expect(at(enhanced, 83), 0);
        expect(at(enhanced, 39), 1);
      },
    );

    for (var vertical in [false, true]) {
      test('keeps a thin line through glyphs (vertical=$vertical)', () {
        var image = _solid(144, 144, 245, 245, 245);
        int offset(int x, int y) => (vertical ? x * 144 + y : y * 144 + x) * 4;
        void ink(int x, int y) {
          var i = offset(x, y);
          image.pixels.fillRange(i, i + 3, 20);
        }

        for (var x in [35, 47, 59, 71, 83]) {
          for (var dx = 0; dx < 3; dx++) {
            for (var y = 30; y < 38; y++) {
              ink(x + dx, y);
            }
          }
        }
        // A disconnected line inside the box and another crossing the glyphs.
        for (var x = 37; x < 87; x++) {
          ink(x, 43);
          ink(x, 34);
        }
        var line = vertical ? IntRect(27, 30, 47, 94) : IntRect(30, 27, 94, 47);
        TextInpainter.erase(image, [line]);
        for (var x = 37; x < 87; x++) {
          expect(image.pixels[offset(x, 43)], 20);
          expect(image.pixels[offset(x, 34)], 20);
        }
        // The intersection is ambiguous, so the whole line stays as drawn.
        expect(image.pixels[offset(60, 30)], 20);
      });
    }

    test('retains glyph-length vowel marks in the erase mask on dark paper', () {
      var img = _solid(120, 60, 25, 25, 25);
      for (var y = 23; y < 34; y++) {
        for (var x in [31, 32, 33, 56, 57, 58]) {
          var i = (y * img.width + x) * 4;
          img.pixels.fillRange(i, i + 3, 238);
        }
      }
      for (var y = 27; y < 30; y++) {
        for (var x = 40; x < 50; x++) {
          var i = (y * img.width + x) * 4;
          img.pixels.fillRange(i, i + 3, 238);
        }
      }
      // A useless optional mask must fall back to the local light-on-dark split.
      for (var value in [0, 255]) {
        var mask = StrokeMask(1, 1, Uint8List.fromList([value]));
        var candidate = TextInpainter.computeMask(
          img,
          IntRect(26, 20, 65, 38),
          strokeMask: mask,
        )!;
        expect(
          candidate.mask[(28 - candidate.top) * candidate.rw +
              45 -
              candidate.left],
          1,
        );
      }
    });
  });

  group('InpaintMode', () {
    test('fromSettings maps values and defaults to smart', () {
      expect(InpaintMode.fromSettings('patch'), InpaintMode.patch);
      expect(InpaintMode.fromSettings('smart'), InpaintMode.smart);
      expect(InpaintMode.fromSettings(null), InpaintMode.smart);
      expect(InpaintMode.fromSettings('nonsense'), InpaintMode.smart);
    });

    test('tokens are distinct single chars', () {
      var tokens = InpaintMode.values.map((m) => m.token).toSet();
      expect(tokens.length, InpaintMode.values.length);
      expect(tokens.every((t) => t.length == 1), isTrue);
    });

    test('mode token is a suffix so scope prefixes still match', () {
      // The rendered-image key appends "#<token>" to the base cache key. A
      // comic/chapter scope prefix of the base key must still be a prefix of
      // the rendered key, or prefix-scoped cache deletes would miss.
      const base = 'pageTranslation@ja>zh@source@cid@eid@imageKey';
      const scopePrefix = 'pageTranslation@ja>zh@source@cid@';
      for (var mode in InpaintMode.values) {
        var renderedKey = '$base#${mode.token}';
        expect(renderedKey.startsWith(scopePrefix), isTrue);
      }
    });
  });

  group('TranslatedRegion cache', () {
    test('old entries use the layout rectangle for erasing', () {
      var region = TranslatedRegion.fromJson({
        'l': 1,
        't': 2,
        'r': 30,
        'b': 40,
        'text': 'translated',
        'bg': 0xFFFFFFFF,
        'fg': 0xFF000000,
      });
      expect(region.eraseRect.left, 1);
      expect(region.eraseRect.bottom, 40);
    });

    test('round-trips a tighter erase rectangle', () {
      var region = TranslatedRegion(
        rect: IntRect(1, 2, 30, 40),
        eraseRect: IntRect(4, 5, 26, 36),
        text: 'translated',
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      );
      var restored = TranslatedRegion.fromJson(region.toJson());
      expect(restored.eraseRect.left, 4);
      expect(restored.eraseRect.bottom, 36);
    });

    test('round-trips per-line erase rectangles', () {
      var region = TranslatedRegion(
        rect: IntRect(1, 2, 60, 80),
        eraseRect: IntRect(4, 5, 56, 76),
        eraseRects: [IntRect(4, 5, 40, 20), IntRect(8, 28, 56, 44)],
        text: 'translated',
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      );

      var restored = TranslatedRegion.fromJson(region.toJson());

      expect(restored.eraseRects, hasLength(2));
      expect(restored.eraseRects.first.left, 4);
      expect(restored.eraseRects.last.bottom, 44);
    });

    test('old tighter entries expose one erase rectangle', () {
      var region = TranslatedRegion.fromJson({
        'l': 1,
        't': 2,
        'r': 60,
        'b': 80,
        'el': 4,
        'et': 5,
        'er': 56,
        'eb': 76,
        'text': 'translated',
        'bg': 0xFFFFFFFF,
        'fg': 0xFF000000,
      });

      expect(region.eraseRects, hasLength(1));
      expect(region.eraseRects.single.left, 4);
      expect(region.eraseRects.single.bottom, 76);
    });

    test('ignores invalid per-line erase rectangles', () {
      var region = TranslatedRegion.fromJson({
        'l': 1,
        't': 2,
        'r': 60,
        'b': 80,
        'es': [
          [4, 5, 4, 20],
          [30, 30, 10, 40],
        ],
        'text': 'translated',
        'bg': 0xFFFFFFFF,
        'fg': 0xFF000000,
      });

      expect(region.eraseRects, hasLength(1));
      expect(region.eraseRects.single.left, 1);
      expect(region.eraseRects.single.bottom, 80);
    });
  });
}

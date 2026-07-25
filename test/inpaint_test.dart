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
          expect(_lum(img, x, y), greaterThan(200),
              reason: 'stroke pixel at $x,$y should be filled with background');
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
          expect(_lum(img, x, y), lessThan(60),
              reason: 'stroke pixel at $x,$y should be filled with dark background');
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

    test('skips tiny regions without error', () {
      var img = _solid(10, 10, 255, 255, 255);
      // A 2px rect is below the working-window minimum.
      expect(() => TextInpainter.erase(img, [IntRect(4, 4, 6, 6)]), returnsNormally);
    });
  });

  group('InpaintMode', () {
    test('fromSettings maps values and defaults to smart', () {
      expect(InpaintMode.fromSettings('patch'), InpaintMode.patch);
      expect(InpaintMode.fromSettings('ai'), InpaintMode.ai);
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
}

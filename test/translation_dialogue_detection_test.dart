import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

RgbaImage _canvas(int width, int height) {
  var bytes = Uint8List(width * height * 4)
    ..fillRange(0, width * height * 4, 255);
  return RgbaImage(width, height, bytes);
}

void _pixel(RgbaImage page, int x, int y, int color) {
  var i = (y * page.width + x) * 4;
  page.pixels[i] = (color >> 16) & 255;
  page.pixels[i + 1] = (color >> 8) & 255;
  page.pixels[i + 2] = color & 255;
}

void _bubble(RgbaImage page, IntRect rect, int color) {
  var rx = rect.width / 2, ry = rect.height / 2;
  for (var y = rect.top; y < rect.bottom; y++) {
    for (var x = rect.left; x < rect.right; x++) {
      var dx = (x + .5 - rect.left - rx) / rx;
      var dy = (y + .5 - rect.top - ry) / ry;
      var d = dx * dx + dy * dy;
      if (d < 1) _pixel(page, x, y, d < .90 ? color : 0x080808);
    }
  }
}

void _letters(RgbaImage page, IntRect box, int color) {
  for (var y = box.top + 1; y < box.bottom - 1; y++) {
    for (var x = box.left + 1; x < box.right - 1; x++) {
      if ((x - box.left) % 8 < 3) _pixel(page, x, y, color);
    }
  }
}

void main() {
  test(
    'groups lines by closed bubble and drops captions and floating text',
    () {
      var image = _canvas(240, 170);
      _bubble(image, IntRect(10, 10, 111, 79), 0xfff2da);
      _bubble(image, IntRect(112, 12, 223, 80), 0x21334a);
      var a = IntRect(28, 26, 88, 37), b = IntRect(24, 43, 98, 53);
      var c = IntRect(138, 32, 201, 48);
      _letters(image, a, 0x111111);
      _letters(image, b, 0x111111);
      _letters(image, c, 0xffffff);
      var caption = IntRect(28, 105, 90, 119);
      for (var y = 87; y < 135; y++) {
        for (var x = 11; x < 108; x++) {
          if (x < 14 || x > 104 || y < 90 || y > 131) {
            _pixel(image, x, y, 0x222222);
          }
        }
      }
      var effect = IntRect(134, 110, 202, 130);
      _letters(image, caption, 0x222222);
      _letters(image, effect, 0x222222);
      expect(dialogueGroups(image, [a, effect, c, caption, b]), [
        [a, b],
        [c],
      ]);
    },
  );

  test(
    'overlapping slices recover the whole bubble at a webtoon tile seam',
    () {
      var page = _canvas(200, 1800);
      _bubble(page, IntRect(25, 318, 170, 415), 0xffeedd);
      var first = IntRect(65, 345, 131, 361);
      var second = IntRect(55, 380, 135, 398);
      _letters(page, first, 0x222222);
      _letters(page, second, 0x222222);
      expect(dialogueGroups(page, [first, second]), [
        [first, second],
      ]);
    },
  );
}

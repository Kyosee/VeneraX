import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/text_detector_geometry.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

List<int> _bounds(IntRect r) => [r.left, r.top, r.right, r.bottom];

void main() {
  test('keeps unclip proportional to the thickness of a 44 by 6 diagonal', () {
    final probs = Float32List(96 * 96);
    for (var y = 0; y < 96; y++) {
      for (var x = 0; x < 96; x++) {
        if ((x + y - 96).abs() <= 31 && (x - y).abs() <= 4) {
          probs[y * 96 + x] = .9;
        }
      }
    }
    final box = postprocessTextDetections(probs, 96, 96, 96, 96).single;
    expect(box.width, inInclusiveRange(44, 51));
    expect(box.height, box.width);
    expect(box.left + box.right, 97);
    expect(box.top + box.bottom, 97);
  });

  test('rejects a high-confidence 16 pixel outline with an empty interior', () {
    final probs = Float32List(40 * 40);
    for (var y = 10; y < 26; y++) {
      for (var x = 10; x < 26; x++) {
        if (x == 10 || x == 25 || y == 10 || y == 25) {
          probs[y * 40 + x] = .9;
        }
      }
    }
    expect(postprocessTextDetections(probs, 40, 40, 40, 40), isEmpty);
    for (var y = 11; y < 25; y++) {
      probs.fillRange(y * 40 + 11, y * 40 + 25, .9);
    }
    expect(postprocessTextDetections(probs, 40, 40, 40, 40), hasLength(1));
  });

  test('scales horizontal and vertical rectangles and clips the tile edge', () {
    final probs = Float32List(64 * 64);
    for (var y = 22; y < 28; y++) {
      probs.fillRange(y * 64 + 20, y * 64 + 36, .9);
    }
    for (var y = 45; y < 61; y++) {
      probs.fillRange(y * 64, y * 64 + 6, .9);
    }
    final boxes = postprocessTextDetections(probs, 64, 64, 128, 64);
    expect(boxes.map(_bounds), [
      [33, 19, 79, 31],
      [0, 42, 19, 64],
    ]);
  });

  test('collects corner-connected islands as one candidate', () {
    final probs = Float32List(40 * 40);
    for (var block = 0; block < 3; block++) {
      final start = 6 + 5 * block;
      for (var y = start; y < start + 5; y++) {
        probs.fillRange(y * 40 + start, y * 40 + start + 5, 1);
      }
    }
    expect(postprocessTextDetections(probs, 40, 40, 40, 40), hasLength(1));
  });
}

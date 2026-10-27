import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test('left to right keeps the order and numbers the images from one', () {
    expect(galleryPageOrder(['a', 'b'], 4, rightToLeft: false), [
      ('a', 5),
      ('b', 6),
    ]);
  });

  test('right to left reverses the layout, not the numbers', () {
    expect(galleryPageOrder(['a', 'b'], 4, rightToLeft: true), [
      ('b', 6),
      ('a', 5),
    ]);
    expect(galleryPageOrder(['a', 'b', 'c'], 0, rightToLeft: true), [
      ('c', 3),
      ('b', 2),
      ('a', 1),
    ]);
  });
}

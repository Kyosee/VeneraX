import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

(int, int, int, int) _bounds(IntRect box) =>
    (box.left, box.top, box.right, box.bottom);

void main() {
  test(
    'retains the full horizontal caption after a partial rotated detection',
    () {
      final caption = IntRect(10, 130, 110, 150);
      expect(
        combineVerticalDetections(
          [caption],
          [IntRect(10, 130, 70, 150)],
        ).map(_bounds),
        [_bounds(caption)],
      );
      expect(
        combineVerticalDetections(
          [caption],
          [IntRect(15, 130, 115, 150)],
        ).map(_bounds),
        [(10, 130, 115, 150)],
      );
    },
  );
  test('retains a partial first or last glyph of the same column', () {
    final column = IntRect(40, 20, 55, 95);
    final neighbour = IntRect(65, 20, 80, 95);
    for (final (glyph, expected) in [
      (IntRect(40, 10, 55, 30), (40, 10, 55, 95)),
      (IntRect(40, 85, 55, 105), (40, 20, 55, 105)),
    ]) {
      expect(
        combineVerticalDetections([glyph], [column, neighbour]).map(_bounds),
        unorderedEquals([expected, _bounds(neighbour)]),
      );
    }
  });
  test('removes a single glyph fully contained in a complete column', () {
    final glyph = IntRect(57, 57, 72, 67);
    final column = IntRect(50, 23, 83, 180);
    expect(combineVerticalDetections([glyph], [column]).map(_bounds), [
      _bounds(column),
    ]);
  });
  test(
    'a repeated vertical anchor cannot erase an independent short caption',
    () {
      final caption = IntRect(49, 39, 74, 49);
      final column = IntRect(50, 43, 72, 160);
      expect(
        combineVerticalDetections([caption], [column]).map(_bounds),
        unorderedEquals([_bounds(caption), _bounds(column)]),
      );
    },
  );

  test('keeps an outside caption above one bubble in a separate OCR block', () {
    final caption = IntRect(10, 20, 115, 34);
    final first = IntRect(24, 38, 106, 52);
    final second = IntRect(25, 56, 105, 70);
    final groups = clusterAllTextBoxes(
      [caption, first, second],
      [
        [first, second],
      ],
      160,
      160,
    );
    expect(groups, hasLength(2));
    expect(groups, contains(equals([caption])));
  });

  test('discards detector blocks repeating staggered vertical columns', () {
    final columns = [
      IntRect(40, 12, 62, 164),
      IntRect(56, 10, 82, 104),
      IntRect(77, 12, 99, 103),
      IntRect(95, 19, 117, 130),
    ];
    final band = IntRect(60, 11, 116, 35);
    final block = IntRect(46, 31, 119, 117);
    expect(
      combineVerticalDetections([band, block], columns).map(_bounds),
      unorderedEquals(columns.map(_bounds)),
    );
  });

  test(
    'discards a horizontal strip repeatedly reading the top of three columns',
    () {
      final cols = [
        for (var x in [20, 42, 64]) IntRect(x, 10, x + 25, 110),
      ];
      final band = IntRect(22, 12, 87, 38);
      expect(
        combineVerticalDetections([band], cols).map(_bounds),
        unorderedEquals(cols.map(_bounds)),
      );
    },
  );

  test('keeps an expanded edge column with its single dialogue bubble', () {
    final interior = IntRect(40, 10, 65, 110);
    final edge = IntRect(64, 14, 88, 70);
    final groups = clusterAllTextBoxes(
      [interior, edge],
      [
        [interior],
      ],
      160,
      160,
    );
    expect(groups, hasLength(1));
    expect(groups.single, containsAll([interior, edge]));
  });

  test('separates neighbouring enclosed bubbles in all-text mode', () {
    final first = IntRect(40, 10, 65, 110);
    final second = IntRect(70, 14, 94, 105);
    final groups = clusterAllTextBoxes(
      [first, second],
      [
        [first],
        [second],
      ],
      160,
      160,
    );
    expect(groups, hasLength(2));
  });

  test('requests a sideways pass for fragmented vertical dialogue', () {
    final columns = [IntRect(90, 20, 102, 105), IntRect(68, 20, 80, 110)];
    final fragmented = [
      ...columns,
      for (var y = 20; y < 100; y += 16) IntRect(48, y, 60, y + 12),
    ];
    expect(needsVerticalDetectionPass(fragmented), isTrue);
    expect(
      needsVerticalDetectionPass([...columns, IntRect(48, 20, 60, 96)]),
      isFalse,
    );

    final horizontal = [
      for (final box in fragmented)
        IntRect(box.top, box.left, box.bottom, box.right),
    ];
    expect(needsVerticalDetectionPass(horizontal), isFalse);
  });

  test('a complete column replaces glyph boxes and preserves a caption', () {
    final column = IntRect(36, 10, 50, 100);
    final caption = IntRect(70, 70, 150, 86);
    final fused = combineVerticalDetections(
      [IntRect(38, 14, 48, 29), IntRect(38, 30, 48, 45), caption],
      [column],
    );
    expect(
      fused.map(_bounds),
      unorderedEquals([_bounds(column), _bounds(caption)]),
    );
  });

  test('combines partial views of a column without losing either end', () {
    final original = IntRect(40, 45, 54, 145);
    final rotated = IntRect(40, 10, 54, 110);
    final fused = combineVerticalDetections([original], [rotated]);
    expect(fused.map(_bounds), [(40, 10, 54, 145)]);
  });

  test('a glyph touching two columns does not join their crops', () {
    final left = IntRect(40, 10, 60, 110);
    final right = IntRect(52, 10, 72, 110);
    final glyph = IntRect(46, 20, 65, 34);
    final fused = combineVerticalDetections([glyph], [left, right]);
    expect(
      fused.map(_bounds),
      unorderedEquals([_bounds(left), _bounds(right)]),
    );
    final tail = IntRect(46, 63, 65, 145);
    final extended = combineVerticalDetections([glyph, tail], [left, right]);
    expect(
      extended.map(_bounds),
      unorderedEquals([(40, 10, 60, 145), _bounds(right)]),
    );
  });

  test('repeated coverage at a column seam preserves a horizontal caption', () {
    final caption = IntRect(20, 88, 80, 98);
    final upper = IntRect(40, 20, 56, 100);
    final lower = IntRect(40, 85, 56, 160);
    final fused = combineVerticalDetections([caption], [upper, lower]);
    expect(
      fused.map(_bounds),
      unorderedEquals([_bounds(caption), _bounds(upper), _bounds(lower)]),
    );
  });

  test('keeps vertically adjacent passages with overlapping box edges', () {
    final top = IntRect(40, 10, 54, 110);
    final bottom = IntRect(40, 104, 54, 178);
    final fused = combineVerticalDetections([bottom], [top]);
    expect(
      fused.map(_bounds),
      unorderedEquals([_bounds(top), _bounds(bottom)]),
    );
  });

  test('orders short PP-OCR columns before they reach the line reader', () {
    final upper = IntRect(100, 10, 110, 85);
    final lower = IntRect(101, 86, 111, 160);
    final left = IntRect(75, 30, 85, 140);
    expect(splitOcrCluster([left, lower, upper]).single, [upper, lower, left]);
  });

  test('splits a long Japanese note with every column in reading order', () {
    final columns = [
      for (var x = 130; x >= 10; x -= 20) IntRect(x, 10, x + 12, 130),
    ];
    final groups = splitOcrCluster(columns.reversed.toList());
    expect(groups.length, greaterThan(1));
    expect(groups.expand((group) => group).map(_bounds), columns.map(_bounds));
  });

  test(
    'reads staggered fragments of one column from top to bottom across crops',
    () {
      final upper = IntRect(100, 10, 110, 110);
      final lower = IntRect(101, 106, 111, 206);
      final ordered = [
        IntRect(140, 50, 150, 170),
        IntRect(120, 50, 130, 170),
        upper,
        lower,
        IntRect(80, 50, 90, 170),
      ];
      final groups = splitOcrCluster(ordered.reversed.toList());
      expect(groups.length, greaterThan(1));
      expect(
        groups.expand((group) => group).map(_bounds),
        ordered.map(_bounds),
      );
    },
  );
}

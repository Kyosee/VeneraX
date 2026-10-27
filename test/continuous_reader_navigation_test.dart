import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/continuous_page_turn_coordinator.dart';

void main() {
  test('mid-chapter rapid turn does not jump directly to the scroll tail', () {
    final estimate = estimateContinuousTurnOffset(
      currentPixels: 500,
      referenceDelta: -100,
      targetIndex: 30,
      referenceIndex: 20,
      itemExtent: 400,
      minScrollExtent: 0,
      maxScrollExtent: 3000,
      maxStepExtent: 1600,
    );

    expect(estimate, greaterThan(500));
    expect(estimate, lessThan(3000));
  });

  test(
    'mid-chapter reverse turn does not jump directly to the scroll head',
    () {
      final estimate = estimateContinuousTurnOffset(
        currentPixels: 2500,
        referenceDelta: 100,
        targetIndex: 10,
        referenceIndex: 20,
        itemExtent: 400,
        minScrollExtent: 0,
        maxScrollExtent: 3000,
        maxStepExtent: 1600,
      );

      expect(estimate, lessThan(2500));
      expect(estimate, greaterThan(0));
    },
  );

  test('explicit long-distance navigation keeps the unbounded estimate', () {
    final estimate = estimateContinuousTurnOffset(
      currentPixels: 500,
      referenceDelta: -100,
      targetIndex: 30,
      referenceIndex: 20,
      itemExtent: 400,
      minScrollExtent: 0,
      maxScrollExtent: 3000,
    );

    expect(estimate, 3000);
  });

  group('split page turned by halves', () {
    // A 1200px page (two 600px halves) in an 800px viewport.
    bool lower(double start, {double readingLine = 1}) => isReadingLowerHalf(
      pageStart: start,
      pageExtent: 1200,
      viewExtent: 800,
      readingLine: readingLine,
    );

    test('top of the page is the upper half', () {
      expect(lower(0), isFalse);
      expect(lower(-200), isFalse);
    });

    test('landing on the midpoint is the lower half, despite rounding', () {
      expect(lower(-600), isTrue);
      expect(lower(-599.6), isTrue);
    });

    test('a remainder that fits on screen counts as the lower half', () {
      // The list ended before the midpoint could reach the reading line.
      expect(lower(-450), isTrue);
      expect(lower(-350), isFalse);
    });

    test('follows a centered reading line', () {
      // Upper half centered: 100px margin above it.
      expect(lower(100, readingLine: 400), isFalse);
      // Lower half centered.
      expect(lower(-500, readingLine: 400), isTrue);
    });
  });
}

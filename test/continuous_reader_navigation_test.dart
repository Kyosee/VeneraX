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
}

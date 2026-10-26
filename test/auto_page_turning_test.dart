import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/auto_page_turning.dart';

void main() {
  test('every speed level scrolls faster than the one below', () {
    for (var level = autoScrollSpeedMin; level < autoScrollSpeedMax; level++) {
      expect(
        autoScrollWidthsPerSecond(level + 1),
        greaterThan(autoScrollWidthsPerSecond(level)),
        reason: 'level $level',
      );
    }
  });

  test('speed spans a slow read to a fast skim and clamps beyond', () {
    expect(autoScrollWidthsPerSecond(autoScrollSpeedMin), closeTo(0.04, 1e-9));
    expect(autoScrollWidthsPerSecond(autoScrollSpeedMax), closeTo(2.0, 1e-9));
    expect(autoScrollWidthsPerSecond(0), autoScrollWidthsPerSecond(1));
    expect(autoScrollWidthsPerSecond(99), autoScrollWidthsPerSecond(30));
  });

  test('scroll steps land on whole device pixels without losing distance', () {
    const dpr = 2.75;
    var carry = 0.0;
    var moved = 0.0;
    // 30 logical px/s at 120 fps: well under one device pixel per frame.
    for (var frame = 0; frame < 1200; frame++) {
      final (step, next) = autoScrollStep(30 / 120, carry, dpr);
      final devicePixels = step * dpr;
      expect(devicePixels, closeTo(devicePixels.roundToDouble(), 1e-6));
      expect(next, inInclusiveRange(-1e-9, 1 / dpr));
      carry = next;
      moved += step;
    }
    expect(moved + carry, closeTo(300, 1e-6));
  });

  test('only continuous modes set to scroll scroll', () {
    expect(autoTurnScrolls('continuousTopToBottom', autoTurnModeScroll), true);
    expect(autoTurnScrolls('continuousRightToLeft', autoTurnModeScroll), true);
    expect(autoTurnScrolls('continuousTopToBottom', autoTurnModePage), false);
    expect(autoTurnScrolls('continuousTopToBottom', null), false);
    expect(autoTurnScrolls('galleryTopToBottom', autoTurnModeScroll), false);
  });

  test('stored values outside the range or of the wrong type fall back', () {
    expect(autoTurnIntervalOf(7), 7);
    expect(autoTurnIntervalOf(0), autoTurnIntervalMin);
    expect(autoTurnIntervalOf(90), autoTurnIntervalMax);
    expect(autoTurnIntervalOf(null), autoTurnIntervalDefault);
    expect(autoScrollSpeedOf(12.6), 13);
    expect(autoScrollSpeedOf('fast'), autoScrollSpeedDefault);
    expect(autoScrollSpeedOf(-3), autoScrollSpeedMin);
  });
}

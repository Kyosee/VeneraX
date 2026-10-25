import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/eink_screen.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test('gallery turns map to the way the page content moves', () {
    const cases = {
      (ReaderMode.galleryLeftToRight, true): RippleSweep.leftward,
      (ReaderMode.galleryLeftToRight, false): RippleSweep.rightward,
      (ReaderMode.galleryRightToLeft, true): RippleSweep.rightward,
      (ReaderMode.galleryRightToLeft, false): RippleSweep.leftward,
      (ReaderMode.galleryTopToBottom, true): RippleSweep.upward,
      (ReaderMode.galleryTopToBottom, false): RippleSweep.downward,
    };
    cases.forEach((input, sweep) {
      expect(
        galleryRippleSweep(input.$1, forward: input.$2),
        sweep,
        reason: '$input',
      );
    });
  });

  test('continuous modes have no ripple', () {
    for (final mode in ReaderMode.values.where((m) => m.isContinuous)) {
      expect(galleryRippleSweep(mode, forward: true), isNull);
    }
  });

  test('next-page turns arm the controller codes per reading direction', () {
    List<int> codesFor(ReaderMode mode) => rippleCodes(
      galleryRippleSweep(mode, forward: true)!,
      RippleSpeed.standard,
    );
    expect(codesFor(ReaderMode.galleryLeftToRight), [65, 68, 66, 67]);
    expect(codesFor(ReaderMode.galleryRightToLeft), [66, 67, 65, 68]);
  });
}

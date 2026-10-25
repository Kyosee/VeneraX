import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/eink_screen.dart';

const _white = Color(0xFFFFFFFF);
const _black = Color(0xFF000000);

void main() {
  setUp(() {
    appdata.settings['einkFullRefresh'] = true;
    appdata.settings['einkRefreshColor'] = 'white';
    appdata.settings['einkRefreshInterval'] = 1;
    appdata.settings['einkRefreshDuration'] = 100;
  });

  testWidgets('a refresh covers the page for the set duration', (
    tester,
  ) async {
    final refresher = EinkRefresher();
    addTearDown(refresher.dispose);

    refresher.onPageSettled();
    expect(refresher.overlay.value, _white);
    await tester.pump(const Duration(milliseconds: 99));
    expect(refresher.overlay.value, _white);
    await tester.pump(const Duration(milliseconds: 1));
    expect(refresher.overlay.value, isNull);
  });

  testWidgets('black then white shows both frames in order', (tester) async {
    appdata.settings['einkRefreshColor'] = 'blackThenWhite';
    final refresher = EinkRefresher();
    addTearDown(refresher.dispose);

    refresher.onPageSettled();
    expect(refresher.overlay.value, _black);
    await tester.pump(const Duration(milliseconds: 100));
    expect(refresher.overlay.value, _white);
    await tester.pump(const Duration(milliseconds: 100));
    expect(refresher.overlay.value, isNull);
  });

  testWidgets('only every Nth turn refreshes', (tester) async {
    appdata.settings['einkRefreshInterval'] = 3;
    final refresher = EinkRefresher();
    addTearDown(refresher.dispose);

    final refreshed = <bool>[];
    for (var i = 0; i < 6; i++) {
      refresher.onPageSettled();
      refreshed.add(refresher.overlay.value != null);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(refreshed, [false, false, true, false, false, true]);
  });

  testWidgets('a turn during a refresh restarts it', (tester) async {
    final refresher = EinkRefresher();
    addTearDown(refresher.dispose);

    refresher.onPageSettled();
    await tester.pump(const Duration(milliseconds: 60));
    refresher.onPageSettled();
    await tester.pump(const Duration(milliseconds: 60));
    expect(refresher.overlay.value, _white);
    await tester.pump(const Duration(milliseconds: 40));
    expect(refresher.overlay.value, isNull);
  });

  test('nothing is painted while the refresh is off', () {
    appdata.settings['einkFullRefresh'] = false;
    final refresher = EinkRefresher();
    addTearDown(refresher.dispose);

    expect(refresher.flashesNextTurn, isFalse);
    refresher.onPageSettled();
    expect(refresher.overlay.value, isNull);
  });

  test('out-of-range stored values are clamped, unknown colors fall back', () {
    appdata.settings['einkRefreshInterval'] = 0;
    appdata.settings['einkRefreshColor'] = 'purple';
    final refresher = EinkRefresher();
    addTearDown(refresher.dispose);

    refresher.onPageSettled();
    expect(refresher.overlay.value, _white);
  });

  testWidgets('flashesNextTurn predicts the refreshing turn', (tester) async {
    appdata.settings['einkRefreshInterval'] = 2;
    final refresher = EinkRefresher();
    addTearDown(refresher.dispose);

    expect(refresher.flashesNextTurn, isFalse);
    refresher.onPageSettled();
    expect(refresher.flashesNextTurn, isTrue);
    refresher.onPageSettled();
    expect(refresher.overlay.value, isNotNull);
    expect(refresher.flashesNextTurn, isFalse);
    await tester.pump(const Duration(milliseconds: 100));
  });

  test('e-ink tuning never leaves this device through sync', () {
    final deviceLocal = Appdata.syncDisabledFields(const []);
    for (final key in [
      'einkFullRefresh',
      'einkRefreshColor',
      'einkRefreshInterval',
      'einkRefreshDuration',
      'einkRipplePageTurn',
      'einkRippleSpeed',
    ]) {
      expect(deviceLocal, contains(key), reason: key);
    }
  });

  group('ripple codes', () {
    test('horizontal sweeps follow the display rotation', () {
      expect(rippleCodes(RippleSweep.leftward, RippleSpeed.standard), [
        65,
        68,
        66,
        67,
      ]);
      expect(rippleCodes(RippleSweep.rightward, RippleSpeed.standard), [
        66,
        67,
        65,
        68,
      ]);
    });

    test('speed only changes the speed bits', () {
      expect(rippleCodes(RippleSweep.leftward, RippleSpeed.slower)[0], 129);
      expect(rippleCodes(RippleSweep.leftward, RippleSpeed.faster)[0], 1);
      expect(RippleSpeed.fromKey('unknown'), RippleSpeed.standard);
    });

    test('a vertical sweep is a horizontal one a quarter turn later', () {
      final up = rippleCodes(RippleSweep.upward, RippleSpeed.standard);
      final left = rippleCodes(RippleSweep.leftward, RippleSpeed.standard);
      for (var r = 0; r < 4; r++) {
        expect(up[r], left[(r + 1) % 4], reason: 'rotation $r');
      }
    });

    test('opposite sweeps', () {
      expect(RippleSweep.leftward.opposite, RippleSweep.rightward);
      expect(RippleSweep.upward.opposite, RippleSweep.downward);
    });
  });
}

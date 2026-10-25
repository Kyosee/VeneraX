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

  test('e-ink tuning never leaves this device through sync', () {
    final deviceLocal = Appdata.syncDisabledFields(const []);
    for (final key in [
      'einkFullRefresh',
      'einkRefreshColor',
      'einkRefreshInterval',
      'einkRefreshDuration',
    ]) {
      expect(deviceLocal, contains(key), reason: key);
    }
  });
}

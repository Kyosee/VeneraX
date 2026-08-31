import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';

KillRule _rule(
  String id, {
  List<String> platforms = const [],
  List<String> abis = const [],
  List<String> appVersions = const [],
  String reason = 'disabled remotely',
}) => KillRule(
  id: id,
  platforms: platforms,
  abis: abis,
  appVersions: appVersions,
  reason: reason,
);

void main() {
  setUp(() {
    KillSwitches.instance.clear();
    KillSwitches.instance.configureDevice(
      platform: 'android',
      abi: 'arm64-v8a',
      appVersion: '2.2.12',
    );
  });

  test('everything is enabled by default', () {
    expect(KillSwitches.instance.isEnabled('imageTranslation'), isTrue);
    expect(KillSwitches.instance.reasonFor('imageTranslation'), isNull);
  });

  test('an unscoped rule disables the feature fleet-wide', () {
    KillSwitches.instance.apply([_rule('imageTranslation')]);
    expect(KillSwitches.instance.isEnabled('imageTranslation'), isFalse);
    expect(KillSwitches.instance.reasonFor('imageTranslation'),
        'disabled remotely');
    expect(KillSwitches.instance.isEnabled('somethingElse'), isTrue);
  });

  test('a platform-scoped rule spares other platforms', () {
    KillSwitches.instance.apply([_rule('x', platforms: ['ios'])]);
    expect(KillSwitches.instance.isEnabled('x'), isTrue,
        reason: 'device is android');

    KillSwitches.instance.clear();
    KillSwitches.instance.apply([_rule('x', platforms: ['android', 'ios'])]);
    expect(KillSwitches.instance.isEnabled('x'), isFalse);
  });

  test('an ABI-scoped rule targets only the affected chips', () {
    // The shape of the ORT SIGILL case: only parts reporting SME1 without SME2
    // trip the fault, so translation must stay available everywhere else.
    KillSwitches.instance.apply([_rule('translate', abis: ['armeabi-v7a'])]);
    expect(KillSwitches.instance.isEnabled('translate'), isTrue);

    KillSwitches.instance.clear();
    KillSwitches.instance.apply([_rule('translate', abis: ['arm64-v8a'])]);
    expect(KillSwitches.instance.isEnabled('translate'), isFalse);
  });

  test('an ABI-scoped rule cannot match a device with unknown ABI', () {
    KillSwitches.instance.configureDevice(
      platform: 'windows',
      abi: null,
      appVersion: '2.2.12',
    );
    KillSwitches.instance.apply([_rule('x', abis: ['arm64-v8a'])]);
    expect(KillSwitches.instance.isEnabled('x'), isTrue,
        reason: 'an unknown ABI must not be treated as matching every ABI');
  });

  test('a version-scoped rule spares other versions', () {
    KillSwitches.instance.apply([_rule('x', appVersions: ['2.2.11'])]);
    expect(KillSwitches.instance.isEnabled('x'), isTrue);

    KillSwitches.instance.clear();
    KillSwitches.instance.apply([_rule('x', appVersions: ['2.2.11', '2.2.12'])]);
    expect(KillSwitches.instance.isEnabled('x'), isFalse);
  });

  test('scopes are ANDed, not ORed', () {
    // Right platform, wrong ABI: must not match. A rule that fired on a
    // partial scope match would disable features on unaffected devices.
    KillSwitches.instance.apply([
      _rule('x', platforms: ['android'], abis: ['x86_64']),
    ]);
    expect(KillSwitches.instance.isEnabled('x'), isTrue);
  });

  test('apply replaces the previous rule set', () {
    KillSwitches.instance.apply([_rule('a')]);
    expect(KillSwitches.instance.isEnabled('a'), isFalse);
    // A manifest that drops a rule must re-enable the feature, otherwise a
    // kill could never be lifted without an app release.
    KillSwitches.instance.apply([_rule('b')]);
    expect(KillSwitches.instance.isEnabled('a'), isTrue);
    expect(KillSwitches.instance.isEnabled('b'), isFalse);
  });

  test('rules parse from a manifest track', () {
    final m = PatchManifest.parse(
      '{"schema":1,"patchVersion":5,"tracks":{"stable":{"kills":['
      '{"id":"translate","platforms":["android"],"abis":["arm64-v8a"],'
      '"reason":"native fault on this chip"},'
      '{"id":"","reason":"dropped"}'
      ']}}}',
    );
    final kills = m.tracks['stable']!.kills;
    expect(kills.length, 1, reason: 'a rule without an id is unusable');
    expect(kills.first.id, 'translate');
    expect(kills.first.reason, 'native fault on this chip');
  });
}

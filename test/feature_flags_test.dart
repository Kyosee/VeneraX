// Kill switches and config overlays, at the app's own call sites.
//
// These are the only tools that help with a fault *below* Dart. A crash inside
// a `.so` can never be patched — the defect is compiled ARM and the patch
// runtime interprets Dart — but the code path that reaches it can be closed
// remotely, turning "the app dies when I open this" into "this feature is
// unavailable".
//
// The dangerous failure mode is the inverse of the obvious one. A switch that
// fails to disable something loses one incident; a switch that disables things
// by accident silently removes features from every install whenever a CDN has a
// bad minute, with nothing in any log to explain it. So the default-enabled
// behaviour is asserted far more heavily here than the disabling behaviour.

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/feature_flags.dart';
import 'package:venera_patch/venera_patch.dart';

KillRule _rule(
  String id, {
  List<String> platforms = const [],
  List<String> abis = const [],
  List<String> appVersions = const [],
  String reason = 'test',
}) =>
    KillRule(
      id: id,
      platforms: platforms,
      abis: abis,
      appVersions: appVersions,
      reason: reason,
    );

void main() {
  setUp(() {
    KillSwitches.instance.clear();
    ConfigOverlay.instance.clear();
    KillSwitches.instance.configureDevice(
      platform: 'android',
      abi: 'arm64-v8a',
      appVersion: '2.2.12',
    );
  });

  tearDown(() {
    KillSwitches.instance.clear();
    ConfigOverlay.instance.clear();
  });

  group('nothing published means nothing disabled', () {
    test('every feature is enabled with no rules at all', () {
      // The state on a fresh install, offline, or after a failed check. Getting
      // this backwards would ship an app whose features depend on a network
      // round trip completing.
      for (final id in KillIds.all) {
        expect(featureEnabled(id), isTrue, reason: id);
        expect(featureDisabledReason(id), isNull, reason: id);
      }
    });

    test('an empty rule list leaves everything enabled', () {
      KillSwitches.instance.apply(const []);
      for (final id in KillIds.all) {
        expect(featureEnabled(id), isTrue, reason: id);
      }
    });

    test('a rule for an unrelated feature disables nothing else', () {
      KillSwitches.instance.apply([_rule(KillIds.imageTranslation)]);
      expect(featureEnabled(KillIds.imageTranslation), isFalse);
      for (final id in KillIds.all.where(
        (i) => i != KillIds.imageTranslation,
      )) {
        expect(featureEnabled(id), isTrue, reason: id);
      }
    });

    test('an unknown feature id is enabled, not disabled', () {
      // A rule naming a feature this build has never heard of — a manifest
      // written for a newer version. It must not take anything down here.
      KillSwitches.instance.apply([_rule('somethingFromTheFuture')]);
      for (final id in KillIds.all) {
        expect(featureEnabled(id), isTrue, reason: id);
      }
      expect(featureEnabled('somethingFromTheFuture'), isFalse);
    });
  });

  group('a matching rule closes exactly its feature', () {
    test('the #169 shape: translation off, on one ABI only', () {
      // onnxruntime dispatching SME2 kernels on SME1-only chips. The rule has
      // to be able to name the affected ABI, or the remedy costs every user
      // their translation to protect the few who crash.
      KillSwitches.instance.apply([
        _rule(
          KillIds.imageTranslation,
          abis: ['arm64-v8a'],
          reason: 'SIGILL on chips reporting SME without usable SME2',
        ),
      ]);
      expect(featureEnabled(KillIds.imageTranslation), isFalse);
      expect(
        featureDisabledReason(KillIds.imageTranslation),
        contains('SME'),
      );
    });

    test('a rule for a different ABI leaves this device alone', () {
      KillSwitches.instance.apply([
        _rule(KillIds.imageTranslation, abis: ['armeabi-v7a']),
      ]);
      expect(featureEnabled(KillIds.imageTranslation), isTrue);
    });

    test('a rule for a different platform leaves this device alone', () {
      KillSwitches.instance.apply([
        _rule(KillIds.archiveExtract, platforms: ['ios']),
      ]);
      expect(featureEnabled(KillIds.archiveExtract), isTrue);
    });

    test('a rule for a different app version leaves this build alone', () {
      KillSwitches.instance.apply([
        _rule(KillIds.downloads, appVersions: ['2.2.11']),
      ]);
      expect(featureEnabled(KillIds.downloads), isTrue);
    });

    test('scopes are ANDed: every stated scope must match', () {
      // Platform matches, ABI does not. A rule that fired on a partial match
      // would disable far more than its author asked for.
      KillSwitches.instance.apply([
        _rule(
          KillIds.downloads,
          platforms: ['android'],
          abis: ['x86_64'],
        ),
      ]);
      expect(featureEnabled(KillIds.downloads), isTrue);
    });

    test('an unscoped rule applies everywhere', () {
      KillSwitches.instance.apply([_rule(KillIds.webdavStartupImport)]);
      expect(featureEnabled(KillIds.webdavStartupImport), isFalse);
    });
  });

  group('rules are replaced wholesale, never merged', () {
    test('a later manifest lifts a rule the earlier one set', () {
      // Withdrawing a rule is how an incident ends. If rules accumulated, a
      // feature closed during an incident could never be reopened without an
      // app update — the opposite of the point.
      KillSwitches.instance.apply([_rule(KillIds.downloads)]);
      expect(featureEnabled(KillIds.downloads), isFalse);

      KillSwitches.instance.apply(const []);
      expect(featureEnabled(KillIds.downloads), isTrue);
    });

    test('clear reopens everything', () {
      KillSwitches.instance.apply([
        _rule(KillIds.downloads),
        _rule(KillIds.imageTranslation),
      ]);
      KillSwitches.instance.clear();
      for (final id in KillIds.all) {
        expect(featureEnabled(id), isTrue, reason: id);
      }
    });
  });

  group('config overlay shadows defaults only', () {
    test('with no overlay, the caller reads its own default', () {
      expect(configInt(ConfigKeys.downloadThreads, 5), 5);
      expect(configBool('someFlag', true), isTrue);
    });

    test('an override replaces the default', () {
      ConfigOverlay.instance.apply({ConfigKeys.downloadThreads: 2});
      expect(configInt(ConfigKeys.downloadThreads, 5), 2);
    });

    test('a wrong-typed override is ignored rather than crashing', () {
      // A hand-edited or mistyped manifest must degrade to built-in behaviour.
      // Casting blindly here would turn a typo into a crash on every launch.
      ConfigOverlay.instance.apply({ConfigKeys.downloadThreads: 'lots'});
      expect(configInt(ConfigKeys.downloadThreads, 5), 5);
    });

    test('an unrelated key does not disturb others', () {
      ConfigOverlay.instance.apply({ConfigKeys.ocrWorkers: 1});
      expect(configInt(ConfigKeys.downloadThreads, 5), 5);
      expect(configInt(ConfigKeys.ocrWorkers, 4), 1);
    });

    test('protected keys are refused', () {
      // Sync version state and credentials are excluded on principle: a patch
      // able to rewrite dataVersion could corrupt the whole fleet's sync
      // lineage, and one able to rewrite WebDAV credentials could redirect a
      // user's backups.
      ConfigOverlay.instance.apply({
        'dataVersion': 999,
        'webdav': 'https://attacker.example',
        ConfigKeys.downloadThreads: 3,
      });
      expect(ConfigOverlay.instance.get('dataVersion'), isNull);
      expect(ConfigOverlay.instance.get('webdav'), isNull);
      // The legitimate key in the same payload still applies — one rejected
      // entry must not discard the rest.
      expect(configInt(ConfigKeys.downloadThreads, 5), 3);
    });

    test('clear restores built-in defaults exactly', () {
      ConfigOverlay.instance.apply({ConfigKeys.downloadThreads: 1});
      ConfigOverlay.instance.clear();
      expect(configInt(ConfigKeys.downloadThreads, 5), 5);
    });
  });

  group('published ids are a stable contract', () {
    test('the id set is the one we expect', () {
      // Rules outlive the build that wrote them: a device on an older version
      // keeps applying a manifest written for a newer one. A renamed id stops
      // matching silently, which reads as "the kill switch didn't work" during
      // exactly the incident it was published for. This pin makes a rename a
      // test failure instead.
      expect(KillIds.all, [
        'imageTranslation',
        'webdavAutoSync',
        'webdavStartupImport',
        'archiveExtract',
        'downloads',
      ]);
    });

    test('no id is published twice', () {
      expect(KillIds.all.toSet().length, KillIds.all.length);
    });

    test('config keys are the ones we expect', () {
      expect(ConfigKeys.all, [
        'downloadThreads',
        'ocrWorkers',
        'imageTimeoutSeconds',
        'backupRetention',
      ]);
    });

    test('no config key collides with a protected key', () {
      for (final key in ConfigKeys.all) {
        expect(
          ConfigOverlay.protectedKeys.contains(key),
          isFalse,
          reason: '$key is published as tunable but also protected — one of '
              'the two is wrong, and the overlay would silently drop it',
        );
      }
    });
  });
}

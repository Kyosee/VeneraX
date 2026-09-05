// The whole chain, against a real app function.
//
// Everything upstream of this has been proven in isolation: the interpreter runs
// VIR, the compiler emits it, the loader validates it, the seam consults the
// registry. What none of those prove is the thing that actually matters — that a
// fix written as ordinary Dart, compiled against the manifest this build
// publishes, changes what a real function in `lib/` returns.
//
// The subject is `shouldSkipStaleUpload`, which decides whether an automatic
// WebDAV upload must stand down because this device is behind the server. It is
// the #86 bug site, and the failure mode is the worst this app has: a device
// holding stale data uploads it stamped as newest, every other device pulls the
// old snapshot back and reverts reads it had already recorded, then re-uploads
// the rollback one version higher.
//
// `_stale_upload_patch.json` is the *actual* output of
//
//   dart run tool/patch_tool.dart surface --out surface.json
//   dart run venera_patch_compiler:compile --surface surface.json \
//     packages/venera_patch_compiler/example/stale_upload_fix.dart
//
// committed verbatim. Not hand-written VIR that resembles compiler output — an
// earlier test in this repo did exactly that and got the shape wrong (2 slots
// where the compiler emits 4), so it only ever tested its own fixture.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/sync_protocol.dart';
import 'package:venera_patch/venera_patch.dart';

/// The compiled patch, as the store would hand it to the loader.
Map<String, Object?> _payload() {
  final file = File('test/_stale_upload_patch.json');
  if (!file.existsSync()) {
    fail('missing fixture test/_stale_upload_patch.json '
        '(cwd ${Directory.current})');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// Installs the patch exactly as `HotUpdate._applyLocal` does.
void _install() {
  final program = VirLoader(host: const CoreBindings()).load(_payload());
  PatchRegistry.installOverrides(VmOverrideBinder.bind(program));
}

void main() {
  setUp(PatchRegistry.clear);
  tearDown(PatchRegistry.clear);

  group('the shipped function, unpatched', () {
    test('guards only when the server is strictly ahead', () {
      // The rule as shipped: `!force && remoteMaxVersion > localVersion`.
      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 5,
          remoteMaxVersion: 7,
        ),
        isTrue,
        reason: 'behind the server: must stand down',
      );
      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 7,
          remoteMaxVersion: 5,
        ),
        isFalse,
        reason: 'ahead of the server: may upload',
      );
      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 5,
          remoteMaxVersion: 5,
        ),
        isFalse,
        reason: 'equal versions: shipped rule allows the upload',
      );
      expect(
        shouldSkipStaleUpload(
          force: true,
          localVersion: 1,
          remoteMaxVersion: 99,
        ),
        isFalse,
        reason: 'force is an explicit publish and bypasses the guard (#80)',
      );
    });
  });

  group('a compiled patch changes the shipped answer', () {
    test('the equal-version case flips, and only that case', () {
      _install();
      expect(
        PatchRegistry.active,
        isTrue,
        reason: 'the registry gate must be open for a seam to consult it',
      );

      // The one behaviour the patch widens: `>` becomes `>=`, so two devices
      // that both believe they are at version N no longer race to overwrite each
      // other at the same version number.
      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 5,
          remoteMaxVersion: 5,
        ),
        isTrue,
        reason: 'the patch must guard equal versions too',
      );

      // Everything else is unchanged — a patch that alters more than it claims
      // is worse than the bug it fixes.
      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 5,
          remoteMaxVersion: 7,
        ),
        isTrue,
      );
      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 7,
          remoteMaxVersion: 5,
        ),
        isFalse,
      );
      expect(
        shouldSkipStaleUpload(
          force: true,
          localVersion: 1,
          remoteMaxVersion: 99,
        ),
        isFalse,
        reason: 'the patch must preserve the force bypass',
      );
    });

    test('clearing the registry restores the shipped behaviour', () {
      _install();
      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 5,
          remoteMaxVersion: 5,
        ),
        isTrue,
      );

      PatchRegistry.clear();

      expect(
        shouldSkipStaleUpload(
          force: false,
          localVersion: 5,
          remoteMaxVersion: 5,
        ),
        isFalse,
        reason: 'rollback must be complete — this is the user-facing '
            '"roll back hot updates" action',
      );
    });

    test('the other five seams are untouched', () {
      // The payload claims one override. A patch that reached seams it never
      // named would be the most alarming possible failure, so it is asserted
      // rather than assumed.
      _install();
      expect(PatchRegistry.installedCount, 1);
      expect(
        PatchRegistry.lookup(SeamIds.shouldSkipStaleUpload),
        isNotNull,
      );
      for (final id in [
        SeamIds.backupDateFromLeadingSegment,
        SeamIds.compareAppVersions,
        SeamIds.nextSyncVersion,
        SeamIds.mergeIncomingDataVersion,
        SeamIds.isOwnPendingPublish,
      ]) {
        expect(
          PatchRegistry.lookup(id),
          isNull,
          reason: 'seam 0x${id.toRadixString(16)} was not named by this patch',
        );
      }

      // And the unnamed seams still compute correctly, through their originals.
      expect(nextSyncVersion(5, 7), 8);
      expect(mergeIncomingDataVersion(5, 3), 5);
    });
  });

  group('the payload targets what it claims', () {
    test('it overrides exactly the shouldSkipStaleUpload seam id', () {
      final overrides = _payload()['overrides'] as Map<String, Object?>;
      expect(overrides.keys.toList(), ['${SeamIds.shouldSkipStaleUpload}']);
    });

    test('it was compiled, not hand-written', () {
      // The compiler names each function and allocates a slot per parameter and
      // local. Three required parameters with three slots is what it emits for
      // this source; hand-written VIR would not reliably match.
      final functions = _payload()['functions'] as List;
      expect(functions.length, 1);
      final fn = functions.first as Map<String, Object?>;
      expect(fn['name'], 'shouldSkipStaleUpload');
      expect(fn['requiredCount'], 3);
      expect(fn['slotCount'], 3);
    });
  });
}

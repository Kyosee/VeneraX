// The full authoring chain, using the real tables this build ships.
//
// Every other test in this package builds its host surface by hand. This one
// uses [CoreSurface] and [CoreBindings] — the actual tables compiled into the
// app — so it fails if the compiler, the id catalogue and the dispatch switch
// ever stop agreeing with each other.
//
// The patch under test is the #51 fix: the days-vs-milliseconds guard in a
// backup file name's leading segment. It is compiled from ordinary Dart, loaded
// through the VM, and compared against the same logic executed natively. A
// compiler that emitted plausible-looking VIR computing something slightly
// different would ship a new bug under the banner of a fix, so agreement with
// native Dart is what gets asserted — not merely "a payload was produced".

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';

/// The native implementation, copied from `RemoteBackupInfo`.
///
/// Duplicated rather than imported because this package must not depend on the
/// app. Divergence is caught by the app's own tests for that function; what
/// matters here is that the interpreted version agrees with *this* logic.
const int _msPerDay = 86400000;
const int _maxValidMs = 8640000000000000;

int _nativeMs(int value) {
  var ms = value.abs() <= _maxValidMs ~/ _msPerDay ? value * _msPerDay : value;
  if (ms > _maxValidMs) ms = _maxValidMs;
  if (ms < -_maxValidMs) ms = -_maxValidMs;
  return ms;
}

/// The surface manifest this build would publish, assembled exactly as
/// `tool/patch_tool.dart surface` assembles it.
String _surfaceJson() => jsonEncode({
      'schema': 1,
      'appVersion': '2.2.12',
      'builtinPatchVersion': 0,
      'members': CoreSurface.members,
      'types': CoreSurface.types,
      'seams': SeamIds.installed,
    });

void main() {
  setUp(PatchRegistry.clear);
  tearDown(PatchRegistry.clear);

  group('the surface manifest this build publishes', () {
    test('is well-formed and names only installed seams', () {
      final decoded = jsonDecode(_surfaceJson()) as Map<String, Object?>;

      expect(decoded['schema'], 1);
      expect(decoded['appVersion'], isNotEmpty);

      final seams = decoded['seams'] as Map<String, Object?>;
      expect(seams, isNotEmpty, reason: 'a manifest with no seams offers a '
          'patch author nothing to override');
      // Every published seam must have a live `patched()` call site. A declared
      // but uninstalled id would let a patch compile, sign, install and report
      // success while overriding nothing at all.
      expect(seams.keys, contains('backupDateFromLeadingSegment'));

      final members = decoded['members'] as Map<String, Object?>;
      final types = decoded['types'] as Map<String, Object?>;
      expect(members.length, greaterThan(150));
      expect(types.length, greaterThan(10));
    });

    test('every member it advertises is answered by the shipped bridge', () {
      // The manifest is a promise: "a patch may call these". The bridge is what
      // keeps it. A member advertised but unbound is the worst kind of gap,
      // because the failure lands on a user's device mid-operation rather than
      // in the compiler.
      const bridge = CoreBindings();
      final unbound = <String>[];
      CoreSurface.members.forEach((key, id) {
        if (!bridge.isBound(id)) unbound.add(key);
      });
      expect(unbound, isEmpty);
    });
  });

  group('a payload compiled against that manifest runs correctly', () {
    // `_real_payload.json` is the *actual* output of
    //
    //   dart run venera_patch_compiler:compile \
    //     --surface <patch_tool surface> example/backup_date_fix.dart
    //
    // committed verbatim, not hand-written VIR that resembles it. The
    // distinction matters: an earlier version of this test inlined equivalent
    // VIR by hand and got the shape wrong — 2 slots where the compiler emits 4,
    // because the compiler keeps `const` locals in slots rather than folding
    // them. A fixture that only looks like compiler output tests the fixture.
    //
    // Loaded from disk rather than compiled in-test because this package must
    // not depend on the compiler: the compiler pulls in `analyzer`, and nothing
    // that ships inside the app may. The compiler's round-trip tests cover
    // source-to-VIR; this covers VIR-to-answer through the real bridge.
    Map<String, Object?> payload() {
      final file = File('test/_real_payload.json');
      if (!file.existsSync()) {
        fail('missing fixture test/_real_payload.json (cwd ${Directory.current})');
      }
      return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    }

    test('loads through the shipped bridge', () {
      final program = VirLoader(host: const CoreBindings()).load(payload());
      expect(
        program.overrideFor(SeamIds.backupDateFromLeadingSegment),
        isNotNull,
      );
    });

    test('agrees with native Dart across the range that mattered', () {
      final program = VirLoader(host: const CoreBindings()).load(payload());
      final fn = program.overrideFor(SeamIds.backupDateFromLeadingSegment)!;

      for (final value in <int>[
        20321, // days-since-epoch: the ordinary case
        1755000000000, // a millisecond timestamp: the #51 trigger
        0,
        1,
        -1,
        -20321,
        99999999999, // exactly at the multiply/passthrough boundary
        100000000000, // one past it
        _maxValidMs,
        -_maxValidMs,
      ]) {
        expect(
          fn.invoke([value]),
          _nativeMs(value),
          reason: 'interpreted and native disagree at value=$value',
        );
      }
    });

    test('the whole chain reaches the seam and changes its answer', () {
      final program = VirLoader(host: const CoreBindings()).load(payload());
      PatchRegistry.installOverrides(VmOverrideBinder.bind(program));

      // What a seam does: consult the registry, run the override if there is
      // one, otherwise the original. Here the "original" deliberately returns a
      // wrong answer, so a passing assertion can only mean the override ran.
      int seam(int value) => patched(
            SeamIds.backupDateFromLeadingSegment,
            [value],
            () => -1,
          );

      expect(seam(1755000000000), _nativeMs(1755000000000));
      expect(seam(20321), _nativeMs(20321));

      PatchRegistry.clear();
      expect(seam(20321), -1, reason: 'the original must come back');
    });

    test('a payload naming an unpublished seam still loads, but reaches no '
        'call site', () {
      // The load-time contract is only about structural validity, so this
      // succeeds. The protection against a patch aimed at a seam that does not
      // exist lives one step earlier: the compiler refuses a seam name absent
      // from the manifest. This pins that division of labour, because the
      // failure it prevents — an override installed where nothing looks it up —
      // is silent by nature.
      final orphan = payload();
      orphan['overrides'] = {'${SeamIds.compareAppVersions}': 0};

      final program = VirLoader(host: const CoreBindings()).load(orphan);
      PatchRegistry.installOverrides(VmOverrideBinder.bind(program));

      expect(
        SeamIds.installed.values,
        isNot(contains(SeamIds.compareAppVersions)),
        reason: 'compareAppVersions has no patched() call site, so it must not '
            'be published in the surface manifest',
      );
      // The installed seam is untouched by the orphan override.
      expect(
        patched(SeamIds.backupDateFromLeadingSegment, [20321], () => -1),
        -1,
      );
    });
  });
}

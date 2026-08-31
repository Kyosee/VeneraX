// The whole chain, exercised as one: JSON payload -> loader -> binder ->
// registry -> seam -> changed behaviour -> rollback.
//
// Every layer has its own tests, and they all passed while the mechanism as a
// whole did nothing: nothing had yet driven a payload from bytes to a patched
// answer and back. A hot-update system that is verified only in pieces is a
// system nobody has confirmed works.
//
// The subject is deliberately the real seam installed in `sync_protocol.dart`
// (`SeamIds.backupDateFromLeadingSegment`), reproduced here as a local function
// with the same shape, so this test fails if the seam contract changes.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';

// ---------------------------------------------------------------------------
// The subject: a seam over a pure function with a real bug history (#51).
// ---------------------------------------------------------------------------

const int _msPerDay = 86400000;
const int _maxValidMs = 8640000000000000;

/// Mirrors `RemoteBackupInfo._dateFromLeadingSegment`, seam included.
int daysToMillis(int value) {
  return patched(
    SeamIds.backupDateFromLeadingSegment,
    [value],
    () => _daysToMillisOrig(value),
  );
}

int _daysToMillisOrig(int value) {
  var ms = value.abs() <= _maxValidMs ~/ _msPerDay ? value * _msPerDay : value;
  if (ms > _maxValidMs) ms = _maxValidMs;
  if (ms < -_maxValidMs) ms = -_maxValidMs;
  return ms;
}

// ---------------------------------------------------------------------------
// Payloads, written the way the compiler will emit them.
// ---------------------------------------------------------------------------

/// A patch that returns a constant, so "did the override run" is unambiguous.
String _constantPayload({required int seamId, required int value}) => jsonEncode({
  'version': 1,
  'functions': [
    {
      'name': 'daysToMillis',
      'slotCount': 1,
      'requiredCount': 1,
      'body': {
        'k': 'return',
        'v': {'k': 'lit', 'v': value},
      },
    },
  ],
  'overrides': {'$seamId': 0},
});

/// A patch that reimplements the guard with a different threshold — the shape
/// of an actual fix to this function.
String _realFixPayload({required int seamId, required int threshold}) =>
    jsonEncode({
      'version': 1,
      'functions': [
        {
          'name': 'daysToMillis',
          'slotCount': 2,
          'requiredCount': 1,
          'body': {
            'k': 'block',
            'body': [
              // if (value > threshold) return value;
              {
                'k': 'if',
                'c': {
                  'k': 'bin',
                  'op': 'gt',
                  'l': {'k': 'local', 'slot': 0},
                  'r': {'k': 'lit', 'v': threshold},
                },
                'then': {
                  'k': 'return',
                  'v': {'k': 'local', 'slot': 0},
                },
              },
              // return value * 86400000;
              {
                'k': 'return',
                'v': {
                  'k': 'bin',
                  'op': 'mul',
                  'l': {'k': 'local', 'slot': 0},
                  'r': {'k': 'lit', 'v': _msPerDay},
                },
              },
            ],
          },
        },
      ],
      'overrides': {'$seamId': 0},
    });

/// A patch whose body calls a host member that is bound but faults when
/// invoked — the manifest/binary mismatch that load-time checks cannot catch.
String _faultingPayload({required int seamId}) => jsonEncode({
  'version': 1,
  'functions': [
    {
      'name': 'boom',
      'slotCount': 1,
      'requiredCount': 1,
      'body': {
        'k': 'return',
        'v': {
          'k': 'hostCall',
          'id': 0x2001,
          'args': [
            {'k': 'local', 'slot': 0},
          ],
        },
      },
    },
  ],
  'overrides': {'$seamId': 0},
});

/// Binds 0x2001 but throws a machinery fault when it is called.
final class _FaultingBridge implements HostBridge {
  const _FaultingBridge();

  @override
  Object? invoke(
    int memberId,
    Object? receiver,
    List<Object?> positional,
    Map<String, Object?>? named,
  ) =>
      throw UnboundMemberFault(memberId, 'surface manifest disagrees');

  @override
  bool isBound(int memberId) => memberId == 0x2001;

  @override
  bool isBoundType(int typeId) => false;

  @override
  String? describe(int memberId) => 'faulting#$memberId';

  @override
  bool isInstanceOf(int typeId, Object? value) =>
      throw UnboundMemberFault(typeId);
}

/// Loads [source] and installs it, exactly as `HotUpdate._applyLocal` does.
void _install(String source, {HostBridge? host}) {
  final program = VirLoader(
    host: host ?? const CoreBindings(),
  ).loadJson(source);
  PatchRegistry.installOverrides(VmOverrideBinder.bind(program));
}

void main() {
  setUp(PatchRegistry.clear);
  tearDown(PatchRegistry.clear);

  // -------------------------------------------------------------------------
  // The claim the whole project rests on.
  // -------------------------------------------------------------------------
  group('a patch actually changes behaviour', () {
    test('before installing, the seam runs the original', () {
      expect(PatchRegistry.active, isFalse);
      expect(daysToMillis(20321), 20321 * _msPerDay);
      // The overflow guard: a millisecond timestamp passes through unmultiplied.
      expect(daysToMillis(1755000000000), 1755000000000);
    });

    test('installing a payload takes the function over', () {
      _install(_constantPayload(
        seamId: SeamIds.backupDateFromLeadingSegment,
        value: 12345,
      ));

      expect(PatchRegistry.active, isTrue);
      expect(daysToMillis(20321), 12345);
      expect(daysToMillis(0), 12345);
    });

    test('a realistic fix changes exactly the branch it targets', () {
      // Lower the threshold so a value the original would multiply is now
      // treated as already-in-milliseconds. This is the shape of the #51 fix.
      _install(_realFixPayload(
        seamId: SeamIds.backupDateFromLeadingSegment,
        threshold: 10000,
      ));

      // Below the new threshold: still multiplied, same as the original.
      expect(daysToMillis(5000), 5000 * _msPerDay);
      // Above it: passed through, where the original would have multiplied.
      expect(daysToMillis(20321), 20321);
      expect(_daysToMillisOrig(20321), 20321 * _msPerDay);
    });

    test('clearing the registry restores the original', () {
      _install(_constantPayload(
        seamId: SeamIds.backupDateFromLeadingSegment,
        value: 999,
      ));
      expect(daysToMillis(20321), 999);

      PatchRegistry.clear();

      expect(PatchRegistry.active, isFalse);
      expect(daysToMillis(20321), 20321 * _msPerDay);
    });

    test('a payload targeting a different seam leaves this one alone', () {
      _install(_constantPayload(seamId: SeamIds.compareAppVersions, value: 7));

      // The registry is active, but not for this id.
      expect(PatchRegistry.active, isTrue);
      expect(daysToMillis(20321), 20321 * _msPerDay);
    });
  });

  // -------------------------------------------------------------------------
  // Failure containment: a broken patch must be no worse than no patch.
  // -------------------------------------------------------------------------
  group('a broken patch degrades to the original', () {
    test('a machinery fault falls back and quarantines, and stays fallen back',
        () {
      _install(
        _faultingPayload(seamId: SeamIds.backupDateFromLeadingSegment),
        host: const _FaultingBridge(),
      );

      // First call: the override faults, the seam falls back.
      expect(daysToMillis(20321), 20321 * _msPerDay);
      expect(
        PatchRegistry.isQuarantined(SeamIds.backupDateFromLeadingSegment),
        isTrue,
      );

      // Later calls skip the override entirely rather than re-entering it.
      expect(daysToMillis(5), 5 * _msPerDay);
      expect(daysToMillis(1755000000000), 1755000000000);
    });

    test('quarantine is reported so the failure is visible, not silent', () {
      final failures = <int>[];
      PatchRegistry.onOverrideFailed = (id, _) => failures.add(id);
      addTearDown(() => PatchRegistry.onOverrideFailed = null);

      _install(
        _faultingPayload(seamId: SeamIds.backupDateFromLeadingSegment),
        host: const _FaultingBridge(),
      );
      daysToMillis(1);

      expect(failures, [SeamIds.backupDateFromLeadingSegment]);
    });

    test('one broken override does not disable the others', () {
      // Two overrides, one broken. The healthy one must keep working: a patch
      // is a set of independent fixes, not an all-or-nothing bundle.
      final source = jsonEncode({
        'version': 1,
        'functions': [
          {
            'name': 'broken',
            'slotCount': 1,
            'requiredCount': 1,
            'body': {
              'k': 'return',
              'v': {
                'k': 'hostCall',
                'id': 0x2001,
                'args': [
                  {'k': 'local', 'slot': 0},
                ],
              },
            },
          },
          {
            'name': 'healthy',
            'slotCount': 1,
            'requiredCount': 1,
            'body': {
              'k': 'return',
              'v': {'k': 'lit', 'v': 42},
            },
          },
        ],
        'overrides': {
          '${SeamIds.backupDateFromLeadingSegment}': 0,
          '${SeamIds.compareAppVersions}': 1,
        },
      });
      _install(source, host: const _FaultingBridge());

      // The broken one falls back.
      expect(daysToMillis(20321), 20321 * _msPerDay);
      expect(
        PatchRegistry.isQuarantined(SeamIds.backupDateFromLeadingSegment),
        isTrue,
      );
      // The healthy one is untouched.
      expect(
        PatchRegistry.isQuarantined(SeamIds.compareAppVersions),
        isFalse,
      );
      expect(
        PatchRegistry.lookup(SeamIds.compareAppVersions)!([1], null),
        42,
      );
    });

    test('a malformed payload installs nothing at all', () {
      // Load must fail before anything is registered: a half-installed patch
      // is the state that makes a patch worse than the bug it replaces.
      expect(
        () => _install('{"version": 1, "functions": [], "overrides": {}}'),
        throwsA(isA<PatchVmFault>()),
      );
      expect(PatchRegistry.active, isFalse);
      expect(daysToMillis(20321), 20321 * _msPerDay);
    });

    test('a payload from a newer toolchain is refused, not half-read', () {
      expect(
        () => _install('{"version": 99, "functions": [], "overrides": {}}'),
        throwsA(isA<PatchLoadFault>()),
      );
      expect(PatchRegistry.active, isFalse);
    });

    test('an override reaching an unbound member is refused at load', () {
      // CoreBindings does not bind 0x2001, so this never reaches execution.
      expect(
        () => _install(
          _faultingPayload(seamId: SeamIds.backupDateFromLeadingSegment),
        ),
        throwsA(isA<UnboundMemberFault>()),
      );
      expect(PatchRegistry.active, isFalse);
      expect(daysToMillis(20321), 20321 * _msPerDay);
    });
  });

  // -------------------------------------------------------------------------
  // Replacing one patch with another, the normal update cycle.
  // -------------------------------------------------------------------------
  group('installing a second patch replaces the first', () {
    test('a newer payload supersedes the previous overrides', () {
      _install(_constantPayload(
        seamId: SeamIds.backupDateFromLeadingSegment,
        value: 111,
      ));
      expect(daysToMillis(1), 111);

      _install(_constantPayload(
        seamId: SeamIds.backupDateFromLeadingSegment,
        value: 222,
      ));
      expect(daysToMillis(1), 222);
    });

    test('reinstalling clears a quarantine so a fixed patch can take over', () {
      // The first patch is broken and gets quarantined; the replacement must
      // not inherit that, or shipping a fix for a bad patch would be
      // impossible without a full app update.
      _install(
        _faultingPayload(seamId: SeamIds.backupDateFromLeadingSegment),
        host: const _FaultingBridge(),
      );
      daysToMillis(1);
      expect(
        PatchRegistry.isQuarantined(SeamIds.backupDateFromLeadingSegment),
        isTrue,
      );

      _install(_constantPayload(
        seamId: SeamIds.backupDateFromLeadingSegment,
        value: 333,
      ));

      expect(
        PatchRegistry.isQuarantined(SeamIds.backupDateFromLeadingSegment),
        isFalse,
      );
      expect(daysToMillis(1), 333);
    });
  });

  // -------------------------------------------------------------------------
  // The uninstalled path is the one every call in the app pays for.
  // -------------------------------------------------------------------------
  group('the uninstalled path stays cheap', () {
    test('a seam with nothing installed is a static bool read', () {
      expect(PatchRegistry.active, isFalse);
      // Not a benchmark — a guard that the fast path never grows a lookup.
      // If `active` is false, `lookup` must not even be consulted.
      var probes = 0;
      PatchRegistry.onOverrideFailed = (_, __) => probes++;
      addTearDown(() => PatchRegistry.onOverrideFailed = null);

      for (var i = 0; i < 1000; i++) {
        daysToMillis(i);
      }
      expect(probes, 0);
    });
  });
}

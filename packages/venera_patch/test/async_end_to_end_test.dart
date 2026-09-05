// The async chain, end to end: payload -> loader -> binder -> async seam ->
// awaited result -> fallback.
//
// The synchronous chain has its own end-to-end test. This one exists because
// almost everything worth patching in this app is async, and the async path has
// its own failure modes: a Future can leak where a value was expected, a
// machinery fault can surface after suspension, and a fallback has to re-run the
// original *without* double-applying whatever the override already awaited.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';
// Direct: building a test bridge and matching on PatchThrow needs VM types the
// app-facing barrel does not re-export. The app loads payloads; it never
// constructs a bridge by hand or matches on an interpreted throw.
import 'package:venera_patch_vm/venera_patch_vm.dart';

// ---------------------------------------------------------------------------
// Subject: an async seam over a function that fetches and post-processes.
// ---------------------------------------------------------------------------

/// Records what the "network" was asked for, so a test can prove whether the
/// original ran, the override ran, or both.
final _calls = <String>[];

/// Stands in for a host async API a patch would call.
Future<String> _fetch(String key) async {
  _calls.add(key);
  await Future<void>.delayed(Duration.zero);
  return 'raw:$key';
}

/// The patchable function. Mirrors the shape of real code in this repo: an
/// await, then a transformation of the result.
Future<String> loadLabel(String key) {
  return patchedAsync(
    SeamIds.compareAppVersions, // reusing a stable id for the test
    [key],
    () => _loadLabelOrig(key),
  );
}

Future<String> _loadLabelOrig(String key) async {
  final raw = await _fetch(key);
  return raw.toUpperCase();
}

// ---------------------------------------------------------------------------
// Host bridge: the async members a patch is allowed to reach.
// ---------------------------------------------------------------------------

const int idFetch = 0x2001;
const int idUpper = 0x2002;
const int idFaultAsync = 0x2003;

HostBridge _bridge() => LayeredHostBridge(
      MapHostBridge(
        {
          idFetch: (recv, pos, named) => _fetch(pos[0] as String),
          idUpper: (recv, pos, named) => (pos[0] as String).toUpperCase(),
          idFaultAsync: (recv, pos, named) async {
            await Future<void>.delayed(Duration.zero);
            throw const ResourceLimitFault('simulated machinery failure');
          },
        },
        const {
          idFetch: 'test.fetch',
          idUpper: 'String.toUpperCase',
          idFaultAsync: 'test.faultAsync',
        },
      ),
    );

// ---------------------------------------------------------------------------
// Payloads, as the compiler would emit them.
// ---------------------------------------------------------------------------

/// `(key) async { var raw = await fetch(key); return 'patched:' + raw; }`
String _asyncPatch({required int seamId}) => jsonEncode({
      'version': 1,
      'functions': [
        {
          'name': 'loadLabel',
          'slotCount': 2,
          'requiredCount': 1,
          'isAsync': true,
          'body': {
            'k': 'block',
            'body': [
              {
                'k': 'var',
                'slot': 1,
                'init': {
                  'k': 'await',
                  'v': {
                    'k': 'hostCall',
                    'id': idFetch,
                    'args': [
                      {'k': 'local', 'slot': 0},
                    ],
                  },
                },
              },
              {
                'k': 'return',
                'v': {
                  'k': 'bin',
                  'op': 'add',
                  'l': {'k': 'lit', 'v': 'patched:'},
                  'r': {'k': 'local', 'slot': 1},
                },
              },
            ],
          },
        },
      ],
      'overrides': {'$seamId': 0},
    });

/// An async override whose awaited host call raises a machinery fault.
String _faultingAsyncPatch({required int seamId}) => jsonEncode({
      'version': 1,
      'functions': [
        {
          'name': 'broken',
          'slotCount': 2,
          'requiredCount': 1,
          'isAsync': true,
          'body': {
            'k': 'return',
            'v': {
              'k': 'await',
              'v': {'k': 'hostCall', 'id': idFaultAsync},
            },
          },
        },
      ],
      'overrides': {'$seamId': 0},
    });

/// An async override that throws a *business* exception after awaiting.
String _throwingAsyncPatch({required int seamId}) => jsonEncode({
      'version': 1,
      'functions': [
        {
          'name': 'rejects',
          'slotCount': 2,
          'requiredCount': 1,
          'isAsync': true,
          'body': {
            'k': 'block',
            'body': [
              {
                'k': 'var',
                'slot': 1,
                'init': {
                  'k': 'await',
                  'v': {
                    'k': 'hostCall',
                    'id': idFetch,
                    'args': [
                      {'k': 'local', 'slot': 0},
                    ],
                  },
                },
              },
              {
                'k': 'throw',
                'v': {'k': 'lit', 'v': 'key rejected by patch'},
              },
            ],
          },
        },
      ],
      'overrides': {'$seamId': 0},
    });

/// A payload marked synchronous while containing an await — a compiler bug.
String _syncPayloadWithAwait({required int seamId}) => jsonEncode({
      'version': 1,
      'functions': [
        {
          'name': 'mislabelled',
          'slotCount': 2,
          'requiredCount': 1,
          // isAsync omitted: claims to be synchronous.
          'body': {
            'k': 'return',
            'v': {
              'k': 'await',
              'v': {
                'k': 'hostCall',
                'id': idFetch,
                'args': [
                  {'k': 'local', 'slot': 0},
                ],
              },
            },
          },
        },
      ],
      'overrides': {'$seamId': 0},
    });

void _install(String source) {
  final program = VirLoader(host: _bridge()).loadJson(source);
  PatchRegistry.installOverrides(VmOverrideBinder.bind(program));
}

void main() {
  setUp(() {
    PatchRegistry.clear();
    _calls.clear();
  });
  tearDown(PatchRegistry.clear);

  group('an async patch changes async behaviour', () {
    test('the original runs when nothing is installed', () async {
      expect(await loadLabel('cover'), 'RAW:COVER');
      expect(_calls, ['cover']);
    });

    test('an installed async override takes over and awaits', () async {
      _install(_asyncPatch(seamId: SeamIds.compareAppVersions));

      // The override awaits the host fetch itself, then transforms differently.
      expect(await loadLabel('cover'), 'patched:raw:cover');
      // Fetched exactly once: the override ran instead of the original, not as
      // well as it.
      expect(_calls, ['cover']);
    });

    test('clearing the registry restores the original async behaviour',
        () async {
      _install(_asyncPatch(seamId: SeamIds.compareAppVersions));
      expect(await loadLabel('a'), 'patched:raw:a');

      PatchRegistry.clear();
      expect(await loadLabel('b'), 'RAW:B');
    });

    test('the seam returns a real Future, not a nested one', () async {
      _install(_asyncPatch(seamId: SeamIds.compareAppVersions));
      final result = loadLabel('x');
      expect(result, isA<Future<String>>());
      // A Future<Future<String>> would satisfy `isA<Future>` but blow up here.
      expect(await result, isA<String>());
    });
  });

  group('async failure containment', () {
    test('a machinery fault after suspension falls back to the original',
        () async {
      _install(_faultingAsyncPatch(seamId: SeamIds.compareAppVersions));

      // The override suspends, faults, and the seam runs the original instead.
      expect(await loadLabel('cover'), 'RAW:COVER');
      expect(
        PatchRegistry.isQuarantined(SeamIds.compareAppVersions),
        isTrue,
      );
    });

    test('after quarantine, later calls skip the override entirely', () async {
      _install(_faultingAsyncPatch(seamId: SeamIds.compareAppVersions));
      await loadLabel('first');
      _calls.clear();

      expect(await loadLabel('second'), 'RAW:SECOND');
      // One fetch, from the original only — the broken override is not re-entered.
      expect(_calls, ['second']);
    });

    test('a business exception after an await propagates, not falls back',
        () async {
      // The patch awaited, then decided to reject. That is the patch working
      // correctly; falling back here would silently run the old code and make a
      // deliberate rejection look like a machinery failure.
      _install(_throwingAsyncPatch(seamId: SeamIds.compareAppVersions));

      await expectLater(
        loadLabel('cover'),
        throwsA(
          isA<PatchThrow>()
              .having((e) => e.value, 'value', 'key rejected by patch'),
        ),
      );
      expect(
        PatchRegistry.isQuarantined(SeamIds.compareAppVersions),
        isFalse,
        reason: 'a business throw is not a machinery failure',
      );
    });

    test('a payload marked sync while containing an await is rejected at load',
        () async {
      // The compiler is supposed to make this impossible. If it slips through,
      // it must fail at load rather than leak a Future where the seam's
      // signature promises a value.
      expect(
        () => _install(_syncPayloadWithAwait(seamId: SeamIds.compareAppVersions)),
        throwsA(isA<PatchLoadFault>()),
      );
      expect(PatchRegistry.active, isFalse);
      expect(await loadLabel('cover'), 'RAW:COVER');
    });
  });

  group('core Future combinators are reachable from a patch', () {
    test('a patch can await Future.value', () async {
      final source = jsonEncode({
        'version': 1,
        'functions': [
          {
            'name': 'usesFutureValue',
            'slotCount': 2,
            'requiredCount': 1,
            'isAsync': true,
            'body': {
              'k': 'return',
              'v': {
                'k': 'await',
                'v': {
                  'k': 'hostCall',
                  'id': CoreIds.futureValue,
                  'args': [
                    {'k': 'lit', 'v': 'from-core'},
                  ],
                },
              },
            },
          },
        ],
        'overrides': {'${SeamIds.compareAppVersions}': 0},
      });
      _install(source);
      expect(await loadLabel('ignored'), 'from-core');
    });

    test('a patch can await Future.wait over several fetches', () async {
      // The shape of a real fix: fan out, gather, join. Proves the interpreter
      // can hold a list of futures and await them as a group.
      final source = jsonEncode({
        'version': 1,
        'functions': [
          {
            'name': 'usesFutureWait',
            'slotCount': 3,
            'requiredCount': 1,
            'isAsync': true,
            'body': {
              'k': 'block',
              'body': [
                {
                  'k': 'var',
                  'slot': 1,
                  'init': {
                    'k': 'list',
                    'items': [
                      {
                        'k': 'hostCall',
                        'id': idFetch,
                        'args': [
                          {'k': 'lit', 'v': 'a'},
                        ],
                      },
                      {
                        'k': 'hostCall',
                        'id': idFetch,
                        'args': [
                          {'k': 'lit', 'v': 'b'},
                        ],
                      },
                    ],
                  },
                },
                {
                  'k': 'var',
                  'slot': 2,
                  'init': {
                    'k': 'await',
                    'v': {
                      'k': 'hostCall',
                      'id': CoreIds.futureWait,
                      'args': [
                        {'k': 'local', 'slot': 1},
                      ],
                    },
                  },
                },
                {
                  'k': 'return',
                  'v': {
                    'k': 'hostCall',
                    'id': CoreIds.listJoin,
                    'recv': {'k': 'local', 'slot': 2},
                    'args': [
                      {'k': 'lit', 'v': '|'},
                    ],
                  },
                },
              ],
            },
          },
        ],
        'overrides': {'${SeamIds.compareAppVersions}': 0},
      });
      _install(source);

      expect(await loadLabel('ignored'), 'raw:a|raw:b');
      expect(_calls, ['a', 'b']);
    });

    test('a patch can await Future.delayed', () async {
      final source = jsonEncode({
        'version': 1,
        'functions': [
          {
            'name': 'usesDelay',
            'slotCount': 2,
            'requiredCount': 1,
            'isAsync': true,
            'body': {
              'k': 'block',
              'body': [
                {
                  'k': 'expr',
                  'e': {
                    'k': 'await',
                    'v': {
                      'k': 'hostCall',
                      'id': CoreIds.futureDelayedMs,
                      'args': [
                        {'k': 'lit', 'v': 1},
                      ],
                    },
                  },
                },
                {
                  'k': 'return',
                  'v': {'k': 'lit', 'v': 'after-delay'},
                },
              ],
            },
          },
        ],
        'overrides': {'${SeamIds.compareAppVersions}': 0},
      });
      _install(source);
      expect(await loadLabel('ignored'), 'after-delay');
    });
  });
}

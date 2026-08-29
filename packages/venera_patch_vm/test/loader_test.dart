// Loader tests: a malformed payload must die at load, never mid-operation.
//
// The loader is the security boundary of the whole mechanism. Not against a
// hostile bundle — only our own signing key can produce one — but against our
// own tooling disagreeing with the binary it targets, which is a real and
// recurring risk across app versions. The failure mode that matters is a patch
// that starts running, applies half its side effects, and *then* hits a bad
// index: that is strictly worse than the bug it was meant to fix. So every
// rejection path gets a test.

import 'package:test/test.dart';
import 'package:venera_patch_vm/venera_patch_vm.dart';

/// A bridge with a few members bound, mirroring what a real core surface looks
/// like to the loader.
HostBridge _bridge() => MapHostBridge(
  {
    1: (recv, pos, named) => (recv as String).length,
    2: (recv, pos, named) => (recv as String).substring(pos[0] as int),
    3: (recv, pos, named) => (recv as String).indexOf(pos[0] as String),
  },
  {1: 'String.length', 2: 'String.substring', 3: 'String.indexOf'},
  {10: (v) => v is String, 11: (v) => v is int},
);

/// Minimal well-formed payload: one function returning a constant.
Map<String, Object?> _payload({
  Object? version = 1,
  List<Object?>? functions,
  Map<String, Object?>? overrides,
}) => {
  'version': version,
  'functions': functions ??
      [
        {
          'name': 'answer',
          'slotCount': 0,
          'requiredCount': 0,
          'body': {
            'k': 'return',
            'v': {'k': 'lit', 'v': 42},
          },
        },
      ],
  'overrides': overrides ?? {'100': 0},
};

VmProgram _load(Map<String, Object?> payload) =>
    VirLoader(host: _bridge()).load(payload);

void main() {
  group('a well-formed payload loads and runs', () {
    test('a single function round-trips from JSON to a result', () {
      final program = _load(_payload());
      final fn = program.overrideFor(100);
      expect(fn, isNotNull);
      expect(fn!.invoke([]), 42);
    });

    test('loadJson accepts the same payload as a string', () {
      const source = '''
      {
        "version": 1,
        "functions": [
          {
            "name": "double",
            "slotCount": 1,
            "requiredCount": 1,
            "body": {
              "k": "return",
              "v": {
                "k": "bin", "op": "mul",
                "l": {"k": "local", "slot": 0},
                "r": {"k": "lit", "v": 2}
              }
            }
          }
        ],
        "overrides": {"7": 0}
      }
      ''';
      final program = VirLoader(host: _bridge()).loadJson(source);
      expect(program.overrideFor(7)!.invoke([21]), 42);
    });

    test('a body with control flow, locals and a host call executes', () {
      // Shape of a real parsing helper: guard, host call, loop, arithmetic.
      final program = _load(_payload(
        functions: [
          {
            'name': 'prefixLen',
            'slotCount': 2,
            'requiredCount': 1,
            'body': {
              'k': 'block',
              'body': [
                {
                  'k': 'var',
                  'slot': 1,
                  'init': {
                    'k': 'hostCall',
                    'id': 3,
                    'recv': {'k': 'local', 'slot': 0},
                    'args': [
                      {'k': 'lit', 'v': '-'},
                    ],
                  },
                },
                {
                  'k': 'if',
                  'c': {
                    'k': 'bin',
                    'op': 'lt',
                    'l': {'k': 'local', 'slot': 1},
                    'r': {'k': 'lit', 'v': 0},
                  },
                  'then': {
                    'k': 'return',
                    'v': {'k': 'lit', 'v': -1},
                  },
                },
                {
                  'k': 'return',
                  'v': {'k': 'local', 'slot': 1},
                },
              ],
            },
          },
        ],
        overrides: {'1': 0},
      ));
      final fn = program.overrideFor(1)!;
      expect(fn.invoke(['20321-2.2.12']), 5);
      expect(fn.invoke(['nodash']), -1);
    });

    test('mutual recursion resolves across the function table', () {
      // isEven(n) = n == 0 ? true : isOdd(n - 1), and vice versa. Function 0
      // calls function 1 before function 1 exists, which is exactly what the
      // loader's two-pass construction is for.
      Map<String, Object?> parity(String name, int other, bool base) => {
        'name': name,
        'slotCount': 1,
        'requiredCount': 1,
        'body': {
          'k': 'return',
          'v': {
            'k': 'cond',
            'c': {
              'k': 'bin',
              'op': 'eq',
              'l': {'k': 'local', 'slot': 0},
              'r': {'k': 'lit', 'v': 0},
            },
            't': {'k': 'lit', 'v': base},
            'e': {
              'k': 'vmCall',
              'fn': other,
              'args': [
                {
                  'k': 'bin',
                  'op': 'sub',
                  'l': {'k': 'local', 'slot': 0},
                  'r': {'k': 'lit', 'v': 1},
                },
              ],
            },
          },
        },
      };
      final program = _load(_payload(
        functions: [parity('isEven', 1, true), parity('isOdd', 0, false)],
        overrides: {'1': 0},
      ));
      final isEven = program.overrideFor(1)!;
      expect(isEven.invoke([10]), isTrue);
      expect(isEven.invoke([7]), isFalse);
    });

    test('parameter defaults are compiled and applied', () {
      final program = _load(_payload(
        functions: [
          {
            'name': 'greet',
            'slotCount': 2,
            'requiredCount': 1,
            'optionalCount': 1,
            'defaults': {
              '1': {'k': 'lit', 'v': '!'},
            },
            'body': {
              'k': 'return',
              'v': {
                'k': 'interp',
                'parts': [
                  {'k': 'local', 'slot': 0},
                  {'k': 'local', 'slot': 1},
                ],
              },
            },
          },
        ],
        overrides: {'5': 0},
      ));
      final fn = program.overrideFor(5)!;
      expect(fn.invoke(['hi']), 'hi!');
      expect(fn.invoke(['hi', '?']), 'hi?');
    });
  });

  group('version and envelope', () {
    test('an unknown wire version is refused, not best-effort parsed', () {
      // Silently ignoring a field from a newer format is how a patch ends up
      // doing something subtly different from what it declares.
      expect(
        () => _load(_payload(version: 2)),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a missing version is refused', () {
      final p = _payload()..remove('version');
      expect(() => _load(p), throwsA(isA<PatchLoadFault>()));
    });

    test('invalid JSON is a load fault, not a raw FormatException', () {
      expect(
        () => VirLoader(host: _bridge()).loadJson('{not json'),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a payload with no functions is refused', () {
      expect(
        () => _load(_payload(functions: const [])),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a payload claiming no overrides is refused', () {
      // A bundle that overrides nothing can only be a build mistake, and
      // installing it would consume a slot and a version number for nothing.
      expect(
        () => _load(_payload(overrides: const {})),
        throwsA(isA<PatchLoadFault>()),
      );
    });
  });

  group('slots and indices are range checked before execution', () {
    test('a local read past slotCount is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'oob',
              'slotCount': 1,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {'k': 'local', 'slot': 5},
              },
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a negative slot is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'neg',
              'slotCount': 2,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {'k': 'local', 'slot': -1},
              },
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('more parameters than slots is refused', () {
      // Parameters occupy the leading slots, so a frame too small to hold them
      // would silently corrupt neighbouring locals instead of failing.
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'tooMany',
              'slotCount': 1,
              'requiredCount': 3,
              'body': {'k': 'return'},
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('an absurd slotCount is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'huge',
              'slotCount': 100000,
              'requiredCount': 0,
              'body': {'k': 'return'},
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a named-parameter slot outside the frame is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'badNamed',
              'slotCount': 1,
              'requiredCount': 0,
              'namedSlots': {'x': 9},
              'body': {'k': 'return'},
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a default for a slot outside the frame is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'badDefault',
              'slotCount': 1,
              'requiredCount': 0,
              'defaults': {
                '7': {'k': 'lit', 'v': 1},
              },
              'body': {'k': 'return'},
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a vmCall to a function index that does not exist is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'callsGhost',
              'slotCount': 0,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {'k': 'vmCall', 'fn': 99},
              },
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('an override pointing outside the function table is refused', () {
      expect(
        () => _load(_payload(overrides: {'100': 4})),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a non-integer override key is refused', () {
      expect(
        () => _load(_payload(overrides: {'notAnInt': 0})),
        throwsA(isA<PatchLoadFault>()),
      );
    });
  });

  group('host surface: a patch cannot reach what it was not given', () {
    test('a call to an unbound member is refused at load', () {
      // The patch compiler is supposed to make this impossible by checking
      // against the target build's surface manifest. This is the backstop for
      // when that guarantee is violated anyway — a manifest/binary mismatch —
      // and it must fail before running, not on the call.
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'reachesOut',
              'slotCount': 0,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {'k': 'hostCall', 'id': 4242},
              },
            },
          ],
        )),
        throwsA(isA<UnboundMemberFault>()),
      );
    });

    test('a bound member with a receiver and args loads', () {
      final program = _load(_payload(
        functions: [
          {
            'name': 'len',
            'slotCount': 1,
            'requiredCount': 1,
            'body': {
              'k': 'return',
              'v': {
                'k': 'hostCall',
                'id': 1,
                'recv': {'k': 'local', 'slot': 0},
              },
            },
          },
        ],
        overrides: {'2': 0},
      ));
      expect(program.overrideFor(2)!.invoke(['abcd']), 4);
    });

    test('an unbound type id in a catch clause is refused at load', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'catchesGhostType',
              'slotCount': 1,
              'requiredCount': 0,
              'body': {
                'k': 'try',
                'body': {
                  'k': 'throw',
                  'v': {'k': 'lit', 'v': 'x'},
                },
                'catches': [
                  {'type': 9999, 'slot': 0, 'body': {'k': 'return'}},
                ],
              },
            },
          ],
        )),
        throwsA(isA<PatchVmFault>()),
      );
    });
  });

  group('malformed node shapes', () {
    test('an unknown expression kind is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'weird',
              'slotCount': 0,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {'k': 'quantumLeap'},
              },
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('an unknown statement kind is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'weirdStmt',
              'slotCount': 0,
              'requiredCount': 0,
              'body': {'k': 'gotoConsideredHarmful'},
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a node with no kind is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'noKind',
              'slotCount': 0,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {'value': 1},
              },
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('an unknown binary operator is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'badOp',
              'slotCount': 0,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {
                  'k': 'bin',
                  'op': 'exponentiateSomehow',
                  'l': {'k': 'lit', 'v': 1},
                  'r': {'k': 'lit', 'v': 2},
                },
              },
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a literal carrying a non-primitive value is refused', () {
      // Literals come straight from JSON, so anything but a primitive means the
      // payload and the loader disagree about the encoding.
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'badLit',
              'slotCount': 0,
              'requiredCount': 0,
              'body': {
                'k': 'return',
                'v': {
                  'k': 'lit',
                  'v': {'nested': 'object'},
                },
              },
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a function whose body is not an object is refused', () {
      expect(
        () => _load(_payload(
          functions: [
            {
              'name': 'stringBody',
              'slotCount': 0,
              'requiredCount': 0,
              'body': 'return 42;',
            },
          ],
        )),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a functions list containing a non-object is refused', () {
      expect(
        () => _load(_payload(functions: ['not a function'])),
        throwsA(isA<PatchLoadFault>()),
      );
    });

    test('a payload that is not an object at all is refused', () {
      expect(
        () => VirLoader(host: _bridge()).load(<Object?>[1, 2, 3]),
        throwsA(isA<PatchLoadFault>()),
      );
    });
  });

  group('limits are attached to loaded functions', () {
    test('the loader threads its limits into every function', () {
      const tight = VmLimits(maxCallDepth: 4, maxLoopIterations: 100);
      final program = VirLoader(host: _bridge(), limits: tight).load(_payload(
        functions: [
          {
            'name': 'recurse',
            'slotCount': 1,
            'requiredCount': 1,
            'body': {
              'k': 'return',
              'v': {
                'k': 'vmCall',
                'fn': 0,
                'args': [
                  {
                    'k': 'bin',
                    'op': 'add',
                    'l': {'k': 'local', 'slot': 0},
                    'r': {'k': 'lit', 'v': 1},
                  },
                ],
              },
            },
          },
        ],
        overrides: {'1': 0},
      ));
      // Unbounded recursion must hit the interpreter's own depth counter. A
      // native stack overflow cannot be caught in Dart and takes the process
      // down — indistinguishable, on a user's device, from the crashes this
      // mechanism exists to fix.
      expect(
        () => program.overrideFor(1)!.invoke([0]),
        throwsA(isA<ResourceLimitFault>()),
      );
    });
  });
}

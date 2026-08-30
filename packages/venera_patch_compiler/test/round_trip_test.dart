// Round trip: Dart source -> compiler -> VIR -> VM -> answer.
//
// This is the test that makes the compiler trustworthy. Each case writes real
// Dart, compiles it, loads the output into the interpreter, runs it, and
// compares against the same logic executed natively. A compiler that emits
// plausible-looking VIR which computes something slightly different would ship a
// new bug under the banner of a fix — so agreement with native Dart, not merely
// "it produced a payload", is what gets asserted.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:venera_patch_compiler/venera_patch_compiler.dart';
import 'package:venera_patch_vm/venera_patch_vm.dart';

// ---------------------------------------------------------------------------
// A small host surface, mirroring what the app's generated table provides.
// Ids are arbitrary but must agree between the manifest and the bridge — which
// is exactly the agreement the surface manifest exists to enforce.
// ---------------------------------------------------------------------------
const _idStringLength = 0x0100;
const _idStringIndexOf = 0x0101;
const _idStringSubstring = 0x0102;
const _idStringCodeUnitAt = 0x0103;
const _idStringToUpperCase = 0x0104;
const _idStringSplit = 0x0105;
const _idStringTrim = 0x0106;
const _idListLength = 0x0200;
const _idListAdd = 0x0201;
const _idIntParse = 0x0300;
const _idIntTryParse = 0x0301;
const _idMathMax = 0x0400;
const _idFetch = 0x0500;
const _idDelayed = 0x0501;
const _idTypeString = 0x1000;
const _idTypeInt = 0x1001;
const _idTypeFormatException = 0x1002;

HostBridge _bridge() => MapHostBridge(
      {
        _idStringLength: (r, a, n) => (r as String).length,
        _idStringIndexOf: (r, a, n) => (r as String).indexOf(a[0] as String),
        _idStringSubstring: (r, a, n) => a.length == 1
            ? (r as String).substring(a[0] as int)
            : (r as String).substring(a[0] as int, a[1] as int),
        _idStringCodeUnitAt: (r, a, n) => (r as String).codeUnitAt(a[0] as int),
        _idStringToUpperCase: (r, a, n) => (r as String).toUpperCase(),
        _idStringSplit: (r, a, n) => (r as String).split(a[0] as String),
        _idStringTrim: (r, a, n) => (r as String).trim(),
        _idListLength: (r, a, n) => (r as List).length,
        _idListAdd: (r, a, n) {
          (r as List).add(a[0]);
          return null;
        },
        _idIntParse: (r, a, n) => int.parse(a[0] as String),
        _idIntTryParse: (r, a, n) => int.tryParse(a[0] as String),
        _idMathMax: (r, a, n) => (a[0] as num) > (a[1] as num) ? a[0] : a[1],
        // Async members: the whole point of await lowering.
        _idFetch: (r, a, n) async {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return (a[0] as int) * 10;
        },
        _idDelayed: (r, a, n) async {
          await Future<void>.delayed(Duration(milliseconds: a[0] as int));
          return a.length > 1 ? a[1] : null;
        },
      },
      const {},
      {
        _idTypeString: (v) => v is String,
        _idTypeInt: (v) => v is int,
        _idTypeFormatException: (v) => v is FormatException,
      },
    );

SurfaceManifest _surface({Map<String, int> seams = const {'target': 1}}) =>
    SurfaceManifest(
      appVersion: '2.2.12',
      builtinPatchVersion: 0,
      members: const {
        'String.length': _idStringLength,
        'String.indexOf': _idStringIndexOf,
        'String.substring': _idStringSubstring,
        'String.codeUnitAt': _idStringCodeUnitAt,
        'String.toUpperCase': _idStringToUpperCase,
        'String.split': _idStringSplit,
        'String.trim': _idStringTrim,
        'List.length': _idListLength,
        'List.add': _idListAdd,
        'int.parse': _idIntParse,
        'int.tryParse': _idIntTryParse,
        'fetch': _idFetch,
        'delayed': _idDelayed,
      },
      types: const {
        'String': _idTypeString,
        'int': _idTypeInt,
        'FormatException': _idTypeFormatException,
      },
      seams: seams,
    );

late Directory _tmp;

/// Compiles [source] and returns the loaded program.
///
/// Declarations the patch calls but does not define (host functions like
/// `fetch`) are declared as `external` so the analyzer resolves them while the
/// compiler routes them through the surface manifest.
Future<VmProgram> _compile(
  String source, {
  SurfaceManifest? surface,
  HostBridge? host,
}) async {
  final file = File('${_tmp.path}/patch_${source.hashCode}.dart');
  file.writeAsStringSync('${_preamble()}\n$source\n');
  final payload = await PatchCompiler(surface ?? _surface())
      .compileFiles([file.path]);
  return VirLoader(host: host ?? _bridge()).load(payload);
}

/// Writes the declarations a patch imports, and returns the import line.
///
/// They live in a *separate, imported* file rather than inline, because that is
/// how a real patch is written — and because the compiler is right to reject
/// anything but functions in the file it compiles. Imported declarations are
/// resolved by the analyzer and never compiled, which is exactly the split we
/// want: the annotation and the host signatures exist for type checking, while
/// the calls themselves resolve through the surface manifest.
String _preamble() {
  File('${_tmp.path}/_stubs.dart').writeAsStringSync('''
/// Marks a function as taking over a seam. Mirrors the real annotation.
class PatchOverride {
  const PatchOverride(this.seam);
  final String seam;
}

// Host functions the patch may call. `external` because the body lives in the
// app: the compiler routes each call through the surface manifest to a member
// id, and the bridge supplies the implementation at run time.
external Future<int> fetch(int id);
external Future<Object?> delayed(int ms, [Object? value]);
''');
  return "import '_stubs.dart';";
}

void main() {
  setUp(() {
    _tmp = Directory.systemTemp.createTempSync('venera_patch_rt');
  });
  tearDown(() {
    try {
      _tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A leftover temp dir is not worth failing a test over.
    }
  });

  // -------------------------------------------------------------------------
  // Arithmetic and locals: the floor everything else stands on.
  // -------------------------------------------------------------------------
  group('compiled arithmetic agrees with native', () {
    test('a straight-line expression body', () async {
      int native(int a, int b) => a * 2 + b - 1;

      final program = await _compile('''
@PatchOverride('target')
int target(int a, int b) => a * 2 + b - 1;
''');
      final fn = program.overrideFor(1)!;
      for (final pair in [(3, 4), (0, 0), (-5, 12), (100, -100)]) {
        expect(fn.invoke([pair.$1, pair.$2]), native(pair.$1, pair.$2));
      }
    });

    test('locals, reassignment and integer division', () async {
      int native(int n) {
        var acc = 0;
        var i = n;
        while (i > 0) {
          acc = acc + i % 10;
          i = i ~/ 10;
        }
        return acc;
      }

      final program = await _compile('''
@PatchOverride('target')
int target(int n) {
  var acc = 0;
  var i = n;
  while (i > 0) {
    acc = acc + i % 10;
    i = i ~/ 10;
  }
  return acc;
}
''');
      final fn = program.overrideFor(1)!;
      for (final n in [0, 7, 19, 20321, 999999]) {
        expect(fn.invoke([n]), native(n), reason: 'digit sum of $n');
      }
    });

    test('a negative modulo follows Dart, not C', () async {
      final program = await _compile('''
@PatchOverride('target')
int target(int a, int b) => a % b;
''');
      final fn = program.overrideFor(1)!;
      expect(fn.invoke([-7, 3]), -7 % 3);
      expect(fn.invoke([7, -3]), 7 % -3);
    });
  });

  // -------------------------------------------------------------------------
  // Control flow
  // -------------------------------------------------------------------------
  group('compiled control flow agrees with native', () {
    test('if/else chains', () async {
      String native(int n) {
        if (n < 0) {
          return 'negative';
        } else if (n == 0) {
          return 'zero';
        } else {
          return 'positive';
        }
      }

      final program = await _compile('''
@PatchOverride('target')
String target(int n) {
  if (n < 0) {
    return 'negative';
  } else if (n == 0) {
    return 'zero';
  } else {
    return 'positive';
  }
}
''');
      final fn = program.overrideFor(1)!;
      for (final n in [-3, 0, 9]) {
        expect(fn.invoke([n]), native(n));
      }
    });

    test('a C-style for with break and continue', () async {
      int native(int n) {
        var sum = 0;
        for (var i = 0; i < n; i++) {
          if (i % 3 == 0) continue;
          if (i > 20) break;
          sum = sum + i;
        }
        return sum;
      }

      final program = await _compile('''
@PatchOverride('target')
int target(int n) {
  var sum = 0;
  for (var i = 0; i < n; i++) {
    if (i % 3 == 0) continue;
    if (i > 20) break;
    sum = sum + i;
  }
  return sum;
}
''');
      final fn = program.overrideFor(1)!;
      for (final n in [0, 5, 30]) {
        expect(fn.invoke([n]), native(n), reason: 'n=$n');
      }
    });

    test('for-in over a list argument', () async {
      int native(List<int> xs) {
        var total = 0;
        for (final x in xs) {
          total = total + x;
        }
        return total;
      }

      final program = await _compile('''
@PatchOverride('target')
int target(List<int> xs) {
  var total = 0;
  for (final x in xs) {
    total = total + x;
  }
  return total;
}
''');
      final fn = program.overrideFor(1)!;
      expect(fn.invoke([<int>[1, 2, 3, 4]]), native([1, 2, 3, 4]));
      expect(fn.invoke([<int>[]]), native([]));
    });

    test('a switch with a default', () async {
      String native(int code) {
        switch (code) {
          case 200:
            return 'ok';
          case 404:
          case 410:
            return 'gone';
          default:
            return 'other';
        }
      }

      final program = await _compile('''
@PatchOverride('target')
String target(int code) {
  switch (code) {
    case 200:
      return 'ok';
    case 404:
    case 410:
      return 'gone';
    default:
      return 'other';
  }
}
''');
      final fn = program.overrideFor(1)!;
      for (final c in [200, 404, 410, 500]) {
        expect(fn.invoke([c]), native(c), reason: 'code=$c');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Host calls: the only door out of the VM.
  // -------------------------------------------------------------------------
  group('host calls route through the manifest', () {
    test('an instance method on a String receiver', () async {
      final program = await _compile('''
@PatchOverride('target')
int target(String s) => s.indexOf('-');
''');
      final fn = program.overrideFor(1)!;
      expect(fn.invoke(['20321-2.2.12']), '20321-2.2.12'.indexOf('-'));
      expect(fn.invoke(['nodash']), 'nodash'.indexOf('-'));
    });

    test('a getter, and a two-argument method', () async {
      String native(String s) => s.substring(0, s.length - 1);

      final program = await _compile('''
@PatchOverride('target')
String target(String s) => s.substring(0, s.length - 1);
''');
      final fn = program.overrideFor(1)!;
      expect(fn.invoke(['venera']), native('venera'));
    });

    test('a static method', () async {
      final program = await _compile('''
@PatchOverride('target')
int target(String s) => int.parse(s);
''');
      final fn = program.overrideFor(1)!;
      expect(fn.invoke(['42']), 42);
    });

    test('a top-level host function', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<int> target(int id) async => await fetch(id);
''');
      final fn = program.overrideFor(1)!;
      expect(await (fn.invoke([7]) as Future), 70);
    });

    test('calling an unbound member fails at compile time, not on device',
        () async {
      // The whole point of the surface manifest. This build binds
      // `String.toUpperCase` but not `String.toLowerCase`, and the failure lands
      // here — naming the member and saying why — rather than as an
      // UnboundMemberFault on a user's phone midway through a patched operation.
      await expectLater(
        _compile('''
@PatchOverride('target')
String target(String s) => s.toLowerCase();
'''),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('String.toLowerCase'),
              contains('cannot reach'),
            ),
          ),
        ),
      );
    });

    test('a misspelled member gets a suggestion', () async {
      // The suggestion heuristic matches on the part after the dot, so a wrong
      // receiver or a typo that preserves the member name is caught. It is
      // deliberately not an edit-distance search: the goal is a useful hint on
      // the common mistakes, not cleverness.
      await expectLater(
        _compile('''
@PatchOverride('target')
int target(List<int> xs) => xs.length + 'abc'.length;
''', surface: SurfaceManifest(
          appVersion: '2.2.12',
          builtinPatchVersion: 0,
          // `String.length` is bound; `List.length` is not.
          members: const {'String.length': _idStringLength},
          types: const {},
          seams: const {'target': 1},
        )),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('List.length'), contains('String.length')),
          ),
        ),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Await lowering. The compiler hoists nested awaits into temp slots so the VM
  // only ever sees await in statement position; a miss would be a load fault,
  // never a silently wrong answer.
  // -------------------------------------------------------------------------
  group('await lowering', () {
    test('await in a binary expression', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<int> target(int id) async {
  return 1 + await fetch(id);
}
''');
      final fn = program.overrideFor(1)!;
      expect(await (fn.invoke([4]) as Future), 41);
    });

    test('two awaits in one expression evaluate left to right', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<int> target(int a, int b) async {
  return await fetch(a) - await fetch(b);
}
''');
      final fn = program.overrideFor(1)!;
      expect(await (fn.invoke([5, 2]) as Future), 30);
    });

    test('await inside a call argument', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<int> target(int id) async {
  return int.parse('\${await fetch(id)}');
}
''');
      final fn = program.overrideFor(1)!;
      expect(await (fn.invoke([3]) as Future), 30);
    });

    test('await inside an if condition', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<String> target(int id) async {
  if (await fetch(id) > 50) {
    return 'big';
  }
  return 'small';
}
''');
      final fn = program.overrideFor(1)!;
      expect(await (fn.invoke([9]) as Future), 'big');
      expect(await (fn.invoke([1]) as Future), 'small');
    });

    test('await inside a loop body accumulates', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<int> target(int n) async {
  var total = 0;
  for (var i = 1; i <= n; i++) {
    total = total + await fetch(i);
  }
  return total;
}
''');
      final fn = program.overrideFor(1)!;
      expect(await (fn.invoke([3]) as Future), 60);
    });

    test('await in a loop condition is refused, not silently hoisted', () async {
      // Hoisting here would be *wrong*, not merely unsupported: the condition is
      // evaluated once per iteration, and a hoisted await would evaluate it once
      // before the loop. Refusing with an actionable message beats emitting a
      // patch whose loop silently runs on a stale value.
      await expectLater(
        _compile('''
@PatchOverride('target')
Future<int> target(int limit) async {
  var i = 0;
  while (await fetch(i) < limit) {
    i = i + 1;
  }
  return i;
}
'''),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('while'), contains('break')),
          ),
        ),
      );
    });

    test('the restructuring the error suggests does compile and run', () async {
      // The counterpart to the test above: an error message is only actionable
      // if the thing it tells you to write actually works.
      final program = await _compile('''
@PatchOverride('target')
Future<int> target(int limit) async {
  var i = 0;
  while (true) {
    var value = await fetch(i);
    if (value >= limit) break;
    i = i + 1;
  }
  return i;
}
''');
      final fn = program.overrideFor(1)!;
      // fetch(n) yields n * 10, so it stops at the first i where i * 10 >= 25.
      expect(await (fn.invoke([25]) as Future), 3);
    });

    test('await inside try/catch, with the exception caught', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<String> target(String s) async {
  try {
    final n = int.parse(s);
    await fetch(n);
    return 'ok';
  } on FormatException {
    return 'bad';
  }
}
''');
      final fn = program.overrideFor(1)!;
      expect(await (fn.invoke(['3']) as Future), 'ok');
      expect(await (fn.invoke(['xyz']) as Future), 'bad');
    });

    test('an await-free async body still produces a Future', () async {
      final program = await _compile('''
@PatchOverride('target')
Future<int> target(int a) async {
  return a * 3;
}
''');
      final fn = program.overrideFor(1)!;
      final result = fn.invoke([5]);
      expect(result, isA<Future>());
      expect(await (result as Future), 15);
    });
  });

  // -------------------------------------------------------------------------
  // Multi-function patches and seam mapping
  // -------------------------------------------------------------------------
  group('patch structure', () {
    test('a helper function is callable from the override', () async {
      int native(int n) {
        int twice(int x) => x * 2;
        return twice(n) + twice(n + 1);
      }

      final program = await _compile('''
int twice(int x) => x * 2;

@PatchOverride('target')
int target(int n) => twice(n) + twice(n + 1);
''');
      final fn = program.overrideFor(1)!;
      expect(fn.invoke([4]), native(4));
    });

    test('recursion works through the function table', () async {
      int native(int n) => n <= 1 ? 1 : n * native(n - 1);

      final program = await _compile('''
@PatchOverride('target')
int target(int n) {
  if (n <= 1) return 1;
  return n * target(n - 1);
}
''');
      final fn = program.overrideFor(1)!;
      for (final n in [1, 5, 10]) {
        expect(fn.invoke([n]), native(n), reason: 'n=$n');
      }
    });

    test('several overrides map to their own seam ids', () async {
      final program = await _compile(
        '''
@PatchOverride('alpha')
int alpha(int n) => n + 1;

@PatchOverride('beta')
int beta(int n) => n + 2;
''',
        surface: _surface(seams: const {'alpha': 10, 'beta': 20}),
      );
      expect(program.overrideFor(10)!.invoke([1]), 2);
      expect(program.overrideFor(20)!.invoke([1]), 3);
    });

    test('an unknown seam name is rejected at compile time', () async {
      await expectLater(
        _compile(
          '''
@PatchOverride('nosuchseam')
int nosuchseam(int n) => n;
''',
          surface: _surface(seams: const {'target': 1}),
        ),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            contains('nosuchseam'),
          ),
        ),
      );
    });

    test('a payload with no override is rejected', () async {
      await expectLater(
        _compile('''
int helperOnly(int n) => n + 1;
'''),
        throwsA(isA<Object>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Unsupported constructs must be refused loudly, at build time.
  // -------------------------------------------------------------------------
  group('unsupported constructs fail at build time', () {
    test('a generator is refused with an actionable message', () async {
      await expectLater(
        _compile('''
@PatchOverride('target')
Iterable<int> target(int n) sync* {
  yield n;
}
'''),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            contains('generator'),
          ),
        ),
      );
    });

    test('a source file with an analysis error never compiles', () async {
      await expectLater(
        _compile('''
@PatchOverride('target')
int target(int n) => n + notADeclaredName;
'''),
        throwsA(isA<Object>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // The real bug shape this mechanism was built for.
  // -------------------------------------------------------------------------
  group('the #51 overflow guard, written as a patch', () {
    test('compiled patch reproduces the native fix exactly', () async {
      const msPerDay = 86400000;
      const maxValidMs = 8640000000000000;

      int native(int value) {
        var ms = value.abs() <= maxValidMs ~/ msPerDay ? value * msPerDay : value;
        if (ms > maxValidMs) ms = maxValidMs;
        if (ms < -maxValidMs) ms = -maxValidMs;
        return ms;
      }

      final program = await _compile('''
@PatchOverride('target')
int target(int value) {
  const msPerDay = 86400000;
  const maxValidMs = 8640000000000000;
  var ms = value.abs() <= maxValidMs ~/ msPerDay ? value * msPerDay : value;
  if (ms > maxValidMs) ms = maxValidMs;
  if (ms < -maxValidMs) ms = -maxValidMs;
  return ms;
}
''', surface: SurfaceManifest(
        appVersion: '2.2.12',
        builtinPatchVersion: 0,
        members: const {'int.abs': 0x0302},
        types: const {},
        seams: const {'target': 1},
      ), host: MapHostBridge({
        0x0302: (r, a, n) => (r as int).abs(),
      }));
      final fn = program.overrideFor(1)!;
      for (final v in [
        20321, // days-since-epoch, the normal case
        1755000000000, // a millisecond timestamp, the #51 trigger
        0,
        -20321,
        maxValidMs,
      ]) {
        expect(fn.invoke([v]), native(v), reason: 'value=$v');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Payload shape: what the loader will actually receive.
  // -------------------------------------------------------------------------
  test('the emitted payload is JSON-round-trippable', () async {
    final file = File('${_tmp.path}/shape.dart');
    file.writeAsStringSync('''
${_preamble()}

@PatchOverride('target')
int target(int n) => n + 1;
''');
    final payload = await PatchCompiler(_surface()).compileFiles([file.path]);

    // Encoded and decoded, because that is the trip a real payload takes: the
    // compiler writes it, the store hashes and verifies it, the loader decodes
    // it. Anything unencodable here would fail on a device instead.
    final decoded = jsonDecode(jsonEncode(payload));
    final program = VirLoader(host: _bridge()).load(decoded);
    expect(program.overrideFor(1)!.invoke([41]), 42);
  });
}

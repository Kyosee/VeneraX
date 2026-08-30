// The surface table and the binding switch must not drift apart.
//
// These are two halves of one fact, written in two places because neither can
// be derived from the other in AOT Dart: `core_bindings.dart` maps an integer id
// to a real Dart call, and `core_surface.dart` maps the name a patch author
// writes to that same id. Drift between them has two flavours, and both are
// quiet:
//
//  * A key in the table whose id nothing binds. The patch compiles, ships, and
//    faults on the device — exactly the failure this whole design exists to move
//    to build time.
//  * A bound id absent from the table. The API works perfectly, but the compiler
//    tells the author it is unreachable. They then write something worse, or
//    conclude the mechanism cannot do what it can.
//
// The second is the more corrosive one, because nothing ever reports it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';

/// Every `static const <name> = 0x....;` in `core_bindings.dart`, read from
/// source.
///
/// Source-reading rather than reflection: this package ships in an AOT release
/// where `dart:mirrors` does not exist, and a test that could only run on the VM
/// would be a test nobody runs. The regex is deliberately narrow — a line it
/// cannot parse shows up as a missing entry, which fails loudly, rather than as
/// a silent skip.
Map<String, int> _declaredIds() {
  final file = File('lib/src/core_bindings.dart');
  if (!file.existsSync()) {
    fail('cannot find lib/src/core_bindings.dart from ${Directory.current}');
  }
  final pattern = RegExp(
    r'^\s*static const (\w+)\s*=\s*(0x[0-9A-Fa-f]+);',
    multiLine: true,
  );
  final out = <String, int>{};
  for (final m in pattern.allMatches(file.readAsStringSync())) {
    out[m.group(1)!] = int.parse(m.group(2)!.substring(2), radix: 16);
  }
  return out;
}

void main() {
  final declared = _declaredIds();
  const bindings = CoreBindings();

  test('the id catalogue was actually parsed', () {
    // Guards the guard: if the regex stopped matching, every other test here
    // would pass vacuously.
    expect(
      declared.length,
      greaterThan(150),
      reason: 'expected to parse the full CoreIds catalogue, got $declared',
    );
    expect(declared['stringIndexOf'], 0x0108);
    expect(declared['typeString'], 0x1000);
  });

  group('every surface entry resolves to a real binding', () {
    test('members', () {
      final unbound = <String>[];
      for (final entry in CoreSurface.members.entries) {
        if (!bindings.isBound(entry.value)) {
          unbound.add('${entry.key} -> 0x${entry.value.toRadixString(16)}');
        }
      }
      expect(
        unbound,
        isEmpty,
        reason: 'these surface keys name ids nothing binds, so a patch using '
            'them would compile and then fault on a device:\n'
            '${unbound.join('\n')}',
      );
    });

    test('types', () {
      final unbound = <String>[];
      for (final entry in CoreSurface.types.entries) {
        if (!bindings.isBoundType(entry.value)) {
          unbound.add('${entry.key} -> 0x${entry.value.toRadixString(16)}');
        }
      }
      expect(unbound, isEmpty, reason: unbound.join('\n'));
    });

    test('a type id also answers isInstanceOf rather than throwing', () {
      // isBoundType is a range check; isInstanceOf is the switch that actually
      // has to have a case. A type in range but missing from the switch would
      // pass the load-time check and then fault inside exception handling.
      for (final entry in CoreSurface.types.entries) {
        expect(
          () => bindings.isInstanceOf(entry.value, 'probe'),
          returnsNormally,
          reason: '${entry.key} (0x${entry.value.toRadixString(16)}) is in '
              'range but has no isInstanceOf case',
        );
      }
    });
  });

  group('every binding is reachable from patch source', () {
    test('no declared id is missing from the surface table', () {
      final exposed = {
        ...CoreSurface.members.values,
        ...CoreSurface.types.values,
      };
      final missing = <String>[];
      declared.forEach((name, id) {
        if (!exposed.contains(id)) {
          missing.add('$name = 0x${id.toRadixString(16)}');
        }
      });
      expect(
        missing,
        isEmpty,
        reason: 'these ids are bound but no patch can name them — the compiler '
            'will report them as unreachable even though they work:\n'
            '${missing.join('\n')}',
      );
    });
  });

  group('ids are unique', () {
    test('keys sharing an id name the same member', () {
      // Sharing an id is expected and necessary. The compiler keys a call by the
      // receiver's *static* type, so `List.length` and `Iterable.length` are the
      // same call written two ways and must reach the same binding — likewise
      // `math.max` and a bare `max`.
      //
      // What must never happen is two *different* operations sharing an id: give
      // `String.trim` the id of `String.split` and every patch calling trim
      // silently splits instead. Counting collisions cannot tell those apart, so
      // the assertion is on the member name, which distinguishes them exactly.
      final byId = <int, List<String>>{};
      for (final entry in CoreSurface.members.entries) {
        byId.putIfAbsent(entry.value, () => []).add(entry.key);
      }

      String member(String key) =>
          key.contains('.') ? key.split('.').last : key;

      final suspicious = <String>[];
      byId.forEach((id, keys) {
        if (keys.length < 2) return;
        final names = keys.map(member).toSet();
        if (names.length > 1) {
          suspicious.add('0x${id.toRadixString(16)}: ${keys.join(', ')}');
        }
      });

      expect(
        suspicious,
        isEmpty,
        reason: 'these ids are shared by keys naming different members, so a '
            'patch calling one would silently get the other:\n'
            '${suspicious.join('\n')}',
      );
    });

    test('member ids and type ids occupy separate ranges', () {
      // The dispatch table and the type table are different switches. An id
      // that fell in both ranges would be answered by whichever check ran
      // first, which is not a property worth relying on.
      for (final id in CoreSurface.members.values) {
        expect(
          bindings.isBoundType(id),
          isFalse,
          reason: 'member id 0x${id.toRadixString(16)} also reads as a type id',
        );
      }
    });
  });

  group('the table is usable as a compiler surface', () {
    test('keys are either Receiver.member or a bare top-level name', () {
      final malformed = <String>[];
      for (final key in CoreSurface.members.keys) {
        if (key.isEmpty || key.startsWith('.') || key.endsWith('.')) {
          malformed.add(key);
          continue;
        }
        if (key.split('.').length > 2) malformed.add(key);
      }
      expect(malformed, isEmpty, reason: malformed.join(', '));
    });

    test('the keys a patch is most likely to reach for are present', () {
      // Not exhaustive — a spot check that the table covers the everyday
      // surface rather than only the exotic corners.
      for (final key in const [
        'String.length',
        'String.indexOf',
        'String.substring',
        'String.split',
        'String.contains',
        'List.length',
        'List.add',
        'Map.[]',
        'int.parse',
        'int.tryParse',
        'jsonDecode',
        'jsonEncode',
        'DateTime.fromMillisecondsSinceEpoch',
        'Uri.parse',
        'Future.wait',
      ]) {
        expect(
          CoreSurface.members.containsKey(key),
          isTrue,
          reason: 'the core surface is missing `$key`',
        );
      }
    });
  });
}

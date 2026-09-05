// The seam's failure semantics, and the core host surface.
//
// The load-bearing assertion in this file is the one distinguishing a machinery
// failure from a business exception. Getting it wrong produces the worst outcome
// in the whole design: a patch that correctly rejects bad input is read as
// "machinery broken", the seam silently runs the original code, and the fix
// looks installed while doing nothing. Every later investigation then has to
// start by asking which implementation is actually running.

import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';
// Imported directly: building a program by hand needs the IR node types, which
// the app-facing barrel deliberately does not re-export. The app only ever
// loads a payload; it never constructs IR.
import 'package:venera_patch_vm/venera_patch_vm.dart';

/// Builds a one-function program whose body is [body], registered as override
/// [id]. Mirrors what the loader produces, without going through JSON.
VmProgram _program({
  required int id,
  required Stmt Function() body,
  int slotCount = 4,
  int requiredCount = 1,
  HostBridge? host,
  VmLimits limits = VmLimits.standard,
}) {
  final fn = VmFunction(
    name: 'override$id',
    slotCount: slotCount,
    requiredCount: requiredCount,
    optionalCount: 0,
    namedSlots: const {},
    limits: limits,
  );
  final ctx = CompileContext(
    host: host ?? const CoreBindings(),
    limits: limits,
    functions: [VmFunctionRef(0)..target = fn],
  );
  fn.body = body().compile(ctx);
  return VmProgram(functions: [fn], overrides: {id: 0});
}

Expr _lit(Object? v) => Literal(v);
Expr _local(int slot) => LocalGet(slot);

void main() {
  setUp(PatchRegistry.clear);
  tearDown(PatchRegistry.clear);

  // -------------------------------------------------------------------------
  // The two kinds of failure. This is the whole reason this layer exists.
  // -------------------------------------------------------------------------
  group('machinery failure vs. business exception', () {
    test('a business throw reaches the caller untouched', () {
      // The patch means to throw: a validation error, a FormatException, an
      // app-level exception. It must arrive exactly as the original
      // implementation's own throw would.
      final program = _program(
        id: 1,
        requiredCount: 0,
        body: () => ThrowStmt(_lit('invalid input')),
      );
      final table = VmOverrideBinder.bind(program);

      expect(
        () => table[1]!([], null),
        throwsA(isA<PatchThrow>().having((e) => e.value, 'value', 'invalid input')),
      );
      // Crucially: NOT quarantined. The override worked exactly as written.
      expect(PatchRegistry.isQuarantined(1), isFalse);
    });

    test('a machinery fault is converted and the override is quarantined', () {
      // A bounds fault is a machinery failure: the interpreter cannot produce a
      // trustworthy answer, so the seam must fall back rather than use it.
      final program = _program(
        id: 2,
        requiredCount: 0,
        body: () => ret(IndexGet(ListLiteral([_lit(1), _lit(2)]), _lit(9))),
      );
      final table = VmOverrideBinder.bind(program);

      expect(
        () => table[2]!([], null),
        throwsA(isA<PatchVmError>().having((e) => e.overrideId, 'id', 2)),
      );
      // Quarantined, so later calls skip the override entirely instead of
      // re-entering code already known to be broken.
      expect(PatchRegistry.isQuarantined(2), isTrue);
    });

    test('a depth-ceiling fault is also machinery, not business logic', () {
      // maxCallDepth below the entry depth makes the very first call trip the
      // ceiling, standing in for the runaway recursion this bound exists for.
      final program = _program(
        id: 4,
        requiredCount: 0,
        limits: const VmLimits(maxCallDepth: -1),
        body: () => ret(_lit(1)),
      );
      final table = VmOverrideBinder.bind(program);

      expect(
        () => table[4]!([], null),
        throwsA(isA<PatchVmError>()),
      );
      expect(PatchRegistry.isQuarantined(4), isTrue);
    });

    test('quarantine is per-override: siblings keep working', () {
      // Discarding a whole patch because one override faulted would throw away
      // fixes that are working. Isolation is the point.
      final broken = _program(
        id: 5,
        requiredCount: 0,
        body: () => ret(IndexGet(ListLiteral([_lit(1)]), _lit(7))),
      );
      final healthy = _program(
        id: 6,
        requiredCount: 0,
        body: () => ret(_lit('fine')),
      );
      PatchRegistry.installOverrides({
        ...VmOverrideBinder.bind(broken),
        ...VmOverrideBinder.bind(healthy),
      });

      expect(() => PatchRegistry.lookup(5)!([], null), throwsA(isA<PatchVmError>()));
      expect(PatchRegistry.lookup(5), isNull, reason: 'quarantined');
      expect(PatchRegistry.lookup(6)!([], null), 'fine');
    });

    test('an unbound member at call time is a machinery fault', () {
      // A member that passes load-time validation but fails at call time can
      // only happen on a manifest/binary mismatch. That is our tooling being
      // inconsistent, not the patch misbehaving, so it must quarantine.
      final program = _program(
        id: 4,
        requiredCount: 0,
        host: const _BoundButFailing(),
        body: () => ret(HostCall(_BoundButFailing.claimedId)),
      );
      final table = VmOverrideBinder.bind(program);

      expect(() => table[4]!([], null), throwsA(isA<PatchVmError>()));
      expect(PatchRegistry.isQuarantined(4), isTrue);
    });

    test('a quarantined override stops being looked up, the rest survive', () {
      final fnA = VmFunction(
        name: 'a',
        slotCount: 1,
        requiredCount: 0,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
      );
      final fnB = VmFunction(
        name: 'b',
        slotCount: 1,
        requiredCount: 0,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
      );
      final ctx = CompileContext(
        host: const _BoundButFailing(),
        limits: VmLimits.standard,
        functions: [
          VmFunctionRef(0)..target = fnA,
          VmFunctionRef(1)..target = fnB,
        ],
      );
      fnA.body = ret(HostCall(_BoundButFailing.claimedId)).compile(ctx);
      fnB.body = ret(_lit('b ok')).compile(ctx);
      final program = VmProgram(
        functions: [fnA, fnB],
        overrides: {10: 0, 11: 1},
      );

      PatchRegistry.installOverrides(VmOverrideBinder.bind(program));
      expect(PatchRegistry.active, isTrue);

      // Trip the broken one.
      expect(() => PatchRegistry.lookup(10)!([], null),
          throwsA(isA<PatchVmError>()));

      // It now falls through to the original...
      expect(PatchRegistry.lookup(10), isNull);
      // ...while its sibling keeps working. Discarding a whole patch over one
      // bad override would throw away fixes that are working fine.
      expect(PatchRegistry.lookup(11)!([], null), 'b ok');
    });

    test('the quarantine callback fires so the host can log it', () {
      final seen = <int>[];
      PatchRegistry.onOverrideFailed = (id, _) => seen.add(id);
      addTearDown(() => PatchRegistry.onOverrideFailed = null);

      final program = _program(
        id: 5,
        requiredCount: 0,
        host: const _BoundButFailing(),
        body: () => ret(HostCall(_BoundButFailing.claimedId)),
      );
      final table = VmOverrideBinder.bind(program);
      expect(() => table[5]!([], null), throwsA(isA<PatchVmError>()));
      expect(seen, [5]);
    });
  });

  // -------------------------------------------------------------------------
  // The gate. Every call in the app pays for this when nothing is installed.
  // -------------------------------------------------------------------------
  group('the registry gate', () {
    test('nothing installed means the gate is closed and lookups are null', () {
      expect(PatchRegistry.active, isFalse);
      expect(PatchRegistry.lookup(1), isNull);
    });

    test('installing an empty table leaves the gate closed', () {
      // Otherwise every seam in the app would start paying for a map probe to
      // learn there is nothing to find.
      PatchRegistry.installOverrides({});
      expect(PatchRegistry.active, isFalse);
    });

    test('clear closes the gate and forgets quarantines', () {
      final program = _program(
        id: 6,
        requiredCount: 0,
        body: () => ret(_lit(1)),
      );
      PatchRegistry.installOverrides(VmOverrideBinder.bind(program));
      PatchRegistry.quarantine(6, 'test');
      expect(PatchRegistry.isQuarantined(6), isTrue);

      PatchRegistry.clear();
      expect(PatchRegistry.active, isFalse);
      expect(PatchRegistry.isQuarantined(6), isFalse);
    });

    test('reinstalling clears quarantines so a fixed patch can retry', () {
      final program = _program(
        id: 7,
        requiredCount: 0,
        body: () => ret(_lit('fresh')),
      );
      PatchRegistry.installOverrides(VmOverrideBinder.bind(program));
      PatchRegistry.quarantine(7, 'earlier failure');
      expect(PatchRegistry.lookup(7), isNull);

      PatchRegistry.installOverrides(VmOverrideBinder.bind(program));
      expect(PatchRegistry.lookup(7)!([], null), 'fresh');
    });
  });

  // -------------------------------------------------------------------------
  // orig: the wrap-rather-than-replace path
  // -------------------------------------------------------------------------
  group('the original implementation stays reachable', () {
    test('an override receives args and returns its own result', () {
      final program = _program(
        id: 8,
        body: () => ret(Binary(BinOp.mul, _local(0), _lit(2))),
      );
      final table = VmOverrideBinder.bind(program);
      expect(table[8]!([21], null), 42);
    });

    test('an override that ignores orig still gets the right answer', () {
      var origCalls = 0;
      final program = _program(
        id: 9,
        body: () => ret(_lit('patched')),
      );
      final table = VmOverrideBinder.bind(program);
      expect(table[9]!([1], () {
        origCalls++;
        return 'original';
      }), 'patched');
      expect(origCalls, 0);
    });
  });

  // -------------------------------------------------------------------------
  // Core host surface
  // -------------------------------------------------------------------------
  group('core bindings', () {
    const core = CoreBindings();

    test('string members match native semantics', () {
      expect(core.invoke(CoreIds.stringLength, 'hello', [], null), 5);
      expect(core.invoke(CoreIds.stringIndexOf, 'a-b', ['-'], null), 1);
      expect(core.invoke(CoreIds.stringSubstring, 'abcdef', [1, 3], null), 'bc');
      expect(core.invoke(CoreIds.stringToUpperCase, 'ab', [], null), 'AB');
    });

    test('list and map members match native semantics', () {
      expect(core.invoke(CoreIds.listLength, [1, 2, 3], [], null), 3);
      final list = <Object?>[1];
      core.invoke(CoreIds.listAdd, list, [2], null);
      expect(list, [1, 2]);
      expect(core.invoke(CoreIds.mapGet, {'k': 'v'}, ['k'], null), 'v');
      expect(core.invoke(CoreIds.mapGet, {'k': 'v'}, ['absent'], null), isNull);
    });

    test('json round-trips, which is what most parsing patches need', () {
      final decoded = core.invoke(CoreIds.jsonDecode, null, ['{"a":1}'], null);
      expect(decoded, {'a': 1});
    });

    test('int parsing returns null rather than throwing, like tryParse', () {
      expect(core.invoke(CoreIds.intParse, null, ['42'], null), 42);
    });

    test('an unbound id is a fault, never a silent null', () {
      expect(
        () => core.invoke(0xFFFF, null, [], null),
        throwsA(isA<UnboundMemberFault>()),
      );
      expect(core.isBound(0xFFFF), isFalse);
    });

    test('type tests answer for bound types and fault for unknown ones', () {
      expect(core.isInstanceOf(CoreIds.typeString, 'x'), isTrue);
      expect(core.isInstanceOf(CoreIds.typeString, 1), isFalse);
      expect(core.isInstanceOf(CoreIds.typeInt, 1), isTrue);
      expect(core.isBoundType(0xFFFF), isFalse);
      expect(
        () => core.isInstanceOf(0xFFFF, 'x'),
        throwsA(isA<UnboundMemberFault>()),
      );
    });

    test('a host exception propagates unchanged, not wrapped as a VM fault', () {
      // A patch calling substring with bad bounds gets Dart's own RangeError.
      // Wrapping it as a machinery fault would make a genuine patch bug look
      // like broken machinery and silently fall back.
      expect(
        () => core.invoke(CoreIds.stringSubstring, 'ab', [5, 9], null),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('layered bridge', () {
    test('app ids reach the app bridge, core ids fall through', () {
      const appId = 0x2000;
      final app = MapHostBridge({
        appId: (recv, pos, named) => 'from app',
      });
      final layered = LayeredHostBridge(app);

      expect(layered.invoke(appId, null, [], null), 'from app');
      expect(layered.invoke(CoreIds.stringLength, 'abcd', [], null), 4);
      expect(layered.isBound(appId), isTrue);
      expect(layered.isBound(CoreIds.stringLength), isTrue);
      expect(layered.isBound(0xFFFF), isFalse);
    });
  });
}

Stmt ret([Expr? v]) => ReturnStmt(v);

/// Claims to bind an id, then faults when actually called.
///
/// This models the one case load-time validation cannot catch: a surface
/// manifest that disagrees with the binary it was built against. The point of
/// the test is that this path quarantines rather than crashing.
final class _BoundButFailing implements HostBridge {
  const _BoundButFailing();

  static const int claimedId = 0x0100;

  @override
  Object? invoke(int id, Object? recv, List<Object?> a, Map<String, Object?>? n) =>
      throw UnboundMemberFault(id, 'manifest/binary mismatch');

  @override
  bool isBound(int memberId) => memberId == claimedId;

  @override
  bool isBoundType(int typeId) => false;

  @override
  String? describe(int memberId) => 'claimed#$memberId';

  @override
  bool isInstanceOf(int typeId, Object? value) => throw UnboundMemberFault(typeId);
}

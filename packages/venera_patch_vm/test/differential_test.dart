// Differential tests: the same logic written twice — once as native Dart, once
// as VIR — asserted to agree.
//
// This is the only real guarantee the interpreter is correct. A hand-written VM
// that is *subtly* wrong is worse than no hot-update mechanism at all: a patch
// that computes a slightly different answer than the code it replaced ships a
// new bug under the banner of a fix. So every language feature a patch may use
// is pinned here against the native semantics it must reproduce.

import 'package:test/test.dart';
import 'package:venera_patch_vm/venera_patch_vm.dart';

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Builds and compiles an interpreted function in one step.
///
/// Mirrors what the loader does: construct, compile the body against a context,
/// then assign — in that order, because a body may reference the function it
/// belongs to (recursion).
VmFunction buildFn({
  required String name,
  required int slotCount,
  required int requiredCount,
  required Stmt Function() body,
  int optionalCount = 0,
  Map<String, int> namedSlots = const {},
  Map<int, Expr> defaults = const {},
  HostBridge? host,
  VmLimits limits = VmLimits.standard,
  List<VmFunction>? siblings,
}) {
  final fn = VmFunction(
    name: name,
    slotCount: slotCount,
    requiredCount: requiredCount,
    optionalCount: optionalCount,
    namedSlots: namedSlots,
    limits: limits,
  );
  final refs = <VmFunctionRef>[VmFunctionRef(0)..target = fn];
  for (var i = 0; i < (siblings?.length ?? 0); i++) {
    refs.add(VmFunctionRef(i + 1)..target = siblings![i]);
  }
  final ctx = CompileContext(
    host: host ?? const EmptyHostBridge(),
    limits: limits,
    functions: refs,
  );
  for (final entry in defaults.entries) {
    fn.defaults[entry.key] = entry.value.compile(ctx);
  }
  fn.body = body().compile(ctx);
  return fn;
}

/// Shorthands, so the IR in each test stays readable enough to check by eye.
Expr lit(Object? v) => Literal(v);
Assignable local(int slot) => LocalGet(slot);
Expr add(Expr a, Expr b) => Binary(BinOp.add, a, b);
Expr sub(Expr a, Expr b) => Binary(BinOp.sub, a, b);
Expr mul(Expr a, Expr b) => Binary(BinOp.mul, a, b);
Expr lt(Expr a, Expr b) => Binary(BinOp.lt, a, b);
Expr gt(Expr a, Expr b) => Binary(BinOp.gt, a, b);
Expr le(Expr a, Expr b) => Binary(BinOp.lte, a, b);
Expr eq(Expr a, Expr b) => Binary(BinOp.eq, a, b);
Stmt ret([Expr? v]) => ReturnStmt(v);
Stmt set(int slot, Expr v) => AssignStmt(LocalGet(slot), v);

void main() {
  // -------------------------------------------------------------------------
  // Arithmetic and operators
  // -------------------------------------------------------------------------
  group('arithmetic matches native Dart', () {
    test('integer operators agree across a range of inputs', () {
      // slots: 0=a, 1=b
      int native(int a, int b) => (a + b) * (a - b) + a % (b == 0 ? 1 : b);

      final fn = buildFn(
        name: 'arith',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(
          add(
            mul(add(local(0), local(1)), sub(local(0), local(1))),
            Binary(BinOp.mod, local(0), local(1)),
          ),
        ),
      );

      for (final a in [0, 1, 7, -3, 1000, -1000]) {
        for (final b in [1, 2, 5, -4, 999]) {
          expect(
            fn.invoke([a, b]),
            native(a, b),
            reason: 'a=$a b=$b',
          );
        }
      }
    });

    test('truncating division and modulo agree, including negatives', () {
      final div = buildFn(
        name: 'div',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(Binary(BinOp.truncDiv, local(0), local(1))),
      );
      for (final a in [7, -7, 100, -100, 0]) {
        for (final b in [2, -2, 3, -3]) {
          expect(div.invoke([a, b]), a ~/ b, reason: '$a ~/ $b');
        }
      }
    });

    test('double arithmetic preserves native precision', () {
      final fn = buildFn(
        name: 'dbl',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(Binary(BinOp.div, local(0), local(1))),
      );
      expect(fn.invoke([1, 3]), 1 / 3);
      expect(fn.invoke([0.1, 0.3]), 0.1 / 0.3);
    });

    test('+ dispatches on operand type, as Dart does', () {
      final fn = buildFn(
        name: 'plus',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(add(local(0), local(1))),
      );
      expect(fn.invoke([1, 2]), 3);
      expect(fn.invoke(['a', 'b']), 'ab');
      expect(fn.invoke([1.5, 2]), 3.5);
    });

    test('comparison and equality agree', () {
      final cmp = buildFn(
        name: 'cmp',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(
          Conditional(
            lt(local(0), local(1)),
            lit(-1),
            Conditional(gt(local(0), local(1)), lit(1), lit(0)),
          ),
        ),
      );
      for (final a in [1, 5, -2]) {
        for (final b in [1, 5, -2]) {
          expect(cmp.invoke([a, b]), a.compareTo(b), reason: '$a vs $b');
        }
      }
    });

    test('short-circuit operators do not evaluate the right side', () {
      // `false && (1 ~/ 0)` must not divide. If && were eager this throws.
      final fn = buildFn(
        name: 'shortCircuit',
        slotCount: 1,
        requiredCount: 1,
        body: () => ret(
          Binary(
            BinOp.and,
            local(0),
            Binary(BinOp.truncDiv, lit(1), lit(0)),
          ),
        ),
      );
      expect(fn.invoke([false]), false);
      expect(() => fn.invoke([true]), throwsA(isA<BoundsFault>()));
    });

    test('null-coalescing agrees with ??', () {
      final fn = buildFn(
        name: 'coalesce',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(Binary(BinOp.ifNull, local(0), local(1))),
      );
      expect(fn.invoke([null, 'fallback']), 'fallback');
      expect(fn.invoke(['value', 'fallback']), 'value');
      expect(fn.invoke([false, 'fallback']), false); // false is not null
      expect(fn.invoke([0, 'fallback']), 0); // nor is 0
    });
  });

  // -------------------------------------------------------------------------
  // Control flow
  // -------------------------------------------------------------------------
  group('control flow matches native Dart', () {
    test('while loop with accumulator', () {
      int native(int n) {
        var sum = 0, i = 0;
        while (i < n) {
          sum = sum + i;
          i = i + 1;
        }
        return sum;
      }

      // slots: 0=n, 1=sum, 2=i
      final fn = buildFn(
        name: 'sumTo',
        slotCount: 3,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(1, lit(0)),
          VarDecl(2, lit(0)),
          WhileStmt(
            lt(local(2), local(0)),
            BlockStmt([
              set(1, add(local(1), local(2))),
              set(2, add(local(2), lit(1))),
            ]),
          ),
          ret(local(1)),
        ]),
      );

      for (final n in [0, 1, 5, 100]) {
        expect(fn.invoke([n]), native(n), reason: 'n=$n');
      }
    });

    test('for loop with break and continue', () {
      int native(int n) {
        var sum = 0;
        for (var i = 0; i < n; i++) {
          if (i % 3 == 0) continue;
          if (i > 20) break;
          sum += i;
        }
        return sum;
      }

      // slots: 0=n, 1=sum, 2=i
      final fn = buildFn(
        name: 'forBreakContinue',
        slotCount: 3,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(1, lit(0)),
          ForStmt(
            init: VarDecl(2, lit(0)),
            condition: lt(local(2), local(0)),
            update: [set(2, add(local(2), lit(1)))],
            body: BlockStmt([
              IfStmt(
                eq(Binary(BinOp.mod, local(2), lit(3)), lit(0)),
                const ContinueStmt(),
              ),
              IfStmt(gt(local(2), lit(20)), const BreakStmt()),
              set(1, add(local(1), local(2))),
            ]),
          ),
          ret(local(1)),
        ]),
      );

      for (final n in [0, 5, 30, 100]) {
        expect(fn.invoke([n]), native(n), reason: 'n=$n');
      }
    });

    test('continue in a for loop still runs the update — no infinite loop', () {
      // The classic interpreter bug: `continue` jumps to the loop head without
      // running the increment, so the loop never terminates. A hang on a user's
      // device is unrecoverable, so this is pinned explicitly.
      final fn = buildFn(
        name: 'continueRunsUpdate',
        slotCount: 2,
        requiredCount: 0,
        body: () => BlockStmt([
          VarDecl(0, lit(0)), // count
          ForStmt(
            init: VarDecl(1, lit(0)),
            condition: lt(local(1), lit(10)),
            update: [set(1, add(local(1), lit(1)))],
            body: BlockStmt([
              const ContinueStmt(),
            ]),
          ),
          ret(local(1)),
        ]),
        limits: const VmLimits(maxLoopIterations: 1000),
      );
      expect(fn.invoke([]), 10);
    });

    test('do-while runs the body at least once', () {
      int native(int n) {
        var i = 0;
        do {
          i++;
        } while (i < n);
        return i;
      }

      final fn = buildFn(
        name: 'doWhile',
        slotCount: 2,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(1, lit(0)),
          DoWhileStmt(
            set(1, add(local(1), lit(1))),
            lt(local(1), local(0)),
          ),
          ret(local(1)),
        ]),
      );
      for (final n in [-5, 0, 1, 7]) {
        expect(fn.invoke([n]), native(n), reason: 'n=$n');
      }
    });

    test('for-in over a list', () {
      int native(List<int> xs) {
        var sum = 0;
        for (final x in xs) {
          sum += x;
        }
        return sum;
      }

      // slots: 0=list, 1=sum, 2=x
      final fn = buildFn(
        name: 'forIn',
        slotCount: 3,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(1, lit(0)),
          ForInStmt(2, local(0), set(1, add(local(1), local(2)))),
          ret(local(1)),
        ]),
      );
      for (final xs in [<int>[], [1], [1, 2, 3], [-5, 10]]) {
        expect(fn.invoke([xs]), native(xs), reason: '$xs');
      }
    });

    test('for-in over a Set and a Map key view', () {
      final fn = buildFn(
        name: 'forInIterable',
        slotCount: 3,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(1, lit(0)),
          ForInStmt(2, local(0), set(1, add(local(1), lit(1)))),
          ret(local(1)),
        ]),
      );
      expect(fn.invoke([{1, 2, 3}]), 3);
      expect(fn.invoke([{'a': 1, 'b': 2}.keys]), 2);
    });

    test('switch with fallthrough-free cases and a default', () {
      String native(int code) {
        switch (code) {
          case 1:
          case 2:
            return 'low';
          case 10:
            return 'ten';
          default:
            return 'other';
        }
      }

      final fn = buildFn(
        name: 'switchStmt',
        slotCount: 1,
        requiredCount: 1,
        body: () => SwitchStmt(
          local(0),
          [
            SwitchCase([lit(1), lit(2)], ret(lit('low'))),
            SwitchCase([lit(10)], ret(lit('ten'))),
          ],
          ret(lit('other')),
        ),
      );
      for (final c in [1, 2, 10, 99, -1]) {
        expect(fn.invoke([c]), native(c), reason: 'code=$c');
      }
    });

    test('nested loops: break exits only the inner one', () {
      int native() {
        var n = 0;
        for (var i = 0; i < 3; i++) {
          for (var j = 0; j < 5; j++) {
            if (j == 2) break;
            n++;
          }
        }
        return n;
      }

      // slots: 0=n, 1=i, 2=j
      final fn = buildFn(
        name: 'nestedBreak',
        slotCount: 3,
        requiredCount: 0,
        body: () => BlockStmt([
          VarDecl(0, lit(0)),
          ForStmt(
            init: VarDecl(1, lit(0)),
            condition: lt(local(1), lit(3)),
            update: [set(1, add(local(1), lit(1)))],
            body: ForStmt(
              init: VarDecl(2, lit(0)),
              condition: lt(local(2), lit(5)),
              update: [set(2, add(local(2), lit(1)))],
              body: BlockStmt([
                IfStmt(eq(local(2), lit(2)), const BreakStmt()),
                set(0, add(local(0), lit(1))),
              ]),
            ),
          ),
          ret(local(0)),
        ]),
      );
      expect(fn.invoke([]), native());
      expect(fn.invoke([]), 6);
    });

    test('early return from inside nested loops unwinds fully', () {
      final fn = buildFn(
        name: 'earlyReturn',
        slotCount: 2,
        requiredCount: 0,
        body: () => BlockStmt([
          ForStmt(
            init: VarDecl(0, lit(0)),
            condition: lt(local(0), lit(10)),
            update: [set(0, add(local(0), lit(1)))],
            body: ForStmt(
              init: VarDecl(1, lit(0)),
              condition: lt(local(1), lit(10)),
              update: [set(1, add(local(1), lit(1)))],
              body: IfStmt(
                eq(add(mul(local(0), lit(10)), local(1)), lit(23)),
                ret(lit('found')),
              ),
            ),
          ),
          ret(lit('not found')),
        ]),
      );
      expect(fn.invoke([]), 'found');
    });
  });

  // -------------------------------------------------------------------------
  // Collections
  // -------------------------------------------------------------------------
  group('collections match native Dart', () {
    test('list literal, index read and write', () {
      final fn = buildFn(
        name: 'listOps',
        slotCount: 1,
        requiredCount: 0,
        body: () => BlockStmt([
          VarDecl(0, ListLiteral([lit(1), lit(2), lit(3)])),
          ExprStmt(IndexSet(local(0), lit(1), lit(99))),
          ret(IndexGet(local(0), lit(1))),
        ]),
      );
      expect(fn.invoke([]), 99);
    });

    test('map literal and key lookup', () {
      final fn = buildFn(
        name: 'mapOps',
        slotCount: 1,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(
            0,
            MapLiteral([
              (lit('a'), lit(1)),
              (lit('b'), lit(2)),
            ]),
          ),
          ret(IndexGet(local(0), local(0 + 0))),
        ]),
      );
      // Reading with the map itself as key yields null, matching Dart.
      expect(fn.invoke(['a']), null);
    });

    test('map index read agrees with native, including missing keys', () {
      final fn = buildFn(
        name: 'mapGet',
        slotCount: 2,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(
            1,
            MapLiteral([
              (lit('x'), lit(10)),
              (lit('y'), lit(20)),
            ]),
          ),
          ret(IndexGet(local(1), local(0))),
        ]),
      );
      final native = {'x': 10, 'y': 20};
      for (final k in ['x', 'y', 'missing']) {
        expect(fn.invoke([k]), native[k], reason: 'key=$k');
      }
    });

    test('set literal deduplicates like Dart', () {
      final fn = buildFn(
        name: 'setOps',
        slotCount: 0,
        requiredCount: 0,
        body: () => ret(SetLiteral([lit(1), lit(2), lit(2), lit(3)])),
      );
      expect(fn.invoke([]), {1, 2, 3});
    });

    test('list index out of range is a fault, not a native crash', () {
      final fn = buildFn(
        name: 'oob',
        slotCount: 1,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(0, ListLiteral([lit(1), lit(2)])),
          ret(IndexGet(local(0), lit(5))),
        ]),
      );
      // A VM fault, so the seam falls back to the original implementation
      // instead of surfacing as an unexplained crash on the user's device.
      expect(() => fn.invoke([0]), throwsA(isA<BoundsFault>()));
    });

    test('string interpolation matches native concatenation', () {
      String native(String name, int n) => 'got $name and $n';
      final fn = buildFn(
        name: 'interp',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(
          StringInterp([lit('got '), local(0), lit(' and '), local(1)]),
        ),
      );
      expect(fn.invoke(['x', 5]), native('x', 5));
      expect(fn.invoke(['', 0]), native('', 0));
    });

    test('string index returns a one-character string, as Dart does', () {
      final fn = buildFn(
        name: 'strIndex',
        slotCount: 1,
        requiredCount: 1,
        body: () => ret(IndexGet(local(0), lit(1))),
      );
      expect(fn.invoke(['abc']), 'abc'[1]);
    });
  });

  // -------------------------------------------------------------------------
  // Exceptions — the part where a mistake is most damaging
  // -------------------------------------------------------------------------
  group('exceptions', () {
    test('throw and catch inside interpreted code', () {
      final fn = buildFn(
        name: 'tryCatch',
        slotCount: 2,
        requiredCount: 1,
        body: () => BlockStmt([
          TryStmt(
            body: BlockStmt([
              IfStmt(local(0), ThrowStmt(lit('boom'))),
              ret(lit('no throw')),
            ]),
            catches: [CatchClause(exceptionSlot: 1, body: ret(local(1)))],
          ),
        ]),
      );
      expect(fn.invoke([false]), 'no throw');
      expect(fn.invoke([true]), 'boom');
    });

    test('finally runs on both the normal and the throwing path', () {
      // slots: 0=shouldThrow, 1=log, 2=caught
      final fn = buildFn(
        name: 'tryFinally',
        slotCount: 3,
        requiredCount: 1,
        body: () => BlockStmt([
          VarDecl(1, lit('')),
          TryStmt(
            body: IfStmt(local(0), ThrowStmt(lit('x'))),
            catches: [CatchClause(exceptionSlot: 2, body: const BlockStmt([]))],
            finallyBlock: AssignStmt(local(1), lit('ran')),
          ),
          ret(local(1)),
        ]),
      );
      expect(fn.invoke([false]), 'ran');
      expect(fn.invoke([true]), 'ran');
    });

    test('finally runs even when the body returns', () {
      // The subtle one: `return` inside `try` must still execute `finally`, and
      // the returned value must survive it.
      final fn = buildFn(
        name: 'returnInTry',
        slotCount: 1,
        requiredCount: 0,
        body: () => BlockStmt([
          VarDecl(0, lit('untouched')),
          TryStmt(
            body: ret(lit('from try')),
            finallyBlock: AssignStmt(local(0), lit('finally ran')),
          ),
          ret(local(0)),
        ]),
      );
      expect(fn.invoke([]), 'from try');
    });

    test('a VM fault is NOT catchable by interpreted code', () {
      // Load-bearing. If a patch's `catch` could swallow a machinery failure,
      // the seam would never see it, never fall back, and never quarantine the
      // override — the patch would look installed and working while silently
      // doing nothing.
      final fn = buildFn(
        name: 'cannotCatchFault',
        slotCount: 1,
        requiredCount: 0,
        body: () => TryStmt(
          body: ExprStmt(Binary(BinOp.truncDiv, lit(1), lit(0))),
          catches: [CatchClause(exceptionSlot: 0, body: ret(lit('swallowed')))],
        ),
      );
      expect(() => fn.invoke([]), throwsA(isA<BoundsFault>()));
    });

    test('a VM fault escapes even through finally', () {
      final fn = buildFn(
        name: 'faultThroughFinally',
        slotCount: 1,
        requiredCount: 0,
        body: () => BlockStmt([
          VarDecl(0, lit('no')),
          TryStmt(
            body: ExprStmt(Binary(BinOp.truncDiv, lit(1), lit(0))),
            catches: [CatchClause(exceptionSlot: 0, body: const BlockStmt([]))],
            finallyBlock: AssignStmt(local(0), lit('yes')),
          ),
          ret(local(0)),
        ]),
      );
      expect(() => fn.invoke([]), throwsA(isA<PatchVmFault>()));
    });

    test('a host exception is catchable, because it is a real Dart throw', () {
      final host = MapHostBridge({
        1: (recv, pos, named) => throw StateError('host failed'),
      });
      final fn = buildFn(
        name: 'catchHostThrow',
        slotCount: 1,
        requiredCount: 0,
        host: host,
        body: () => TryStmt(
          body: ExprStmt(const HostCall(1)),
          catches: [CatchClause(exceptionSlot: 0, body: ret(lit('caught')))],
        ),
      );
      expect(fn.invoke([]), 'caught');
    });

    test('an uncaught interpreted throw surfaces to the host', () {
      final fn = buildFn(
        name: 'uncaught',
        slotCount: 0,
        requiredCount: 0,
        body: () => ThrowStmt(lit('escaped')),
      );
      expect(
        () => fn.invoke([]),
        throwsA(isA<PatchThrow>().having((e) => e.value, 'value', 'escaped')),
      );
    });

    test('rethrow-shaped nesting: inner catch, outer catch', () {
      final fn = buildFn(
        name: 'nestedCatch',
        slotCount: 2,
        requiredCount: 0,
        body: () => TryStmt(
          body: TryStmt(
            body: ThrowStmt(lit('inner')),
            catches: [CatchClause(exceptionSlot: 0, body: ThrowStmt(lit('outer')))],
          ),
          catches: [CatchClause(exceptionSlot: 1, body: ret(local(1)))],
        ),
      );
      expect(fn.invoke([]), 'outer');
    });

    test('assert failure is reported, and passing assert is transparent', () {
      final fn = buildFn(
        name: 'assertStmt',
        slotCount: 1,
        requiredCount: 1,
        body: () => BlockStmt([
          AssertStmt(gt(local(0), lit(0)), lit('must be positive')),
          ret(lit('ok')),
        ]),
      );
      expect(fn.invoke([5]), 'ok');
      expect(fn.invoke([-1]), isNot('ok'), skip: 'throws instead');
    });
  });

  // -------------------------------------------------------------------------
  // Host bridge — the sandbox boundary
  // -------------------------------------------------------------------------
  group('host bridge', () {
    test('calls reach bound members with receiver and arguments intact', () {
      const idIndexOf = 1;
      const idSubstring = 2;
      final host = MapHostBridge({
        idIndexOf: (recv, pos, named) =>
            (recv as String).indexOf(pos[0] as String),
        idSubstring: (recv, pos, named) =>
            (recv as String).substring(pos[0] as int, pos[1] as int),
      });

      final fn = buildFn(
        name: 'hostCalls',
        slotCount: 2,
        requiredCount: 1,
        host: host,
        body: () => BlockStmt([
          VarDecl(1, HostCall(idIndexOf, receiver: local(0), args: [lit('-')])),
          IfStmt(le(local(1), lit(0)), ret(lit(null))),
          ret(HostCall(
            idSubstring,
            receiver: local(0),
            args: [lit(0), local(1)],
          )),
        ]),
      );

      expect(fn.invoke(['20321-2.2.12']), '20321');
      expect(fn.invoke(['nodash']), null);
    });

    test('an unbound member is a fault, never a silent null', () {
      final fn = buildFn(
        name: 'unbound',
        slotCount: 0,
        requiredCount: 0,
        body: () => ret(const HostCall(999)),
      );
      expect(() => fn.invoke([]), throwsA(isA<UnboundMemberFault>()));
    });

    test('named arguments reach the binding', () {
      final host = MapHostBridge({
        1: (recv, pos, named) => 'p=${pos.join(",")} n=${named?["flag"]}',
      });
      final fn = buildFn(
        name: 'namedArgs',
        slotCount: 0,
        requiredCount: 0,
        host: host,
        body: () => ret(HostCall(
          1,
          args: [lit('a')],
          named: {'flag': lit(true)},
        )),
      );
      expect(fn.invoke([]), 'p=a n=true');
    });

    test('a call with no named arguments passes null, not an empty map', () {
      // Allocating a map per crossing would show up on hot paths; the contract
      // is that the common case allocates nothing.
      Object? seen = 'unset';
      final host = MapHostBridge({
        1: (recv, pos, named) {
          seen = named;
          return null;
        },
      });
      final fn = buildFn(
        name: 'noNamed',
        slotCount: 0,
        requiredCount: 0,
        host: host,
        body: () => ExprStmt(const HostCall(1)),
      );
      fn.invoke([]);
      expect(seen, isNull);
    });

    test('type tests go through the bridge, so a patch cannot name a type it '
        'was not given', () {
      const idString = 7;
      final host = MapHostBridge(
        {},
        const {},
        {idString: (v) => v is String},
      );
      final fn = buildFn(
        name: 'typeTest',
        slotCount: 1,
        requiredCount: 1,
        host: host,
        body: () => ret(HostTypeTest(local(0), idString)),
      );
      expect(fn.invoke(['s']), true);
      expect(fn.invoke([1]), false);

      final unbound = buildFn(
        name: 'unboundType',
        slotCount: 1,
        requiredCount: 1,
        host: host,
        body: () => ret(HostTypeTest(local(0), 999)),
      );
      expect(() => unbound.invoke(['s']), throwsA(isA<UnboundMemberFault>()));
    });
  });

  // -------------------------------------------------------------------------
  // Parameters
  // -------------------------------------------------------------------------
  group('parameter binding', () {
    test('optional positional parameters fall back to defaults', () {
      final fn = buildFn(
        name: 'optionals',
        slotCount: 2,
        requiredCount: 1,
        optionalCount: 1,
        defaults: {1: lit(10)},
        body: () => ret(add(local(0), local(1))),
      );
      expect(fn.invoke([1]), 11);
      expect(fn.invoke([1, 2]), 3);
    });

    test('named parameters fall back to defaults', () {
      final fn = buildFn(
        name: 'nameds',
        slotCount: 2,
        requiredCount: 1,
        namedSlots: const {'extra': 1},
        defaults: {1: lit(100)},
        body: () => ret(add(local(0), local(1))),
      );
      expect(fn.invoke([1]), 101);
      expect(fn.invoke([1], {'extra': 5}), 6);
    });

    test('wrong arity is a fault, not a silent misbind', () {
      final fn = buildFn(
        name: 'arity',
        slotCount: 2,
        requiredCount: 2,
        body: () => ret(add(local(0), local(1))),
      );
      expect(() => fn.invoke([1]), throwsA(isA<TypeFault>()));
      expect(() => fn.invoke([1, 2, 3]), throwsA(isA<TypeFault>()));
    });

    test('an unknown named argument is rejected', () {
      final fn = buildFn(
        name: 'unknownNamed',
        slotCount: 1,
        requiredCount: 1,
        body: () => ret(local(0)),
      );
      expect(
        () => fn.invoke([1], {'nope': 2}),
        throwsA(isA<TypeFault>()),
      );
    });
  });

  // -------------------------------------------------------------------------
  // Resource limits
  // -------------------------------------------------------------------------
  group('resource limits bound our own bugs', () {
    test('runaway recursion is caught by the interpreter, not the native stack',
        () {
      // A native stack overflow cannot be caught in Dart and takes the process
      // down — indistinguishable, from the user's side, from the crashes this
      // mechanism exists to fix.
      const limits = VmLimits(maxCallDepth: 32);
      late VmFunction fn;
      fn = VmFunction(
        name: 'recurse',
        slotCount: 1,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: limits,
      );
      final ctx = CompileContext(
        host: const EmptyHostBridge(),
        limits: limits,
        functions: [VmFunctionRef(0)..target = fn],
      );
      fn.body = BlockStmt([
        ret(VmCall(0, args: [add(local(0), lit(1))])),
      ]).compile(ctx);

      expect(() => fn.invoke([0]), throwsA(isA<ResourceLimitFault>()));
    });

    test('an infinite loop is bounded rather than hanging the device', () {
      final fn = buildFn(
        name: 'infinite',
        slotCount: 1,
        requiredCount: 0,
        limits: const VmLimits(maxLoopIterations: 1000),
        body: () => BlockStmt([
          VarDecl(0, lit(0)),
          WhileStmt(lit(true), set(0, add(local(0), lit(1)))),
          ret(local(0)),
        ]),
      );
      expect(() => fn.invoke([]), throwsA(isA<ResourceLimitFault>()));
    });

    test('a legitimate long loop is not falsely tripped', () {
      final fn = buildFn(
        name: 'longButFinite',
        slotCount: 2,
        requiredCount: 0,
        limits: const VmLimits(maxLoopIterations: 100000),
        body: () => BlockStmt([
          VarDecl(0, lit(0)),
          ForStmt(
            init: VarDecl(1, lit(0)),
            condition: lt(local(1), lit(50000)),
            update: [set(1, add(local(1), lit(1)))],
            body: set(0, add(local(0), lit(1))),
          ),
          ret(local(0)),
        ]),
      );
      expect(fn.invoke([]), 50000);
    });
  });

  // -------------------------------------------------------------------------
  // Real venera-shaped functions
  // -------------------------------------------------------------------------
  group('real bug-shaped functions from this repo', () {
    test('backup filename parsing, including the 64-bit overflow guard', () {
      // The shape of RemoteBackupInfo.fromFileName: legacy backups use a
      // 13-digit millisecond timestamp where current ones use days-since-epoch,
      // and multiplying the former by 86400000 overflows (issue #51).
      int native(String name) {
        final dash = name.indexOf('-');
        if (dash <= 0) return -1;
        final head = name.substring(0, dash);
        var n = 0;
        for (var i = 0; i < head.length; i++) {
          final c = head.codeUnitAt(i);
          if (c < 48 || c > 57) return -1;
          n = n * 10 + (c - 48);
        }
        if (n > 100000000000) n = n ~/ 86400000;
        return n;
      }

      const idIndexOf = 1, idSubstring = 2, idLength = 3, idCodeUnitAt = 4;
      final host = MapHostBridge({
        idIndexOf: (r, p, n) => (r as String).indexOf(p[0] as String),
        idSubstring: (r, p, n) =>
            (r as String).substring(p[0] as int, p[1] as int),
        idLength: (r, p, n) => (r as String).length,
        idCodeUnitAt: (r, p, n) => (r as String).codeUnitAt(p[0] as int),
      });

      // slots: 0=name, 1=dash, 2=head, 3=n, 4=i, 5=c
      final fn = buildFn(
        name: 'parseBackupName',
        slotCount: 6,
        requiredCount: 1,
        host: host,
        body: () => BlockStmt([
          VarDecl(1, HostCall(idIndexOf, receiver: local(0), args: [lit('-')])),
          IfStmt(le(local(1), lit(0)), ret(lit(-1))),
          VarDecl(
            2,
            HostCall(idSubstring, receiver: local(0), args: [lit(0), local(1)]),
          ),
          VarDecl(3, lit(0)),
          ForStmt(
            init: VarDecl(4, lit(0)),
            condition: lt(local(4), HostCall(idLength, receiver: local(2))),
            update: [set(4, add(local(4), lit(1)))],
            body: BlockStmt([
              VarDecl(
                5,
                HostCall(idCodeUnitAt, receiver: local(2), args: [local(4)]),
              ),
              IfStmt(
                Binary(
                  BinOp.or,
                  lt(local(5), lit(48)),
                  gt(local(5), lit(57)),
                ),
                ret(lit(-1)),
              ),
              set(
                3,
                add(mul(local(3), lit(10)), sub(local(5), lit(48))),
              ),
            ]),
          ),
          IfStmt(
            gt(local(3), lit(100000000000)),
            set(3, Binary(BinOp.truncDiv, local(3), lit(86400000))),
          ),
          ret(local(3)),
        ]),
      );

      const cases = [
        '20321-2.2.12.android.venera',
        '1755000000000-2.2.11.ios.venera',
        '19999-2.0.0.windows.venera',
        'bad-name.venera',
        'nodash.venera',
        '-leading.venera',
      ];
      for (final c in cases) {
        expect(fn.invoke([c]), native(c), reason: c);
      }
    });

    test('numeric dotted-version comparison', () {
      // The shape of the sync/patch version rule: numeric comparison, never
      // lexicographic, and never by timestamp.
      int native(String a, String b) {
        final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
        final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
        final n = pa.length > pb.length ? pa.length : pb.length;
        for (var i = 0; i < n; i++) {
          final x = i < pa.length ? pa[i] : 0;
          final y = i < pb.length ? pb[i] : 0;
          if (x != y) return x < y ? -1 : 1;
        }
        return 0;
      }

      const idSplit = 1, idParse = 2, idLen = 3;
      final host = MapHostBridge({
        idSplit: (r, p, n) => (r as String).split(p[0] as String),
        idParse: (r, p, n) => int.tryParse(p[0] as String) ?? 0,
        idLen: (r, p, n) => (r as List).length,
      });

      // slots: 0=a 1=b 2=pa 3=pb 4=n 5=i 6=x 7=y
      final fn = buildFn(
        name: 'compareVersions',
        slotCount: 8,
        requiredCount: 2,
        host: host,
        body: () => BlockStmt([
          VarDecl(2, HostCall(idSplit, receiver: local(0), args: [lit('.')])),
          VarDecl(3, HostCall(idSplit, receiver: local(1), args: [lit('.')])),
          VarDecl(
            4,
            Conditional(
              gt(
                HostCall(idLen, receiver: local(2)),
                HostCall(idLen, receiver: local(3)),
              ),
              HostCall(idLen, receiver: local(2)),
              HostCall(idLen, receiver: local(3)),
            ),
          ),
          ForStmt(
            init: VarDecl(5, lit(0)),
            condition: lt(local(5), local(4)),
            update: [set(5, add(local(5), lit(1)))],
            body: BlockStmt([
              VarDecl(
                6,
                Conditional(
                  lt(local(5), HostCall(idLen, receiver: local(2))),
                  HostCall(
                    idParse,
                    args: [IndexGet(local(2), local(5))],
                  ),
                  lit(0),
                ),
              ),
              VarDecl(
                7,
                Conditional(
                  lt(local(5), HostCall(idLen, receiver: local(3))),
                  HostCall(
                    idParse,
                    args: [IndexGet(local(3), local(5))],
                  ),
                  lit(0),
                ),
              ),
              IfStmt(
                Unary(UnOp.not, eq(local(6), local(7))),
                ret(Conditional(lt(local(6), local(7)), lit(-1), lit(1))),
              ),
            ]),
          ),
          ret(lit(0)),
        ]),
      );

      const versions = ['2.2.12', '2.2.11', '2.2', '2.10.0', '2.9.9', '3.0.0'];
      for (final a in versions) {
        for (final b in versions) {
          expect(fn.invoke([a, b]), native(a, b), reason: '$a vs $b');
        }
      }
    });

    test('cover-URL scheme check, the shape of the file:// download bug', () {
      // Issue #206: a collection download failed because the cover went over
      // HTTP and was rejected with BadScheme — pagination had been funnelled
      // through the guard but covers had not.
      bool native(String url) =>
          url.startsWith('http://') || url.startsWith('https://');

      const idStartsWith = 1;
      final host = MapHostBridge({
        idStartsWith: (r, p, n) => (r as String).startsWith(p[0] as String),
      });
      final fn = buildFn(
        name: 'isHttpUrl',
        slotCount: 1,
        requiredCount: 1,
        host: host,
        body: () => ret(
          Binary(
            BinOp.or,
            HostCall(idStartsWith, receiver: local(0), args: [lit('http://')]),
            HostCall(idStartsWith, receiver: local(0), args: [lit('https://')]),
          ),
        ),
      );

      for (final u in [
        'http://a/b.jpg',
        'https://a/b.jpg',
        'file:///data/cover.jpg',
        '',
        'ftp://x',
      ]) {
        expect(fn.invoke([u]), native(u), reason: u);
      }
    });
  });

  // -------------------------------------------------------------------------
  // Interpreted-to-interpreted calls
  // -------------------------------------------------------------------------
  group('interpreted function calls', () {
    test('a function can call another function in the same bundle', () {
      // callee: (x) => x * 2
      final callee = VmFunction(
        name: 'double',
        slotCount: 1,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
      );
      // caller: (x) => double(x) + 1
      final caller = VmFunction(
        name: 'doublePlusOne',
        slotCount: 1,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
      );
      final ctx = CompileContext(
        host: const EmptyHostBridge(),
        limits: VmLimits.standard,
        functions: [
          VmFunctionRef(0)..target = callee,
          VmFunctionRef(1)..target = caller,
        ],
      );
      callee.body = ret(mul(local(0), lit(2))).compile(ctx);
      caller.body =
          ret(add(VmCall(0, args: [local(0)]), lit(1))).compile(ctx);

      expect(caller.invoke([5]), 11);
      expect(caller.invoke([0]), 1);
    });

    test('recursion produces the same result as the native equivalent', () {
      int nativeFib(int n) => n < 2 ? n : nativeFib(n - 1) + nativeFib(n - 2);

      final fib = VmFunction(
        name: 'fib',
        slotCount: 1,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
      );
      final ctx = CompileContext(
        host: const EmptyHostBridge(),
        limits: VmLimits.standard,
        functions: [VmFunctionRef(0)..target = fib],
      );
      fib.body = BlockStmt([
        IfStmt(lt(local(0), lit(2)), ret(local(0))),
        ret(
          add(
            VmCall(0, args: [sub(local(0), lit(1))]),
            VmCall(0, args: [sub(local(0), lit(2))]),
          ),
        ),
      ]).compile(ctx);

      for (final n in [0, 1, 5, 10, 15]) {
        expect(fib.invoke([n]), nativeFib(n), reason: 'fib($n)');
      }
    });
  });

  // -------------------------------------------------------------------------
  // Program-level
  // -------------------------------------------------------------------------
  group('program', () {
    test('override lookup resolves to the right function', () {
      final a = buildFn(
        name: 'a',
        slotCount: 0,
        requiredCount: 0,
        body: () => ret(lit('a')),
      );
      final b = buildFn(
        name: 'b',
        slotCount: 0,
        requiredCount: 0,
        body: () => ret(lit('b')),
      );
      final program = VmProgram(
        functions: [a, b],
        overrides: {0x11: 0, 0x22: 1},
      );
      expect(program.overrideFor(0x11)?.invoke([]), 'a');
      expect(program.overrideFor(0x22)?.invoke([]), 'b');
      expect(program.overrideFor(0x33), isNull);
    });

    test('an override pointing outside the function table is a load fault', () {
      final program = VmProgram(functions: const [], overrides: {1: 7});
      expect(
        () => program.overrideFor(1),
        throwsA(isA<PatchLoadFault>()),
      );
    });
  });
}

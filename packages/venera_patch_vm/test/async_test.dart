// Async execution: awaiting host futures from interpreted code.
//
// Most of what this app does that is worth patching is asynchronous —
// downloads, storage, WebDAV, imports. A patch that cannot await could only fix
// pure computation, which would leave most of the real bug surface untouchable.
//
// The design under test: the compiled async body is a real Dart `async` closure
// chain, so `await` in a patch is the host's own `await`. There is no scheduler
// of ours, which removes what would otherwise be the single most likely place in
// this interpreter to be subtly and asynchronously wrong.
//
// The other half is the cost control: `hasAwait` is structural, so an await-free
// statement inside an async body still compiles to the synchronous closure. The
// tests below pin both the behaviour and that split.

import 'dart:async';

import 'package:test/test.dart';
import 'package:venera_patch_vm/venera_patch_vm.dart';

// ---------------------------------------------------------------------------
// Host surface: a few members that return futures, plus a synchronous one so
// tests can prove the sync path still runs inside an async body.
// ---------------------------------------------------------------------------

const int idAsyncDouble = 1; // Future<int> (int) — delayed
const int idAsyncFail = 2; // Future<Never> — throws after a turn
const int idSyncTriple = 3; // int (int) — no future at all
const int idAsyncEcho = 4; // Future<String> (String)
const int idSyncLen = 5; // int (String)
const int idAsyncList = 6; // Future<List<int>> ()
const int idVmFault = 7; // throws a PatchVmFault after a turn

HostBridge _host() => MapHostBridge(
      {
        idAsyncDouble: (recv, pos, named) async {
          await Future<void>.delayed(Duration.zero);
          return (pos[0] as int) * 2;
        },
        idAsyncFail: (recv, pos, named) async {
          await Future<void>.delayed(Duration.zero);
          throw StateError('host failed asynchronously');
        },
        idSyncTriple: (recv, pos, named) => (pos[0] as int) * 3,
        idAsyncEcho: (recv, pos, named) async {
          await Future<void>.delayed(Duration.zero);
          return 'echo:${pos[0]}';
        },
        idSyncLen: (recv, pos, named) => (pos[0] as String).length,
        idAsyncList: (recv, pos, named) async {
          await Future<void>.delayed(Duration.zero);
          return <int>[1, 2, 3];
        },
        idVmFault: (recv, pos, named) async {
          await Future<void>.delayed(Duration.zero);
          throw const ResourceLimitFault('simulated machinery failure');
        },
      },
      const {},
      {0x1000: (v) => v is StateError},
    );

/// Builds a function and compiles its body on the path [isAsync] selects.
VmFunction _fn({
  required Stmt body,
  int slotCount = 4,
  int requiredCount = 1,
  bool isAsync = true,
  HostBridge? host,
  VmLimits limits = VmLimits.standard,
}) {
  final fn = VmFunction(
    name: 'subject',
    slotCount: slotCount,
    requiredCount: requiredCount,
    optionalCount: 0,
    namedSlots: const {},
    limits: limits,
    isAsync: isAsync,
  );
  final ctx = CompileContext(
    host: host ?? _host(),
    limits: limits,
    functions: [VmFunctionRef(0)..target = fn],
  );
  if (isAsync) {
    fn.asyncBody = body.compileAsyncOrWrap(ctx);
  } else {
    fn.body = body.compile(ctx);
  }
  return fn;
}

Expr _lit(Object? v) => Literal(v);
Assignable _local(int slot) => LocalGet(slot);
Expr _await(Expr e) => AwaitExpr(e);
Stmt _ret([Expr? v]) => ReturnStmt(v);

void main() {
  group('awaiting a host future', () {
    test('return await hostCall(...)', () async {
      final fn = _fn(
        body: _ret(_await(HostCall(idAsyncDouble, args: [_local(0)]))),
      );
      // `invoke` on an async function returns a Future, exactly as calling a
      // Dart `async` function does, so one await yields the value.
      expect(await fn.invoke([21]), 42);
    });

    test('var x = await ...; then use x', () async {
      // slots: 0=arg, 1=doubled
      final fn = _fn(
        body: BlockStmt([
          VarDecl(1, _await(HostCall(idAsyncDouble, args: [_local(0)]))),
          _ret(Binary(BinOp.add, _local(1), _lit(1))),
        ]),
      );
      expect((await fn.invoke([10])) as int, 21);
    });

    test('assignment from an awaited value', () async {
      final fn = _fn(
        body: BlockStmt([
          VarDecl(1, _lit(0)),
          AssignStmt(
            _local(1),
            _await(HostCall(idAsyncDouble, args: [_local(0)])),
          ),
          _ret(_local(1)),
        ]),
      );
      expect((await fn.invoke([7])) as int, 14);
    });

    test('bare await as a statement, for its effect', () async {
      final fn = _fn(
        body: BlockStmt([
          ExprStmt(_await(HostCall(idAsyncDouble, args: [_local(0)]))),
          _ret(_lit('done')),
        ]),
      );
      expect((await fn.invoke([1])) as String, 'done');
    });

    test('awaiting a non-future yields the value, as native await does', () async {
      final fn = _fn(
        body: _ret(_await(HostCall(idSyncTriple, args: [_local(0)]))),
      );
      expect((await fn.invoke([5])) as int, 15);
    });

    test('two sequential awaits thread values through', () async {
      // slots: 0=arg, 1=first, 2=second
      final fn = _fn(
        slotCount: 3,
        body: BlockStmt([
          VarDecl(1, _await(HostCall(idAsyncDouble, args: [_local(0)]))),
          VarDecl(2, _await(HostCall(idAsyncDouble, args: [_local(1)]))),
          _ret(_local(2)),
        ]),
      );
      expect((await fn.invoke([3])) as int, 12);
    });

    test('an awaited list is usable by the collection surface', () async {
      final fn = _fn(
        requiredCount: 0,
        body: BlockStmt([
          VarDecl(1, _await(const HostCall(idAsyncList))),
          _ret(IndexGet(_local(1), _lit(1))),
        ]),
      );
      expect((await fn.invoke([])) as int, 2);
    });
  });

  group('async control flow', () {
    test('await inside an if branch', () async {
      final fn = _fn(
        body: BlockStmt([
          IfStmt(
            Binary(BinOp.gt, _local(0), _lit(0)),
            _ret(_await(HostCall(idAsyncDouble, args: [_local(0)]))),
            _ret(_lit(-1)),
          ),
        ]),
      );
      expect((await fn.invoke([4])) as int, 8);
      expect((await fn.invoke([-4])) as int, -1);
    });

    test('await inside a for-in body, accumulating', () async {
      // slots: 0=list, 1=sum, 2=item, 3=doubled
      final fn = _fn(
        slotCount: 4,
        body: BlockStmt([
          VarDecl(1, _lit(0)),
          ForInStmt(
            2,
            _local(0),
            BlockStmt([
              VarDecl(3, _await(HostCall(idAsyncDouble, args: [_local(2)]))),
              AssignStmt(_local(1), Binary(BinOp.add, _local(1), _local(3))),
            ]),
          ),
          _ret(_local(1)),
        ]),
      );
      expect((await fn.invoke([<int>[1, 2, 3]])) as int, 12);
    });

    test('await inside a while body', () async {
      // slots: 0=limit, 1=i, 2=sum, 3=tmp
      final fn = _fn(
        slotCount: 4,
        body: BlockStmt([
          VarDecl(1, _lit(0)),
          VarDecl(2, _lit(0)),
          WhileStmt(
            Binary(BinOp.lt, _local(1), _local(0)),
            BlockStmt([
              VarDecl(3, _await(HostCall(idAsyncDouble, args: [_local(1)]))),
              AssignStmt(_local(2), Binary(BinOp.add, _local(2), _local(3))),
              AssignStmt(_local(1), Binary(BinOp.add, _local(1), _lit(1))),
            ]),
          ),
          _ret(_local(2)),
        ]),
      );
      // 2*(0+1+2+3) = 12
      expect((await fn.invoke([4])) as int, 12);
    });

    test('await inside a C-style for, with break', () async {
      // slots: 0=n, 1=i, 2=acc, 3=tmp
      final fn = _fn(
        slotCount: 4,
        body: BlockStmt([
          VarDecl(2, _lit(0)),
          ForStmt(
            init: VarDecl(1, _lit(0)),
            condition: Binary(BinOp.lt, _local(1), _local(0)),
            update: [
              AssignStmt(_local(1), Binary(BinOp.add, _local(1), _lit(1))),
            ],
            body: BlockStmt([
              IfStmt(
                Binary(BinOp.gt, _local(1), _lit(2)),
                const BreakStmt(),
              ),
              VarDecl(3, _await(HostCall(idAsyncDouble, args: [_local(1)]))),
              AssignStmt(_local(2), Binary(BinOp.add, _local(2), _local(3))),
            ]),
          ),
          _ret(_local(2)),
        ]),
      );
      // i = 0,1,2 then break: 2*(0+1+2) = 6
      expect((await fn.invoke([100])) as int, 6);
    });

    test('await inside a do-while', () async {
      final fn = _fn(
        slotCount: 3,
        body: BlockStmt([
          VarDecl(1, _lit(0)),
          DoWhileStmt(
            BlockStmt([
              VarDecl(2, _await(HostCall(idAsyncDouble, args: [_local(1)]))),
              AssignStmt(_local(1), Binary(BinOp.add, _local(2), _lit(1))),
            ]),
            Binary(BinOp.lt, _local(1), _local(0)),
          ),
          _ret(_local(1)),
        ]),
      );
      // 0 -> 1 -> 3 -> 7; stops once >= 5
      expect((await fn.invoke([5])) as int, 7);
    });

    test('early return from inside an awaiting loop unwinds fully', () async {
      final fn = _fn(
        slotCount: 3,
        body: BlockStmt([
          ForInStmt(
            1,
            _local(0),
            BlockStmt([
              VarDecl(2, _await(HostCall(idAsyncDouble, args: [_local(1)]))),
              IfStmt(
                Binary(BinOp.gt, _local(2), _lit(4)),
                _ret(_local(2)),
              ),
            ]),
          ),
          _ret(_lit('not found')),
        ]),
      );
      expect((await fn.invoke([<int>[1, 2, 3, 4]])) as int, 6);
    });
  });

  group('async exceptions', () {
    test('a host exception from an awaited call is catchable', () async {
      final fn = _fn(
        requiredCount: 0,
        body: TryStmt(
          body: _ret(_await(const HostCall(idAsyncFail))),
          catches: [
            CatchClause(exceptionSlot: 1, body: _ret(_lit('caught'))),
          ],
        ),
      );
      expect((await fn.invoke([])) as String, 'caught');
    });

    test('the caught value is the host exception itself', () async {
      final fn = _fn(
        requiredCount: 0,
        body: TryStmt(
          body: ExprStmt(_await(const HostCall(idAsyncFail))),
          catches: [CatchClause(exceptionSlot: 1, body: _ret(_local(1)))],
        ),
      );
      final caught = (await fn.invoke([]));
      expect(caught, isA<StateError>());
    });

    test('`on T catch` filters an async host exception by type', () async {
      final fn = _fn(
        requiredCount: 0,
        body: TryStmt(
          body: ExprStmt(_await(const HostCall(idAsyncFail))),
          catches: [
            CatchClause(
              typeId: 0x1000, // StateError
              exceptionSlot: 1,
              body: _ret(_lit('matched')),
            ),
          ],
        ),
      );
      expect((await fn.invoke([])) as String, 'matched');
    });

    test('finally runs after an awaited body, on both paths', () async {
      // slots: 0=shouldFail, 1=log, 2=err
      Future<Object?> run(bool shouldFail) async {
        final fn = _fn(
          slotCount: 3,
          body: BlockStmt([
            VarDecl(1, _lit('')),
            TryStmt(
              body: IfStmt(
                _local(0),
                ExprStmt(_await(const HostCall(idAsyncFail))),
                ExprStmt(_await(HostCall(idAsyncDouble, args: [_lit(1)]))),
              ),
              catches: [
                CatchClause(exceptionSlot: 2, body: const BlockStmt([])),
              ],
              finallyBlock: AssignStmt(_local(1), _lit('ran')),
            ),
            _ret(_local(1)),
          ]),
        );
        return await fn.invoke([shouldFail]);
      }

      expect(await run(false), 'ran');
      expect(await run(true), 'ran');
    });

    test('an awaited finally is honoured', () async {
      final fn = _fn(
        requiredCount: 0,
        slotCount: 2,
        body: BlockStmt([
          VarDecl(1, _lit('')),
          TryStmt(
            body: const BlockStmt([]),
            finallyBlock: AssignStmt(
              _local(1),
              _await(HostCall(idAsyncEcho, args: [_lit('fin')])),
            ),
          ),
          _ret(_local(1)),
        ]),
      );
      expect((await fn.invoke([])) as String, 'echo:fin');
    });

    test('a machinery fault is NOT catchable across an await', () async {
      // The load-bearing rule, now on the async path: if an interpreted catch
      // could swallow a PatchVmFault, the seam would never learn the override is
      // broken — it would look installed and working while producing wrong
      // results, asynchronously, which is the hardest version to trace.
      final fn = _fn(
        requiredCount: 0,
        body: TryStmt(
          body: ExprStmt(_await(const HostCall(idVmFault))),
          catches: [
            CatchClause(exceptionSlot: 1, body: _ret(_lit('swallowed'))),
          ],
        ),
      );
      await expectLater(
        fn.invoke([]) as Future,
        throwsA(isA<ResourceLimitFault>()),
      );
    });

    test('an uncaught async host exception propagates to the caller', () async {
      final fn = _fn(
        requiredCount: 0,
        body: _ret(_await(const HostCall(idAsyncFail))),
      );
      await expectLater(fn.invoke([]) as Future, throwsA(isA<StateError>()));
    });

    test('an interpreted throw after an await still surfaces', () async {
      final fn = _fn(
        requiredCount: 0,
        slotCount: 2,
        body: BlockStmt([
          VarDecl(1, _await(HostCall(idAsyncDouble, args: [_lit(1)]))),
          ThrowStmt(_lit('after await')),
        ]),
      );
      await expectLater(
        fn.invoke([]) as Future,
        throwsA(
          isA<PatchThrow>().having((e) => e.value, 'value', 'after await'),
        ),
      );
    });
  });

  group('the sync path is preserved', () {
    test('an await-free statement in an async body stays synchronous', () {
      // hasAwait is structural, so this must be false even though the enclosing
      // function is async. If it were true, every arithmetic statement in every
      // async patch would allocate a Future.
      final stmt = BlockStmt([
        VarDecl(1, Binary(BinOp.add, _local(0), _lit(1))),
        _ret(_local(1)),
      ]);
      expect(stmt.hasAwait, isFalse);
    });

    test('hasAwait is true only where an await actually lives', () {
      expect(_ret(_lit(1)).hasAwait, isFalse);
      expect(_ret(_await(_lit(1))).hasAwait, isTrue);
      expect(
        BlockStmt([_ret(_lit(1))]).hasAwait,
        isFalse,
      );
      expect(
        BlockStmt([ExprStmt(_await(_lit(1)))]).hasAwait,
        isTrue,
      );
      // Nested: the flag has to climb out of the loop.
      expect(
        WhileStmt(_lit(true), ExprStmt(_await(_lit(1)))).hasAwait,
        isTrue,
      );
    });

    test('a sync function mixing awaited-free work still runs synchronously',
        () {
      final fn = _fn(
        isAsync: false,
        body: _ret(HostCall(idSyncTriple, args: [_local(0)])),
      );
      // Not a Future: a synchronous function must not become async merely
      // because the async machinery exists.
      expect(fn.invoke([4]), 12);
    });

    test('an await in a function not marked async is rejected at load', () {
      // Compiling the sync path over an AwaitExpr throws, so a payload that
      // claims to be synchronous while containing an await fails at load rather
      // than leaking a Future where a value was expected.
      expect(
        () => _fn(
          isAsync: false,
          body: _ret(_await(HostCall(idAsyncDouble, args: [_local(0)]))),
        ),
        throwsA(isA<PatchLoadFault>()),
      );
    });
  });

  group('interpreted async functions calling each other', () {
    test('an async function awaits another async function', () async {
      // inner(x) async => await asyncDouble(x)
      final inner = VmFunction(
        name: 'inner',
        slotCount: 1,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
        isAsync: true,
      );
      // outer(x) async => (await inner(x)) + 1
      final outer = VmFunction(
        name: 'outer',
        slotCount: 2,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
        isAsync: true,
      );
      final ctx = CompileContext(
        host: _host(),
        limits: VmLimits.standard,
        functions: [
          VmFunctionRef(0)..target = inner,
          VmFunctionRef(1)..target = outer,
        ],
      );
      inner.asyncBody = _ret(
        _await(HostCall(idAsyncDouble, args: [_local(0)])),
      ).compileAsyncOrWrap(ctx);
      outer.asyncBody = BlockStmt([
        VarDecl(1, _await(VmCall(0, args: [_local(0)]))),
        _ret(Binary(BinOp.add, _local(1), _lit(1))),
      ]).compileAsyncOrWrap(ctx);

      expect((await outer.invoke([20])) as int, 41);
    });

    test('a sync function can be called from an async one', () async {
      final syncFn = VmFunction(
        name: 'syncTriple',
        slotCount: 1,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
      );
      final asyncFn = VmFunction(
        name: 'asyncCaller',
        slotCount: 2,
        requiredCount: 1,
        optionalCount: 0,
        namedSlots: const {},
        limits: VmLimits.standard,
        isAsync: true,
      );
      final ctx = CompileContext(
        host: _host(),
        limits: VmLimits.standard,
        functions: [
          VmFunctionRef(0)..target = syncFn,
          VmFunctionRef(1)..target = asyncFn,
        ],
      );
      syncFn.body = _ret(Binary(BinOp.mul, _local(0), _lit(3))).compile(ctx);
      asyncFn.asyncBody = BlockStmt([
        // No await needed: a sync callee returns a value directly.
        VarDecl(1, VmCall(0, args: [_local(0)])),
        _ret(_await(HostCall(idAsyncDouble, args: [_local(1)]))),
      ]).compileAsyncOrWrap(ctx);

      expect((await asyncFn.invoke([2])) as int, 12);
    });
  });

  group('limits still apply across suspension', () {
    test('an awaiting loop is still bounded', () async {
      final fn = _fn(
        requiredCount: 0,
        slotCount: 2,
        limits: const VmLimits(maxLoopIterations: 5),
        body: BlockStmt([
          VarDecl(1, _lit(0)),
          WhileStmt(
            _lit(true),
            BlockStmt([
              AssignStmt(
                _local(1),
                _await(HostCall(idAsyncDouble, args: [_lit(1)])),
              ),
            ]),
          ),
          _ret(_local(1)),
        ]),
      );
      await expectLater(
        fn.invoke([]) as Future,
        throwsA(isA<ResourceLimitFault>()),
      );
    });
  });
}

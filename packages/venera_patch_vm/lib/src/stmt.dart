import 'errors.dart';
import 'expr.dart';
import 'frame.dart';

/// A compiled statement: takes a frame, returns a [Flow] signal.
typedef StmtFn = int Function(Frame);

/// A statement in the IR. Compiles once, at load time — see [Expr].
abstract class Stmt {
  const Stmt();

  StmtFn compile(CompileContext ctx);
}

// ---------------------------------------------------------------------------
// Sequencing
// ---------------------------------------------------------------------------

/// A statement sequence.
class BlockStmt extends Stmt {
  const BlockStmt(this.body);

  final List<Stmt> body;

  @override
  StmtFn compile(CompileContext ctx) {
    final fns = <StmtFn>[for (final s in body) s.compile(ctx)];
    // Specialise short blocks: real code is overwhelmingly two or three
    // statements, where the loop's index arithmetic and bounds check are pure
    // overhead.
    switch (fns.length) {
      case 0:
        return (_) => Flow.next;
      case 1:
        return fns[0];
      case 2:
        final a = fns[0], b = fns[1];
        return (f) {
          final s = a(f);
          if (s != Flow.next) return s;
          return b(f);
        };
      case 3:
        final a = fns[0], b = fns[1], c = fns[2];
        return (f) {
          var s = a(f);
          if (s != Flow.next) return s;
          s = b(f);
          if (s != Flow.next) return s;
          return c(f);
        };
      default:
        final n = fns.length;
        return (f) {
          for (var i = 0; i < n; i++) {
            final s = fns[i](f);
            if (s != Flow.next) return s;
          }
          return Flow.next;
        };
    }
  }
}

/// Evaluates an expression for its effect and discards the value.
class ExprStmt extends Stmt {
  const ExprStmt(this.expr);

  final Expr expr;

  @override
  StmtFn compile(CompileContext ctx) {
    final e = expr.compile(ctx);
    return (f) {
      e(f);
      return Flow.next;
    };
  }
}

/// Declares a local, optionally with an initialiser.
///
/// Slots are pre-allocated for the whole frame, so this only stores the initial
/// value. Shadowing is handled by the compiler assigning distinct slots.
class VarDecl extends Stmt {
  const VarDecl(this.slot, [this.init]);

  final int slot;
  final Expr? init;

  @override
  StmtFn compile(CompileContext ctx) {
    final s = slot;
    final i = init?.compile(ctx);
    if (i == null) {
      return (f) {
        f.slots[s] = null;
        return Flow.next;
      };
    }
    return (f) {
      f.slots[s] = i(f);
      return Flow.next;
    };
  }
}

/// Assignment to any [Assignable] target: local, index, or host field.
class AssignStmt extends Stmt {
  const AssignStmt(this.target, this.value);

  final Assignable target;
  final Expr value;

  @override
  StmtFn compile(CompileContext ctx) {
    final store = target.compileStore(ctx);
    final v = value.compile(ctx);
    return (f) {
      store(f, v(f));
      return Flow.next;
    };
  }
}

// ---------------------------------------------------------------------------
// Branching
// ---------------------------------------------------------------------------

class IfStmt extends Stmt {
  const IfStmt(this.condition, this.then, [this.otherwise]);

  final Expr condition;
  final Stmt then;
  final Stmt? otherwise;

  @override
  StmtFn compile(CompileContext ctx) {
    final c = condition.compile(ctx);
    final t = then.compile(ctx);
    final e = otherwise?.compile(ctx);
    if (e == null) {
      return (f) => asBool(c(f)) ? t(f) : Flow.next;
    }
    return (f) => asBool(c(f)) ? t(f) : e(f);
  }
}

/// A `switch` statement over `==`-comparable values.
///
/// Cases are matched in order rather than through a hash map: a switch in real
/// code has a handful of cases, and the map's hashing plus its inability to
/// handle non-hashable selectors would cost more than it saves.
class SwitchStmt extends Stmt {
  const SwitchStmt(this.selector, this.cases, [this.defaultCase]);

  final Expr selector;
  final List<SwitchCase> cases;
  final Stmt? defaultCase;

  @override
  StmtFn compile(CompileContext ctx) {
    final sel = selector.compile(ctx);
    final compiled = <List<ExprFn>, StmtFn>{};
    for (final c in cases) {
      compiled[[for (final v in c.values) v.compile(ctx)]] = c.body.compile(ctx);
    }
    final entries = compiled.entries.toList(growable: false);
    final n = entries.length;
    final def = defaultCase?.compile(ctx);
    return (f) {
      final value = sel(f);
      for (var i = 0; i < n; i++) {
        for (final test in entries[i].key) {
          if (test(f) == value) {
            final s = entries[i].value(f);
            // `break` belongs to the switch and stops here; `continue` and
            // `return` belong to an enclosing construct and keep unwinding.
            return s == Flow.brk ? Flow.next : s;
          }
        }
      }
      if (def != null) {
        final s = def(f);
        return s == Flow.brk ? Flow.next : s;
      }
      return Flow.next;
    };
  }
}

class SwitchCase {
  const SwitchCase(this.values, this.body);

  /// Multiple values share one body, for fall-through groups like
  /// `case 'a': case 'b':`.
  final List<Expr> values;
  final Stmt body;
}

// ---------------------------------------------------------------------------
// Loops
//
// Every loop carries an iteration ceiling. A patch runs on user devices where
// an accidental infinite loop is an unrecoverable freeze — no debugger, no way
// to interrupt. Failing so the seam can fall back beats hanging.
// ---------------------------------------------------------------------------

class WhileStmt extends Stmt {
  const WhileStmt(this.condition, this.body);

  final Expr condition;
  final Stmt body;

  @override
  StmtFn compile(CompileContext ctx) {
    final c = condition.compile(ctx);
    final b = body.compile(ctx);
    final max = ctx.limits.maxLoopIterations;
    return (f) {
      var iterations = 0;
      while (asBool(c(f))) {
        if (++iterations > max) {
          throw ResourceLimitFault('while loop exceeded $max iterations');
        }
        final s = b(f);
        if (s == Flow.brk) break;
        if (s == Flow.ret) return s;
      }
      return Flow.next;
    };
  }
}

class DoWhileStmt extends Stmt {
  const DoWhileStmt(this.body, this.condition);

  final Stmt body;
  final Expr condition;

  @override
  StmtFn compile(CompileContext ctx) {
    final b = body.compile(ctx);
    final c = condition.compile(ctx);
    final max = ctx.limits.maxLoopIterations;
    return (f) {
      var iterations = 0;
      do {
        if (++iterations > max) {
          throw ResourceLimitFault('do-while loop exceeded $max iterations');
        }
        final s = b(f);
        if (s == Flow.brk) break;
        if (s == Flow.ret) return s;
      } while (asBool(c(f)));
      return Flow.next;
    };
  }
}

/// A C-style `for`.
class ForStmt extends Stmt {
  const ForStmt({
    this.init,
    this.condition,
    this.update = const [],
    required this.body,
  });

  final Stmt? init;
  final Expr? condition;
  final List<Stmt> update;
  final Stmt body;

  @override
  StmtFn compile(CompileContext ctx) {
    final i = init?.compile(ctx);
    final c = condition?.compile(ctx);
    final u = <StmtFn>[for (final s in update) s.compile(ctx)];
    final b = body.compile(ctx);
    final max = ctx.limits.maxLoopIterations;
    final un = u.length;
    return (f) {
      if (i != null) i(f);
      var iterations = 0;
      while (c == null || asBool(c(f))) {
        if (++iterations > max) {
          throw ResourceLimitFault('for loop exceeded $max iterations');
        }
        final s = b(f);
        if (s == Flow.brk) break;
        if (s == Flow.ret) return s;
        for (var k = 0; k < un; k++) {
          u[k](f);
        }
      }
      return Flow.next;
    };
  }
}

/// `for (x in iterable)`.
class ForInStmt extends Stmt {
  const ForInStmt(this.slot, this.iterable, this.body);

  final int slot;
  final Expr iterable;
  final Stmt body;

  @override
  StmtFn compile(CompileContext ctx) {
    final s = slot;
    final it = iterable.compile(ctx);
    final b = body.compile(ctx);
    final max = ctx.limits.maxLoopIterations;
    return (f) {
      final source = it(f);
      if (source is! Iterable) {
        throw TypeFault('for-in requires an Iterable, got ${source.runtimeType}');
      }
      var iterations = 0;
      for (final item in source) {
        if (++iterations > max) {
          throw ResourceLimitFault('for-in loop exceeded $max iterations');
        }
        f.slots[s] = item;
        final flow = b(f);
        if (flow == Flow.brk) break;
        if (flow == Flow.ret) return flow;
      }
      return Flow.next;
    };
  }
}

// ---------------------------------------------------------------------------
// Jumps
// ---------------------------------------------------------------------------

class ReturnStmt extends Stmt {
  const ReturnStmt([this.value]);

  final Expr? value;

  @override
  StmtFn compile(CompileContext ctx) {
    final v = value?.compile(ctx);
    if (v == null) {
      return (f) {
        f.returnValue = null;
        return Flow.ret;
      };
    }
    return (f) {
      f.returnValue = v(f);
      return Flow.ret;
    };
  }
}

class BreakStmt extends Stmt {
  const BreakStmt();

  @override
  StmtFn compile(CompileContext ctx) => (_) => Flow.brk;
}

class ContinueStmt extends Stmt {
  const ContinueStmt();

  @override
  StmtFn compile(CompileContext ctx) => (_) => Flow.cont;
}

// ---------------------------------------------------------------------------
// Exceptions
//
// A `throw` in interpreted code is a real Dart `throw`, and a compiled `try` is
// a real Dart `try`. So a host exception and an interpreted one unwind through
// the same mechanism, the happy path carries no exception bookkeeping, and the
// two kinds of failure cannot drift apart.
// ---------------------------------------------------------------------------

class ThrowStmt extends Stmt {
  const ThrowStmt(this.value);

  final Expr value;

  @override
  StmtFn compile(CompileContext ctx) {
    final v = value.compile(ctx);
    return (f) => throw PatchThrow(v(f));
  }
}

/// An exception thrown by interpreted code.
///
/// Wrapped rather than thrown bare so the seam can tell an interpreted `throw`
/// apart from a host exception that happened to pass through, and so a thrown
/// non-Object (`throw null`) stays representable.
final class PatchThrow implements Exception {
  const PatchThrow(this.value);

  final Object? value;

  @override
  String toString() => 'PatchThrow: $value';
}

/// `try` / `on` / `catch` / `finally`.
class TryStmt extends Stmt {
  const TryStmt({
    required this.body,
    this.catches = const [],
    this.finallyBlock,
  });

  final Stmt body;
  final List<CatchClause> catches;
  final Stmt? finallyBlock;

  @override
  StmtFn compile(CompileContext ctx) {
    final b = body.compile(ctx);
    final handlers = <_CompiledCatch>[
      for (final c in catches)
        _CompiledCatch(
          typeId: c.typeId,
          exceptionSlot: c.exceptionSlot,
          stackSlot: c.stackSlot,
          body: c.body.compile(ctx),
        ),
    ];
    final fin = finallyBlock?.compile(ctx);
    final host = ctx.host;
    final hn = handlers.length;

    return (f) {
      try {
        try {
          return b(f);
        } catch (e, st) {
          // A VM fault is a machinery failure, not a patch-logic error. If an
          // interpreted `catch` swallowed it, the seam would never learn the
          // override is broken: it would look installed and working while
          // silently producing wrong results. Machinery failures always escape
          // to the seam, which falls back and quarantines.
          if (e is PatchVmFault) rethrow;
          final value = e is PatchThrow ? e.value : e;
          for (var i = 0; i < hn; i++) {
            final h = handlers[i];
            if (h.typeId != null && !host.isInstanceOf(h.typeId!, value)) {
              continue;
            }
            if (h.exceptionSlot != null) f.slots[h.exceptionSlot!] = value;
            if (h.stackSlot != null) f.slots[h.stackSlot!] = st;
            return h.body(f);
          }
          rethrow;
        }
      } finally {
        // Dart's own semantics apply: a `finally` that returns or breaks
        // overrides the pending flow, and one that throws replaces the pending
        // exception. Running it inside a real `finally` gets that for free.
        if (fin != null) fin(f);
      }
    };
  }
}

class CatchClause {
  const CatchClause({
    this.typeId,
    this.exceptionSlot,
    this.stackSlot,
    required this.body,
  });

  /// Host type id for `on T catch`. Null means catch-all.
  final int? typeId;

  /// Slot for the caught exception, null when the clause names no variable.
  final int? exceptionSlot;

  /// Slot for the stack trace, null when the clause omits it.
  final int? stackSlot;

  final Stmt body;
}

final class _CompiledCatch {
  const _CompiledCatch({
    required this.typeId,
    required this.exceptionSlot,
    required this.stackSlot,
    required this.body,
  });

  final int? typeId;
  final int? exceptionSlot;
  final int? stackSlot;
  final StmtFn body;
}

/// `assert`.
///
/// Kept live in patches rather than stripped: an assertion that fires becomes a
/// VM-visible failure, which makes the seam fall back to the original
/// implementation — exactly the right outcome for a patch whose own invariant
/// broke.
class AssertStmt extends Stmt {
  const AssertStmt(this.condition, [this.message]);

  final Expr condition;
  final Expr? message;

  @override
  StmtFn compile(CompileContext ctx) {
    final c = condition.compile(ctx);
    final m = message?.compile(ctx);
    return (f) {
      if (!asBool(c(f))) {
        throw PatchThrow(m == null ? 'assertion failed' : m(f));
      }
      return Flow.next;
    };
  }
}

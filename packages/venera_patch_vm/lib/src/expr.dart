import 'errors.dart';
import 'frame.dart';
import 'host.dart';

/// A compiled expression: takes a frame, produces a value.
typedef ExprFn = Object? Function(Frame);

/// Threaded through `compile()` so nodes reach the host bridge and the function
/// table without a global.
///
/// Nodes are pure data deserialised from the payload; compilation binds them to
/// a runtime. Keeping the two separate is what lets the differential tests
/// compile one IR against a stub bridge and against the real one.
final class CompileContext {
  CompileContext({
    required this.host,
    required this.limits,
    required this.functions,
  });

  final HostBridge host;
  final VmLimits limits;

  /// Interpreted functions by index. Populated before any body compiles, so
  /// mutual recursion resolves.
  final List<VmFunctionRef> functions;
}

/// Indirection to an interpreted function.
///
/// A body that calls a function compiled later needs a handle it can capture
/// now and resolve at call time. Without it, compiling `a` before `b` would
/// leave `a`'s call site holding a null.
final class VmFunctionRef {
  VmFunctionRef(this.index);

  final int index;

  /// Assigned by the loader once the target is built. Typed loosely to avoid a
  /// cycle between this file and `function.dart`.
  Object? target;
}

/// An expression in the IR.
///
/// Each node compiles **once**, at load time, into a closure that captures its
/// children's closures. Execution is then a chain of closure calls with no
/// `switch (node.kind)` dispatch — the trick that buys most of the distance
/// between a naive tree-walker and a bytecode VM without the bytecode
/// machinery. Measured at 23.2x native AOT on a representative parse function.
abstract class Expr {
  const Expr();

  ExprFn compile(CompileContext ctx);
}

/// An expression that can also be assigned to.
abstract class Assignable extends Expr {
  const Assignable();

  /// Compiles the store side. The returned closure takes the frame and the new
  /// value.
  void Function(Frame, Object?) compileStore(CompileContext ctx);
}

// ---------------------------------------------------------------------------
// Literals and variables
// ---------------------------------------------------------------------------

/// A compile-time constant.
class Literal extends Expr {
  const Literal(this.value);

  final Object? value;

  @override
  ExprFn compile(CompileContext ctx) {
    final v = value;
    // Specialising null lets `x ?? y` and default-value slots skip a capture.
    if (v == null) return (_) => null;
    return (_) => v;
  }
}

/// Reads a local slot.
class LocalGet extends Assignable {
  const LocalGet(this.slot);

  final int slot;

  @override
  ExprFn compile(CompileContext ctx) {
    final s = slot;
    return (f) => f.slots[s];
  }

  @override
  void Function(Frame, Object?) compileStore(CompileContext ctx) {
    final s = slot;
    return (f, v) => f.slots[s] = v;
  }
}

// ---------------------------------------------------------------------------
// Operators
//
// Every operator is specialised at compile time: the runtime closure contains
// no operator switch. Numeric operators additionally specialise on int/int,
// which is the overwhelmingly common case in the parsing and predicate code
// this VM exists to patch.
// ---------------------------------------------------------------------------

/// Binary operator kinds.
enum BinOp {
  add,
  sub,
  mul,
  div,
  truncDiv,
  mod,
  lt,
  lte,
  gt,
  gte,
  eq,
  neq,
  and,
  or,
  bitAnd,
  bitOr,
  bitXor,
  shl,
  shr,
  ifNull,
}

class Binary extends Expr {
  const Binary(this.op, this.left, this.right);

  final BinOp op;
  final Expr left;
  final Expr right;

  @override
  ExprFn compile(CompileContext ctx) {
    final a = left.compile(ctx);
    final b = right.compile(ctx);
    return switch (op) {
      // Short-circuit operators must not evaluate the right side eagerly —
      // `x != null && x.foo` depends on it.
      BinOp.and => (f) => asBool(a(f)) ? asBool(b(f)) : false,
      BinOp.or => (f) => asBool(a(f)) ? true : asBool(b(f)),
      BinOp.ifNull => (f) => a(f) ?? b(f),
      BinOp.add => (f) => _add(a(f), b(f)),
      BinOp.sub => (f) => _num(a(f)) - _num(b(f)),
      BinOp.mul => (f) => _num(a(f)) * _num(b(f)),
      BinOp.div => (f) => _num(a(f)) / _num(b(f)),
      BinOp.truncDiv => (f) => _intDiv(a(f), b(f)),
      BinOp.mod => (f) => _num(a(f)) % _num(b(f)),
      BinOp.lt => (f) => _num(a(f)) < _num(b(f)),
      BinOp.lte => (f) => _num(a(f)) <= _num(b(f)),
      BinOp.gt => (f) => _num(a(f)) > _num(b(f)),
      BinOp.gte => (f) => _num(a(f)) >= _num(b(f)),
      BinOp.eq => (f) => a(f) == b(f),
      BinOp.neq => (f) => a(f) != b(f),
      BinOp.bitAnd => (f) => _int(a(f)) & _int(b(f)),
      BinOp.bitOr => (f) => _int(a(f)) | _int(b(f)),
      BinOp.bitXor => (f) => _int(a(f)) ^ _int(b(f)),
      BinOp.shl => (f) => _int(a(f)) << _int(b(f)),
      BinOp.shr => (f) => _int(a(f)) >> _int(b(f)),
    };
  }
}

enum UnOp { neg, not, bitNot }

class Unary extends Expr {
  const Unary(this.op, this.operand);

  final UnOp op;
  final Expr operand;

  @override
  ExprFn compile(CompileContext ctx) {
    final v = operand.compile(ctx);
    return switch (op) {
      UnOp.neg => (f) => -_num(v(f)),
      UnOp.not => (f) => !asBool(v(f)),
      UnOp.bitNot => (f) => ~_int(v(f)),
    };
  }
}

/// Ternary conditional.
class Conditional extends Expr {
  const Conditional(this.cond, this.then, this.otherwise);

  final Expr cond;
  final Expr then;
  final Expr otherwise;

  @override
  ExprFn compile(CompileContext ctx) {
    final c = cond.compile(ctx);
    final t = then.compile(ctx);
    final e = otherwise.compile(ctx);
    return (f) => asBool(c(f)) ? t(f) : e(f);
  }
}

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

/// Calls a host member through the bridge — the only way out of the sandbox.
///
/// Arity-specialised: the 0/1/2-argument forms skip building a list, and they
/// cover almost every real call site.
class HostCall extends Expr {
  const HostCall(
    this.memberId, {
    this.receiver,
    this.args = const [],
    this.named = const {},
  });

  final int memberId;

  /// Null for statics and top-level functions.
  final Expr? receiver;
  final List<Expr> args;
  final Map<String, Expr> named;

  @override
  ExprFn compile(CompileContext ctx) {
    final id = memberId;
    final host = ctx.host;
    // Reject at compile time, not on the call. Load-time rejection means a
    // manifest/binary mismatch can never surface halfway through a patched
    // operation, with side effects already applied.
    if (!host.isBound(id)) {
      throw UnboundMemberFault(id);
    }
    final r = receiver?.compile(ctx);
    final a = <ExprFn>[for (final e in args) e.compile(ctx)];

    if (named.isNotEmpty) {
      final n = {
        for (final entry in named.entries) entry.key: entry.value.compile(ctx),
      };
      return (f) => host.invoke(
            id,
            r?.call(f),
            [for (final fn in a) fn(f)],
            {for (final e in n.entries) e.key: e.value(f)},
          );
    }

    switch (a.length) {
      case 0:
        return (f) => host.invoke(id, r?.call(f), const [], null);
      case 1:
        final x = a[0];
        return (f) => host.invoke(id, r?.call(f), [x(f)], null);
      case 2:
        final x = a[0], y = a[1];
        return (f) => host.invoke(id, r?.call(f), [x(f), y(f)], null);
      case 3:
        final x = a[0], y = a[1], z = a[2];
        return (f) => host.invoke(id, r?.call(f), [x(f), y(f), z(f)], null);
      default:
        return (f) =>
            host.invoke(id, r?.call(f), [for (final fn in a) fn(f)], null);
    }
  }
}

/// Calls another interpreted function.
class VmCall extends Expr {
  const VmCall(this.functionIndex, {this.args = const [], this.named = const {}});

  final int functionIndex;
  final List<Expr> args;
  final Map<String, Expr> named;

  @override
  ExprFn compile(CompileContext ctx) {
    if (functionIndex < 0 || functionIndex >= ctx.functions.length) {
      throw PatchLoadFault('function index $functionIndex out of range');
    }
    final ref = ctx.functions[functionIndex];
    final a = <ExprFn>[for (final e in args) e.compile(ctx)];
    final n = named.isEmpty
        ? null
        : {
            for (final entry in named.entries)
              entry.key: entry.value.compile(ctx),
          };
    return (f) {
      final target = ref.target;
      if (target is! VmInvokable) {
        throw PatchLoadFault('function #$functionIndex unresolved');
      }
      return target.invoke(
        [for (final fn in a) fn(f)],
        n == null ? null : {for (final e in n.entries) e.key: e.value(f)},
        // Depth grows per interpreted frame so runaway recursion is caught
        // here rather than by a native stack overflow.
        f.depth + 1,
      );
    };
  }
}

/// What [VmCall] needs from an interpreted function. Declared here so this file
/// does not depend on `function.dart`.
abstract interface class VmInvokable {
  Object? invoke(
    List<Object?> positional, [
    Map<String, Object?>? named,
    int depth,
  ]);
}

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

class ListLiteral extends Expr {
  const ListLiteral(this.elements);

  final List<Expr> elements;

  @override
  ExprFn compile(CompileContext ctx) {
    final es = <ExprFn>[for (final e in elements) e.compile(ctx)];
    if (es.isEmpty) return (_) => <Object?>[];
    return (f) => <Object?>[for (final fn in es) fn(f)];
  }
}

class MapLiteral extends Expr {
  const MapLiteral(this.entries);

  final List<(Expr, Expr)> entries;

  @override
  ExprFn compile(CompileContext ctx) {
    final es = <(ExprFn, ExprFn)>[
      for (final e in entries) (e.$1.compile(ctx), e.$2.compile(ctx)),
    ];
    if (es.isEmpty) return (_) => <Object?, Object?>{};
    return (f) => <Object?, Object?>{
          for (final e in es) e.$1(f): e.$2(f),
        };
  }
}

class SetLiteral extends Expr {
  const SetLiteral(this.elements);

  final List<Expr> elements;

  @override
  ExprFn compile(CompileContext ctx) {
    final es = <ExprFn>[for (final e in elements) e.compile(ctx)];
    if (es.isEmpty) return (_) => <Object?>{};
    return (f) => <Object?>{for (final fn in es) fn(f)};
  }
}

/// String interpolation. Concatenation is done with a buffer rather than
/// repeated `+` because `'$a$b$c'` is everywhere in this codebase's messages.
class StringInterp extends Expr {
  const StringInterp(this.parts);

  final List<Expr> parts;

  @override
  ExprFn compile(CompileContext ctx) {
    final ps = <ExprFn>[for (final e in parts) e.compile(ctx)];
    if (ps.length == 1) {
      final only = ps[0];
      return (f) => '${only(f)}';
    }
    return (f) {
      final sb = StringBuffer();
      for (final fn in ps) {
        sb.write(fn(f));
      }
      return sb.toString();
    };
  }
}

/// `list[i]` / `map[k]`.
class IndexGet extends Assignable {
  const IndexGet(this.target, this.index);

  final Expr target;
  final Expr index;

  @override
  ExprFn compile(CompileContext ctx) {
    final t = target.compile(ctx);
    final i = index.compile(ctx);
    return (f) {
      final recv = t(f);
      final key = i(f);
      if (recv is List) {
        if (key is! int) {
          throw TypeFault('list index must be int, got ${key.runtimeType}');
        }
        if (key < 0 || key >= recv.length) {
          throw BoundsFault('index $key outside 0..${recv.length - 1}');
        }
        return recv[key];
      }
      if (recv is Map) return recv[key];
      if (recv is String) {
        if (key is! int) {
          throw TypeFault('string index must be int, got ${key.runtimeType}');
        }
        if (key < 0 || key >= recv.length) {
          throw BoundsFault('index $key outside 0..${recv.length - 1}');
        }
        return recv[key];
      }
      throw TypeFault('cannot index ${recv.runtimeType}');
    };
  }

  @override
  void Function(Frame, Object?) compileStore(CompileContext ctx) {
    final t = target.compile(ctx);
    final i = index.compile(ctx);
    return (f, v) {
      final recv = t(f);
      final key = i(f);
      if (recv is List) {
        if (key is! int) {
          throw TypeFault('list index must be int, got ${key.runtimeType}');
        }
        if (key < 0 || key >= recv.length) {
          throw BoundsFault('index $key outside 0..${recv.length - 1}');
        }
        recv[key] = v;
        return;
      }
      if (recv is Map) {
        recv[key] = v;
        return;
      }
      throw TypeFault('cannot index-assign ${recv.runtimeType}');
    };
  }
}

// ---------------------------------------------------------------------------
// Type operations
// ---------------------------------------------------------------------------

/// Runtime type kinds the VM can test directly.
///
/// Only shapes the VM itself understands. Testing a host type goes through the
/// bridge instead, so this stays independent of the binding surface.
enum VmType { intType, doubleType, numType, stringType, boolType, listType, mapType, setType }

/// `x is T` for VM-native types.
class TypeTest extends Expr {
  const TypeTest(this.operand, this.type, {this.negated = false});

  final Expr operand;
  final VmType type;
  final bool negated;

  @override
  ExprFn compile(CompileContext ctx) {
    final v = operand.compile(ctx);
    final neg = negated;
    bool test(Object? o) => switch (type) {
          VmType.intType => o is int,
          VmType.doubleType => o is double,
          VmType.numType => o is num,
          VmType.stringType => o is String,
          VmType.boolType => o is bool,
          VmType.listType => o is List,
          VmType.mapType => o is Map,
          VmType.setType => o is Set,
        };
    return (f) => test(v(f)) != neg;
  }
}

/// `x is T` where T is a host type, tested through the bridge.
class HostTypeTest extends Expr {
  const HostTypeTest(this.operand, this.typeId, {this.negated = false});

  final Expr operand;
  final int typeId;
  final bool negated;

  @override
  ExprFn compile(CompileContext ctx) {
    final v = operand.compile(ctx);
    final host = ctx.host;
    final id = typeId;
    final neg = negated;
    return (f) => host.isInstanceOf(id, v(f)) != neg;
  }
}

/// `x!` — null assertion.
class NotNull extends Expr {
  const NotNull(this.operand);

  final Expr operand;

  @override
  ExprFn compile(CompileContext ctx) {
    final v = operand.compile(ctx);
    return (f) {
      final o = v(f);
      // A null-assertion failure is the patch's own logic error, not broken
      // machinery, so it must surface as an ordinary Dart error and propagate —
      // not as a PatchVmFault that would silently fall back to the original.
      if (o == null) throw _NullAssertion();
      return o;
    };
  }
}

/// Thrown by a failed `!`. Mirrors Dart's own behaviour rather than being a
/// [PatchVmFault], so the seam propagates it instead of quarantining.
final class _NullAssertion extends TypeError {
  @override
  String toString() => 'Null check operator used on a null value';
}

// ---------------------------------------------------------------------------
// Coercion helpers
//
// These carry the VM's dynamic-type discipline. Each failure is a TypeFault
// because it means the patch compiler's static reasoning disagreed with runtime
// reality — a tooling inconsistency, not patch logic.
// ---------------------------------------------------------------------------

/// Coerces to bool, rejecting anything else.
///
/// Public because `stmt.dart` needs it for every condition it compiles. Dart has
/// no truthiness, and neither does the IR: a non-bool condition means our own
/// compiler emitted something inconsistent, so it must fault rather than guess.
bool asBool(Object? v) {
  if (v is bool) return v;
  throw TypeFault('expected bool, got ${v.runtimeType}');
}

num _num(Object? v) {
  if (v is num) return v;
  throw TypeFault('expected num, got ${v.runtimeType}');
}

int _int(Object? v) {
  if (v is int) return v;
  throw TypeFault('expected int, got ${v.runtimeType}');
}

/// `+` is overloaded in Dart across num, String, and List, and patches use all
/// three, so it dispatches on the operands instead of assuming num.
Object? _add(Object? a, Object? b) {
  if (a is num && b is num) return a + b;
  if (a is String) return a + (b is String ? b : '$b');
  if (a is List) return [...a, ...(b is Iterable ? b : [b])];
  throw TypeFault('cannot add ${a.runtimeType} and ${b.runtimeType}');
}

Object _intDiv(Object? a, Object? b) {
  final x = _num(a), y = _num(b);
  if (y == 0) throw BoundsFault('integer division by zero');
  return x ~/ y;
}

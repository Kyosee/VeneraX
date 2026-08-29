import 'errors.dart';

/// One activation record.
///
/// Locals live in a fixed-length list, indexed by slot numbers the compiler
/// assigned. A `Map<String, Object?>` scope would cost a hash lookup per
/// variable access — the single most frequent operation in any interpreter —
/// so names are resolved once at compile time and never appear at runtime.
final class Frame {
  Frame(int slotCount, {required this.depth})
      : slots = List<Object?>.filled(slotCount, null, growable: false);

  final List<Object?> slots;

  /// Call depth, carried so runaway recursion is caught by the interpreter
  /// rather than by a native stack overflow — which no Dart `catch` can recover
  /// from, and which takes the process down with it.
  final int depth;

  /// Set by a `return` statement; read at the function boundary.
  Object? returnValue;
}

/// Statement outcome.
///
/// A plain int, not an enum or an exception. Every statement in every loop
/// iteration produces one of these, so an enum would box and an exception would
/// cost an allocation plus a stack capture on ordinary control flow.
///
/// Note there is deliberately no "raise" signal: an exception in interpreted
/// code is a real Dart `throw`, so host exceptions and interpreted ones unwind
/// through the same mechanism and a compiled `try` is a real Dart `try`. That
/// keeps the happy path free of exception bookkeeping and makes it impossible
/// for the two kinds of failure to diverge.
abstract final class Flow {
  /// Continue with the next statement.
  static const int next = 0;

  /// A `return` executed; unwind to the function boundary.
  static const int ret = 1;

  /// A `break` executed; unwind past the nearest enclosing loop or switch.
  static const int brk = 2;

  /// A `continue` executed; jump to the nearest enclosing loop head.
  static const int cont = 3;
}

/// Execution limits.
///
/// Not a defence against malicious patches — only our own signing key can
/// produce one. These bound *our own bugs*, which land on user devices where an
/// infinite loop is an unrecoverable freeze with no debugger attached. Failing
/// fast so the seam can fall back to the original implementation is strictly
/// better than hanging.
final class VmLimits {
  const VmLimits({
    this.maxCallDepth = 256,
    this.maxLoopIterations = 20000000,
  });

  final int maxCallDepth;

  /// Per-loop iteration ceiling. High enough that no legitimate patch reaches
  /// it, low enough that hitting it fails in seconds instead of hanging.
  final int maxLoopIterations;

  static const VmLimits standard = VmLimits();

  void checkDepth(int depth) {
    if (depth > maxCallDepth) {
      throw ResourceLimitFault('call depth exceeded $maxCallDepth');
    }
  }
}

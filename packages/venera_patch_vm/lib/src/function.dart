import 'errors.dart';
import 'expr.dart';
import 'frame.dart';
import 'stmt.dart';

/// An interpreted function.
///
/// The body compiles once, at load time, into a closure chain; calling it is
/// then a sequence of closure invocations with no `switch (node.kind)` dispatch.
/// That is the whole performance argument for this design — measured at 23.2x
/// native AOT on a representative parsing function, close to bytecode-VM
/// territory for a fraction of the machinery.
///
/// Slots are assigned by the compiler: parameters occupy the low indices in
/// declaration order (required positional, then optional positional, then
/// named), locals follow. Nothing looks up a variable by name at runtime.
// `implements VmInvokable` is load-bearing, not documentation: Dart's `is` test
// is nominal, so [VmCall] rejecting a target that merely *has* a matching
// `invoke` signature would fail every interpreted-to-interpreted call. The
// differential tests caught exactly that.
final class VmFunction implements VmInvokable {
  VmFunction({
    required this.name,
    required this.slotCount,
    required this.requiredCount,
    required this.optionalCount,
    required this.namedSlots,
    required this.limits,
    this.isAsync = false,
  });

  final String name;

  /// Frame size. Fixed at compile time, so the frame is one flat allocation.
  final int slotCount;

  /// Required positional parameters, in slots `0..requiredCount-1`.
  final int requiredCount;

  /// Optional positional parameters, following the required ones.
  final int optionalCount;

  /// Named parameter name to slot index.
  final Map<String, int> namedSlots;

  /// Default-value expressions by slot, for parameters the caller omitted.
  /// Populated by the loader alongside [body].
  final Map<int, ExprFn> defaults = {};

  final VmLimits limits;

  /// Whether the body awaits. An async body returns a Future and is invoked
  /// through [invokeAsync]; the distinction is resolved at compile time so a
  /// synchronous call never pays for `FutureOr` handling.
  final bool isAsync;

  /// Compiled body. Assigned by the loader after every function in the bundle
  /// has been constructed, so mutual recursion resolves.
  late final StmtFn body;

  int get maxPositional => requiredCount + optionalCount;

  /// Calls the function synchronously.
  ///
  /// [depth] is threaded so runaway recursion is caught by the interpreter's own
  /// counter. A native stack overflow cannot be caught in Dart and takes the
  /// process down, which on a user's device is indistinguishable from the crashes
  /// this whole mechanism exists to fix.
  @override
  Object? invoke(
    List<Object?> positional, [
    Map<String, Object?>? named,
    int depth = 0,
  ]) {
    limits.checkDepth(depth);
    final frame = bindFrame(positional, named, depth);
    body(frame);
    return frame.returnValue;
  }

  /// Builds and populates a frame for a call. Exposed because a bridge shell
  /// (stage 4) needs to drive a method body with a receiver already in place.
  Frame bindFrame(
    List<Object?> positional,
    Map<String, Object?>? named,
    int depth,
  ) {
    if (positional.length < requiredCount ||
        positional.length > maxPositional) {
      throw TypeFault(
        '$name expects $requiredCount..$maxPositional positional arguments, '
        'got ${positional.length}',
      );
    }
    final frame = Frame(slotCount, depth: depth);
    final slots = frame.slots;
    for (var i = 0; i < positional.length; i++) {
      slots[i] = positional[i];
    }
    // Defaults for omitted optionals. Evaluated against this frame so a default
    // can reference an earlier parameter, matching Dart's own rule.
    for (var i = positional.length; i < maxPositional; i++) {
      final d = defaults[i];
      if (d != null) slots[i] = d(frame);
    }
    if (namedSlots.isNotEmpty) {
      for (final entry in namedSlots.entries) {
        final slot = entry.value;
        if (named != null && named.containsKey(entry.key)) {
          slots[slot] = named[entry.key];
        } else {
          final d = defaults[slot];
          if (d != null) slots[slot] = d(frame);
        }
      }
    }
    if (named != null) {
      for (final key in named.keys) {
        if (!namedSlots.containsKey(key)) {
          throw TypeFault('$name has no named parameter "$key"');
        }
      }
    }
    return frame;
  }
}

/// A callable that interpreted code can pass around: a tear-off, a closure, or
/// a function-typed argument handed to a host API.
///
/// Implements [Function] via `call` so a host binding can accept it wherever a
/// Dart callback is expected — which is what lets a patch supply, say, a
/// `Comparator` to `List.sort` without the binding knowing about the VM.
final class VmClosure implements VmInvokable {
  VmClosure(this.function, this.depth, [this.captured]);

  final VmFunction function;

  /// Depth at the point of capture, so calling a closure from inside deep
  /// recursion still counts against the same budget.
  final int depth;

  /// Enclosing frame for a nested function. Null for a top-level tear-off.
  final Frame? captured;

  Object? call([
    Object? a0 = _absent,
    Object? a1 = _absent,
    Object? a2 = _absent,
    Object? a3 = _absent,
  ]) {
    final args = <Object?>[];
    if (!identical(a0, _absent)) args.add(a0);
    if (!identical(a1, _absent)) args.add(a1);
    if (!identical(a2, _absent)) args.add(a2);
    if (!identical(a3, _absent)) args.add(a3);
    return function.invoke(args, null, depth + 1);
  }

  /// Invocation with an explicit argument list, used by the VM's own call sites
  /// where arity is known from the IR.
  ///
  /// The declared [depth] argument is ignored in favour of the capture depth:
  /// a closure invoked from shallow code must still count against the budget of
  /// the recursion it was created inside, or a closure handed outward would
  /// reset the depth counter and defeat the limit.
  @override
  Object? invoke(
    List<Object?> positional, [
    Map<String, Object?>? named,
    int callerDepth = 0,
  ]) {
    final d = callerDepth > depth ? callerDepth : depth;
    return function.invoke(positional, named, d + 1);
  }

  @override
  String toString() => 'VmClosure(${function.name})';

  static const Object _absent = Object();
}

/// A loaded bundle: the functions it defines plus the override ids it claims.
final class VmProgram {
  VmProgram({
    required this.functions,
    required this.overrides,
  });

  /// All interpreted functions, indexed as the IR references them.
  final List<VmFunction> functions;

  /// Override id to function index. These are the seams this bundle takes over;
  /// everything else in the app keeps running its original compiled code.
  final Map<int, int> overrides;

  VmFunction? overrideFor(int id) {
    final index = overrides[id];
    if (index == null) return null;
    if (index < 0 || index >= functions.length) {
      throw PatchLoadFault('override #$id points at function $index');
    }
    return functions[index];
  }
}

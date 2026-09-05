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
  ///
  /// Set only when [isAsync] is false; an async function carries [asyncBody]
  /// instead. Keeping them as separate fields rather than one `FutureOr`-typed
  /// field is what keeps a synchronous call free of async bookkeeping.
  late final StmtFn body;

  /// Compiled body for an async function.
  late final StmtAsyncFn asyncBody;

  int get maxPositional => requiredCount + optionalCount;

  /// Calls the function.
  ///
  /// An async function returns a `Future<Object?>` here, exactly as calling a
  /// Dart `async` function does. That symmetry is deliberate: it means [VmCall]
  /// needs no special case, and an interpreted `await` on the result behaves the
  /// way the same source would natively.
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
    if (isAsync) return _runAsync(frame);
    body(frame);
    return frame.returnValue;
  }

  /// Awaits the async body, then reads the return slot.
  ///
  /// The body is a real Dart `async` closure chain, so suspension is the host's
  /// own — there is no scheduler of ours to get wrong. That was the single
  /// riskiest thing this design could have contained, and delegating it removes
  /// the risk entirely rather than managing it.
  Future<Object?> _runAsync(Frame frame) async {
    await asyncBody(frame);
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
/// ## Why callers receive `closure.call`, never the closure itself
///
/// A Dart object with a `call` method is *invocable* — `c(1)` compiles — but it
/// is **not** a subtype of `Function`: `c is Function` is false and
/// `c as Function` throws. Every closure-taking host binding casts its callback
/// that way (`a[0] as Function` in `CoreBindings`), so handing out the object
/// made `list.where((x) => ...)` throw a `TypeError` at the boundary, which the
/// seam then read as a machinery fault: quarantined, silently fallen back to the
/// original. A patch that looked installed and did nothing.
///
/// `implements Function` cannot fix it — `Function` is a final class. So
/// [ClosureExpr] hands out the **tear-off** `closure.call`, which is a real
/// `Function` object, and the cast succeeds.
///
/// Same nominal-typing trap that made every interpreted-to-interpreted call fail
/// until [VmFunction] declared `implements VmInvokable`. Dart's `is` never infers
/// structural conformance; it has to be arranged deliberately.
final class VmClosure implements VmInvokable {
  VmClosure(this.function, this.depth, [this.bound = const []]);

  final VmFunction function;

  /// Depth at the point of capture, so calling a closure from inside deep
  /// recursion still counts against the same budget.
  final int depth;

  /// Values captured from the enclosing scope, prepended to every call.
  ///
  /// Capture is resolved by *lambda lifting* in the compiler, not by a frame
  /// chain here: a closure body is compiled as an ordinary top-level function
  /// whose leading parameters are the variables it captured, and the values are
  /// evaluated once, where the closure is created. So this list is the whole of
  /// the closure's environment.
  ///
  /// The alternative — giving each frame a pointer to its enclosing one and
  /// walking the chain on a slot read — would put a branch on the single hottest
  /// operation in the interpreter to support a feature most patches never use.
  /// Worse, an earlier draft of this class carried exactly that pointer and
  /// *never read it*, which meant a closure reading an enclosing variable would
  /// have quietly read its own frame's slot instead: the same index, a different
  /// frame, a plausible wrong answer. Values, evaluated once, cannot fail that
  /// way.
  final List<Object?> bound;

  Object? call([
    Object? a0 = _absent,
    Object? a1 = _absent,
    Object? a2 = _absent,
    Object? a3 = _absent,
  ]) {
    final args = <Object?>[...bound];
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
    // Captured values lead, exactly as in [call]. Both entry points must agree:
    // a closure reached through the host (`call`) and one reached from
    // interpreted code (`invoke`) are the same closure, and a disagreement here
    // would shift every parameter by the number of captures — silently, and
    // only for closures that capture anything.
    final args = bound.isEmpty ? positional : <Object?>[...bound, ...positional];
    return function.invoke(args, named, d + 1);
  }

  @override
  String toString() => 'VmClosure(${function.name})';

  static const Object _absent = Object();
}

/// Builds a [VmClosure] over the function at [functionIndex].
///
/// Lives here rather than in `expr.dart` because it constructs a [VmClosure],
/// and `expr.dart` deliberately does not import this file — its [VmFunctionRef]
/// keeps its target as `Object?` for exactly that reason.
///
/// ## Non-capturing only, deliberately
///
/// The closure body gets a fresh frame from [VmFunction.invoke], so it can reach
/// its own parameters and nothing else. A body referring to a local of the
/// enclosing function would need that frame threaded through, and slots are
/// per-frame indices — there is no representation for "slot 2 of my parent".
///
/// That is not as limiting as it sounds: `where((x) => x > 3)`,
/// `map((x) => x * 2)`, `fold(0, (a, b) => a + b)` capture nothing. What the
/// compiler must do is *reject* a capturing lambda with an actionable message
/// rather than compile one that silently reads a null slot — a wrong answer from
/// a patch is worse than a patch that would not build.
class ClosureExpr extends Expr {
  const ClosureExpr(this.functionIndex, {this.captures = const []});

  final int functionIndex;

  /// Expressions for the values the closure captures, in the order the lifted
  /// function declares them as leading parameters.
  ///
  /// Evaluated **here**, when the closure is created — not when it is called.
  /// That is what makes capture-by-value correct rather than merely convenient:
  /// a `for` loop creating a closure per iteration captures each iteration's
  /// value, which is what Dart itself does for a loop variable.
  final List<Expr> captures;

  @override
  ExprFn compile(CompileContext ctx) {
    if (functionIndex < 0 || functionIndex >= ctx.functions.length) {
      throw PatchLoadFault(
        'closure names function $functionIndex, but the payload defines '
        '${ctx.functions.length}',
      );
    }
    final ref = ctx.functions[functionIndex];
    final caps = <ExprFn>[for (final c in captures) c.compile(ctx)];

    // The VALUE handed out is `closure.call` — a tear-off — not the [VmClosure]
    // itself.
    //
    // Having a `call` method makes an object callable but does NOT make it a
    // subtype of `Function`: `x is Function` is false and `x as Function`
    // throws. Every closure-taking binding casts its callback exactly that way
    // (`a[0] as Function` in `CoreBindings`), so passing the object would throw
    // a TypeError at the host boundary — reported as a machinery fault,
    // quarantined, and silently fallen back to the original. A tear-off *is* a
    // real `Function`, so the cast succeeds and `where`/`map`/`sort` work.
    //
    // `implements Function` is not an option: `Function` is a final class. This
    // is the same nominal-typing trap that broke every interpreted-to-
    // interpreted call until [VmFunction] declared `implements VmInvokable` —
    // Dart never infers structural conformance, and the round-trip tests caught
    // both.
    if (caps.isEmpty) {
      return (f) {
        final target = ref.target;
        if (target is! VmFunction) {
          throw PatchLoadFault('closure #$functionIndex unresolved');
        }
        // Depth carried from the creating frame so a closure handed to a host
        // callback still counts against the recursion budget of the code that
        // made it, instead of resetting the counter on the way out.
        return VmClosure(target, f.depth).call;
      };
    }
    return (f) {
      final target = ref.target;
      if (target is! VmFunction) {
        throw PatchLoadFault('closure #$functionIndex unresolved');
      }
      return VmClosure(target, f.depth, [for (final c in caps) c(f)]).call;
    };
  }
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

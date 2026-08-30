import 'package:venera_patch_vm/venera_patch_vm.dart';

import 'registry.dart';

/// Adapts a loaded [VmProgram] into the [OverrideFn]s a generated seam calls.
///
/// This is a thin layer with one load-bearing job: keeping the two kinds of
/// failure apart.
///
/// * A [PatchVmFault] means the *machinery* broke — malformed payload, unbound
///   member, depth or iteration ceiling hit. The seam must fall back to the
///   original implementation and quarantine the override, because the patch
///   cannot be trusted to produce a correct answer.
/// * Anything else is an exception the patched code *meant* to throw. It
///   propagates untouched.
///
/// Blurring the two produces the worst failure mode in the whole design: a
/// patch that correctly rejects bad input gets read as "machinery broken", the
/// seam silently runs the old code, and the fix looks installed while doing
/// nothing. Every future investigation then starts by asking which
/// implementation is actually running.
class VmOverrideBinder {
  const VmOverrideBinder._();

  /// Builds the override table for [program].
  ///
  /// Each entry wraps one interpreted function. `orig` reaches the interpreted
  /// code as its last argument, so a patch can call the original and correct the
  /// result rather than reimplementing it — the smaller, safer shape of fix.
  static Map<int, OverrideFn> bind(VmProgram program) {
    final table = <int, OverrideFn>{};
    for (final id in program.overrides.keys) {
      final fn = program.overrideFor(id);
      if (fn == null) continue;
      table[id] = _wrap(id, fn);
    }
    return table;
  }

  static OverrideFn _wrap(int id, VmFunction fn) {
    return (args, orig) {
      final Object? result;
      try {
        result = fn.invoke(args);
      } on PatchVmFault catch (e, s) {
        _quarantineAndRethrow(id, e, s);
      }
      // An async override returns its Future *here*, before the body has run, so
      // a fault inside it arrives long after the try/catch above has exited. A
      // synchronous catch alone would let it escape as an unhandled async error:
      // no quarantine, no fallback, and the seam would go on calling a broken
      // override forever. So the same handling is attached to the Future.
      if (result is Future) {
        return result.catchError(
          (Object e, StackTrace s) => _quarantineAndRethrow(id, e, s),
          test: (e) => e is PatchVmFault,
        );
      }
      return result;
      // A non-fault exception is deliberately NOT caught on either path: it is
      // the patched code's own throw and must reach the caller exactly as the
      // original implementation's would.
    };
  }

  /// Quarantines [id] and re-raises as the host-side type the seam falls back
  /// from. Shared by the sync and async paths so they cannot drift apart —
  /// which is precisely how the async path came to be missing this originally.
  static Never _quarantineAndRethrow(int id, Object fault, StackTrace s) {
    PatchRegistry.quarantine(id, fault);
    Error.throwWithStackTrace(
      PatchVmError(
        id,
        fault is PatchVmFault ? fault.detail : fault.toString(),
        fault,
      ),
      s,
    );
  }
}

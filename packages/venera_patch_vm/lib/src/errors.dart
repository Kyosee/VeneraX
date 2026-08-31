/// Faults raised by the VM machinery, as opposed to exceptions thrown *by*
/// interpreted code.
///
/// This distinction is load-bearing and must never be blurred. A seam that
/// treats both alike turns "the patch correctly threw a validation error" into
/// "the patch quietly fell back to the original implementation" — the patch
/// looks installed and working while doing nothing, which is worse than a
/// visible failure.
///
/// So: [PatchVmFault] means the machinery broke, and the seam should fall back
/// and quarantine the override. Anything else is the patch's own business
/// exception and propagates untouched.
sealed class PatchVmFault implements Exception {
  const PatchVmFault(this.detail);

  final String detail;

  @override
  String toString() => '$runtimeType: $detail';
}

/// The bundle is structurally invalid: bad ids, out-of-range indices, malformed
/// node shapes. Raised during load, before any interpreted code runs, so a
/// corrupt payload can never reach execution.
final class PatchLoadFault extends PatchVmFault {
  const PatchLoadFault(super.detail);
}

/// Interpreted code called a host member with no binding.
///
/// The patch compiler makes this impossible in principle: it checks every call
/// against the target build's surface manifest and refuses to emit a bundle
/// that reaches an unbound member. This exists for when that guarantee is
/// violated anyway — a manifest/binary mismatch — and turns it into a clean
/// fallback instead of a crash.
final class UnboundMemberFault extends PatchVmFault {
  const UnboundMemberFault(this.memberId, [String? detail])
      : super(detail ?? 'no binding for member #$memberId');

  final int memberId;
}

/// Interpreted code exceeded a resource bound (call depth, loop iterations).
final class ResourceLimitFault extends PatchVmFault {
  const ResourceLimitFault(super.detail);
}

/// A type assumption inside interpreted code did not hold.
///
/// The VM is dynamically typed, so what the patch compiler proved statically is
/// only as good as the binding metadata. A mismatch here means our own tooling
/// is inconsistent — machinery failure, not patch logic.
final class TypeFault extends PatchVmFault {
  const TypeFault(super.detail);
}

/// An index or range was outside its collection.
///
/// Separate from [TypeFault] because the cause differs: a type fault points at
/// inconsistent bindings, a bounds fault at arithmetic in the patch itself.
final class BoundsFault extends PatchVmFault {
  const BoundsFault(super.detail);
}

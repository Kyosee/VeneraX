/// Override registry: the lookup a generated seam performs.
///
/// Stage 1 ships the registry with no interpreter behind it, so `active` is
/// always false and every seam falls straight through to its original body. The
/// VM (stage 2) only has to call [installOverrides]; no seam changes.
///
/// ## Why the gate is a plain static bool
///
/// Seams are generated across the whole codebase, so the *uninstalled* cost is
/// paid by every call in the app. A static bool read is a few ns and folds into
/// the surrounding code; anything richer (a map probe, a null check on an
/// object field, a getter on a singleton) would not.
library;

/// Signature of an installed override. [orig] is the original implementation,
/// passed so a patch can wrap rather than replace — "call the original, then
/// correct the result" is a far smaller and safer change than a rewrite.
typedef OverrideFn = Object? Function(List<Object?> args, Function? orig);

/// Raised when the VM itself fails: malformed payload, unbound member, stack
/// overflow. Distinct from an exception the patched code *meant* to throw.
///
/// The seam must treat these differently. Conflating them turns "the patch
/// correctly rejected bad input" into "the patch silently ran the old code",
/// which is the worst possible failure mode: a fix that appears applied but
/// isn't.
class PatchVmError implements Exception {
  PatchVmError(this.overrideId, this.detail, [this.cause]);

  final int overrideId;
  final String detail;
  final Object? cause;

  @override
  String toString() => 'PatchVmError(#$overrideId): $detail'
      '${cause == null ? '' : ' <- $cause'}';
}

class PatchRegistry {
  PatchRegistry._();

  /// Hot gate. False whenever no patch is installed, which is the normal state.
  static bool active = false;

  static final Map<int, OverrideFn> _overrides = {};

  /// Override ids disabled after a VM-level failure. Kept separate from
  /// [_overrides] so a later reinstall of the same patch can retry cleanly.
  static final Set<int> _quarantined = {};

  /// Called when an override is quarantined, so the host can log it and surface
  /// it in diagnostics.
  static void Function(int id, Object error)? onOverrideFailed;

  static void installOverrides(Map<int, OverrideFn> overrides) {
    _overrides
      ..clear()
      ..addAll(overrides);
    _quarantined.clear();
    active = _overrides.isNotEmpty;
  }

  static void clear() {
    _overrides.clear();
    _quarantined.clear();
    active = false;
  }

  /// Resolves [id], or null when nothing is installed for it (or it has been
  /// quarantined). A null result means "run the original".
  static OverrideFn? lookup(int id) {
    if (!active) return null;
    if (_quarantined.isNotEmpty && _quarantined.contains(id)) return null;
    return _overrides[id];
  }

  /// Disables one override after a VM-level failure, leaving the rest of the
  /// patch in place. Isolating the failure beats discarding a patch whose other
  /// overrides are working.
  static void quarantine(int id, Object error) {
    _quarantined.add(id);
    onOverrideFailed?.call(id, error);
  }

  static bool isQuarantined(int id) => _quarantined.contains(id);

  static int get installedCount => _overrides.length;

  static Set<int> get quarantinedIds => Set.unmodifiable(_quarantined);
}

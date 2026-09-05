import 'manifest.dart';

/// Remote circuit breakers.
///
/// The only hot-update mechanism that helps with a *native* fault. A crash
/// inside a `.so` can never be patched from Dart, but the code path that
/// reaches it can be closed remotely, turning "crashes on launch" into "this
/// feature is temporarily unavailable".
///
/// Reads are on hot paths (a guarded feature may be checked per page build), so
/// the lookup is a map read behind an `isEmpty` short-circuit: zero cost while
/// no rule is installed, which is the normal state.
class KillSwitches {
  KillSwitches._();

  static final KillSwitches instance = KillSwitches._();

  /// id -> reason. Only *matching* rules land here, so membership alone is the
  /// answer; no per-query matching work.
  final Map<String, String> _active = {};

  /// Device facts, injected by the host so this package stays platform-free
  /// (and unit-testable without a Flutter binding).
  String _platform = '';
  String? _abi;
  String _appVersion = '';

  void configureDevice({
    required String platform,
    required String? abi,
    required String appVersion,
  }) {
    _platform = platform;
    _abi = abi;
    _appVersion = appVersion;
  }

  /// Replaces the rule set wholesale. Applying a track is atomic: a partially
  /// applied set could leave a feature disabled with no rule explaining why.
  void apply(List<KillRule> rules) {
    _active.clear();
    for (final rule in rules) {
      if (rule.matches(
        platform: _platform,
        abi: _abi,
        appVersion: _appVersion,
      )) {
        _active[rule.id] = rule.reason;
      }
    }
  }

  void clear() => _active.clear();

  /// Whether [featureId] may run. Default is `true` — a feature must never be
  /// disabled by the mere absence of a manifest (a network failure must not
  /// break the app).
  bool isEnabled(String featureId) {
    if (_active.isEmpty) return true;
    return !_active.containsKey(featureId);
  }

  /// Why [featureId] is disabled, for display. Null when it is enabled.
  String? reasonFor(String featureId) {
    if (_active.isEmpty) return null;
    return _active[featureId];
  }

  /// Snapshot for the settings screen / diagnostics.
  Map<String, String> get activeRules => Map.unmodifiable(_active);
}

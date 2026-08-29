/// L0 config overlay: remote values that shadow built-in defaults.
///
/// Covers the class of bug that is really a wrong constant — a timeout, a
/// threshold, a URL, a batch size, a feature default. No interpreter involved,
/// so this works on every platform including web.
///
/// The overlay never writes to the user's settings store. It shadows *defaults*
/// only, so a value the user has explicitly chosen always wins, and dropping
/// the overlay restores built-in behaviour exactly.
class ConfigOverlay {
  ConfigOverlay._();

  static final ConfigOverlay instance = ConfigOverlay._();

  final Map<String, Object?> _values = {};

  /// Keys the host refuses to let a patch touch. Credentials and sync-version
  /// state are excluded on principle: a patch that could rewrite `dataVersion`
  /// could corrupt the whole fleet's sync lineage, and one that could rewrite
  /// WebDAV credentials could redirect a user's backups.
  static const Set<String> protectedKeys = {
    'webdav',
    'dataVersion',
    'deviceId',
    'appLockType',
    'appLockCredential',
    'authorizationRequired',
  };

  /// Replaces the overlay wholesale. Protected keys are dropped, not rejected:
  /// one bad key must not discard an otherwise valid overlay.
  void apply(Map<String, Object?> values) {
    _values.clear();
    for (final e in values.entries) {
      if (protectedKeys.contains(e.key)) continue;
      _values[e.key] = e.value;
    }
  }

  void clear() => _values.clear();

  bool get isEmpty => _values.isEmpty;

  bool has(String key) => _values.isEmpty ? false : _values.containsKey(key);

  /// Overlay value for [key], or null when unset. Callers use
  /// `overlay.get(k) ?? builtinDefault`.
  Object? get(String key) => _values.isEmpty ? null : _values[key];

  T? typed<T>(String key) {
    final v = get(key);
    return v is T ? v : null;
  }

  Map<String, Object?> get snapshot => Map.unmodifiable(_values);
}

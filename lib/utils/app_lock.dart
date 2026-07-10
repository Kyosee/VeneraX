import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/appdata.dart';

/// Available unlock methods for the app lock.
///
/// [biometric] delegates to the device's fingerprint/face hardware (the legacy
/// behaviour). The remaining three are self-contained fallbacks that work on
/// devices without biometric hardware — e-readers being the motivating case.
enum AppLockType {
  biometric,
  pin,
  password,
  pattern;

  static AppLockType fromName(String? name) {
    return AppLockType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => AppLockType.biometric,
    );
  }
}

/// Persists and verifies the local unlock credential.
///
/// The secret (PIN / password / pattern) is never stored in the clear: we keep
/// a random salt plus a salted SHA-256 digest, so reading appdata.json does not
/// reveal the code. This is a local-tampering deterrent, not defence against a
/// determined attacker with the device — matching the biometric feature's
/// threat model. The credential lives in [appdata] under `appLockCredential`
/// and is device-local (never synced — see `_disableSync`).
class AppLock {
  const AppLock._();

  static AppLockType get type =>
      AppLockType.fromName(appdata.settings['appLockType'] as String?);

  /// Whether a non-biometric credential has actually been set. Biometric mode
  /// needs no stored secret.
  static bool get hasCredential {
    var stored = appdata.settings['appLockCredential'];
    return stored is Map && stored['hash'] != null && stored['salt'] != null;
  }

  static String _hash(String secret, String salt) {
    return sha256.convert(utf8.encode('$salt::$secret')).toString();
  }

  static String _newSalt() {
    var rng = Random.secure();
    var bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Store [type] and, for non-biometric methods, the salted hash of [secret].
  /// Passing biometric clears any stored secret.
  static Future<void> setCredential(AppLockType type, [String? secret]) async {
    appdata.settings['appLockType'] = type.name;
    if (type == AppLockType.biometric || secret == null) {
      appdata.settings['appLockCredential'] = null;
    } else {
      var salt = _newSalt();
      appdata.settings['appLockCredential'] = {
        'salt': salt,
        'hash': _hash(secret, salt),
      };
    }
    await appdata.saveData();
  }

  /// Verify [secret] against the stored credential. Returns false when no
  /// credential is set (fail closed).
  static bool verify(String secret) {
    var stored = appdata.settings['appLockCredential'];
    if (stored is! Map) return false;
    var salt = stored['salt'];
    var hash = stored['hash'];
    if (salt is! String || hash is! String) return false;
    return _hash(secret, salt) == hash;
  }
}

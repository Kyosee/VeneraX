import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/app_lock.dart';

// AppLock stores a random salt + salted SHA-256 of the secret, never the
// secret itself. These tests drive verify/type purely through the in-memory
// settings map, so they touch no files (setCredential's saveData would hit
// disk and is exercised separately in manual runs).

String storedHash(String salt, String secret) =>
    sha256.convert(utf8.encode('$salt::$secret')).toString();

void main() {
  setUp(() {
    appdata.settings['appLockType'] = 'biometric';
    appdata.settings['appLockCredential'] = null;
  });

  test('fromName falls back to biometric for unknown / null', () {
    expect(AppLockType.fromName(null), AppLockType.biometric);
    expect(AppLockType.fromName('nonsense'), AppLockType.biometric);
    expect(AppLockType.fromName('pattern'), AppLockType.pattern);
  });

  test('verify accepts the correct secret and rejects others', () {
    const salt = 'fixed-salt';
    appdata.settings['appLockType'] = 'pin';
    appdata.settings['appLockCredential'] = {
      'salt': salt,
      'hash': storedHash(salt, '1234'),
    };

    expect(AppLock.type, AppLockType.pin);
    expect(AppLock.hasCredential, isTrue);
    expect(AppLock.verify('1234'), isTrue);
    expect(AppLock.verify('0000'), isFalse);
    expect(AppLock.verify(''), isFalse);
  });

  test('verify fails closed when no credential is set', () {
    appdata.settings['appLockType'] = 'password';
    appdata.settings['appLockCredential'] = null;

    expect(AppLock.hasCredential, isFalse);
    expect(AppLock.verify('anything'), isFalse);
  });

  test('a different salt yields a different stored hash for the same secret',
      () {
    expect(storedHash('a', 'secret'), isNot(storedHash('b', 'secret')));
  });
}

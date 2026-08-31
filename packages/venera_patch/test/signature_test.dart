import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/key_generators/api.dart'
    show ECKeyGeneratorParameters;
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:venera_patch/venera_patch.dart';

/// A signing-side helper mirroring what `tool/make_patch.dart` will do in CI.
/// Having it in the test is what makes the accept path meaningful: a verifier
/// that always returns false would pass a reject-only test suite.
class _Signer {
  _Signer() {
    final rnd = FortunaRandom();
    final seed = Uint8List(32);
    final r = Random.secure();
    for (var i = 0; i < seed.length; i++) {
      seed[i] = r.nextInt(256);
    }
    rnd.seed(KeyParameter(seed));

    final domain = ECCurve_secp256r1();
    final gen = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), rnd));
    final pair = gen.generateKeyPair();
    _private = pair.privateKey;
    _public = pair.publicKey;
    _random = rnd;
  }

  late final ECPrivateKey _private;
  late final ECPublicKey _public;
  late final SecureRandom _random;

  /// Uncompressed SEC1 point, base64 — the form compiled into the app.
  String get publicKeyB64 =>
      base64Encode(_public.Q!.getEncoded(false));

  String signB64(String message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(
        true,
        ParametersWithRandom(PrivateKeyParameter(_private), _random),
      );
    final sig = signer.generateSignature(
      Uint8List.fromList(utf8.encode(message)),
    ) as ECSignature;
    final out = Uint8List(64);
    out.setRange(0, 32, _pad32(sig.r));
    out.setRange(32, 64, _pad32(sig.s));
    return base64Encode(out);
  }

  static Uint8List _pad32(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    final out = Uint8List(32);
    out.setRange(32 - bytes.length, 32, bytes);
    return out;
  }
}

void main() {
  late _Signer signer;

  setUpAll(() {
    signer = _Signer();
  });

  group('accept path', () {
    test('a correctly signed message verifies', () {
      const body = '{"schema":1,"patchVersion":42}';
      expect(
        PatchSignature.verifyBase64(
          message: body,
          signatureB64: signer.signB64(body),
          publicKeyB64: signer.publicKeyB64,
        ),
        isTrue,
      );
    });

    test('signatures are verified over the literal signed bytes', () {
      // Whitespace-significant: the manifest is signed as text precisely so a
      // canonicalisation disagreement between signer and verifier cannot become
      // a bypass.
      const body = '{ "schema" : 1 }';
      final sig = signer.signB64(body);
      expect(
        PatchSignature.verifyBase64(
          message: body,
          signatureB64: sig,
          publicKeyB64: signer.publicKeyB64,
        ),
        isTrue,
      );
      expect(
        PatchSignature.verifyBase64(
          message: '{"schema":1}',
          signatureB64: sig,
          publicKeyB64: signer.publicKeyB64,
        ),
        isFalse,
        reason: 're-serialised JSON must not verify against the original',
      );
    });
  });

  group('reject path', () {
    test('a tampered message fails', () {
      const body = '{"schema":1,"patchVersion":42}';
      final sig = signer.signB64(body);
      expect(
        PatchSignature.verifyBase64(
          message: '{"schema":1,"patchVersion":43}',
          signatureB64: sig,
          publicKeyB64: signer.publicKeyB64,
        ),
        isFalse,
      );
    });

    test('a different key fails', () {
      const body = 'payload';
      final other = _Signer();
      expect(
        PatchSignature.verifyBase64(
          message: body,
          signatureB64: signer.signB64(body),
          publicKeyB64: other.publicKeyB64,
        ),
        isFalse,
      );
    });

    test('malformed inputs are rejected, not thrown', () {
      // A corrupt bundle and a forged bundle must take the same path: any throw
      // escaping here would turn a bad download into a crash.
      final pk = base64Decode(signer.publicKeyB64);
      final msg = Uint8List.fromList(utf8.encode('x'));

      expect(
        PatchSignature.verify(
          message: msg,
          signature: Uint8List(63),
          publicKeyPoint: pk,
        ),
        isFalse,
        reason: 'wrong signature length',
      );
      expect(
        PatchSignature.verify(
          message: msg,
          signature: Uint8List(64),
          publicKeyPoint: pk,
        ),
        isFalse,
        reason: 'r=s=0 is out of range',
      );
      expect(
        PatchSignature.verify(
          message: msg,
          signature: Uint8List(64)..[0] = 1,
          publicKeyPoint: Uint8List(65),
        ),
        isFalse,
        reason: 'point must start with 0x04',
      );
      expect(
        PatchSignature.verify(
          message: msg,
          signature: Uint8List(64)..[0] = 1,
          publicKeyPoint: Uint8List(64, )..[0] = 0x04,
        ),
        isFalse,
        reason: 'wrong point length',
      );
      expect(
        PatchSignature.verifyBase64(
          message: 'x',
          signatureB64: 'not base64!!!',
          publicKeyB64: signer.publicKeyB64,
        ),
        isFalse,
      );
    });

    test('an all-max scalar is out of range', () {
      final sig = Uint8List(64);
      for (var i = 0; i < 64; i++) {
        sig[i] = 0xFF;
      }
      expect(
        PatchSignature.verify(
          message: Uint8List.fromList(utf8.encode('x')),
          signature: sig,
          publicKeyPoint: base64Decode(signer.publicKeyB64),
        ),
        isFalse,
      );
    });
  });

  group('digest', () {
    test('sha256Hex matches the known vector for the empty input', () {
      expect(
        PatchSignature.sha256Hex(Uint8List(0)),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('sha256Hex zero-pads each byte', () {
      // A naive toRadixString loop drops the leading zero of bytes < 0x10 and
      // produces a short, mismatching digest.
      final hex = PatchSignature.sha256Hex(
        Uint8List.fromList(utf8.encode('abc')),
      );
      expect(hex.length, 64);
      expect(
        hex,
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show PublicKeyParameter;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart' show ECCurve_secp256r1;
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// Payload authentication for patch bundles.
///
/// ECDSA over secp256r1 (P-256) with SHA-256. Chosen over Ed25519 because
/// `pointycastle` — already a dependency of the host app — ships P-256 curves
/// and an ECDSA signer, while it has no Ed25519 implementation. Adding a crypto
/// dependency purely for the curve would enlarge the very attack surface this
/// module exists to bound.
///
/// Only the holder of the project private key can produce a bundle this
/// accepts. That is deliberate: it keeps the mechanism a first-party update
/// channel and makes user-authored patches impossible.
class PatchSignature {
  const PatchSignature._();

  /// Verifies a raw `r||s` signature (64 bytes) over [message].
  ///
  /// [publicKeyPoint] is an uncompressed SEC1 point: `0x04 || X(32) || Y(32)`.
  /// Returns false on any malformed input rather than throwing — a corrupt
  /// bundle and a forged bundle must take the same rejection path.
  static bool verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKeyPoint,
  }) {
    try {
      if (signature.length != 64) return false;
      if (publicKeyPoint.length != 65 || publicKeyPoint[0] != 0x04) {
        return false;
      }
      // Instantiated directly rather than via ECDomainParameters('secp256r1'),
      // which resolves through pointycastle's global registry — that lookup
      // depends on registration side effects and defeats tree-shaking.
      final domain = ECCurve_secp256r1();
      final q = domain.curve.decodePoint(publicKeyPoint);
      if (q == null) return false;
      final r = _toBigInt(signature.sublist(0, 32));
      final s = _toBigInt(signature.sublist(32, 64));
      // Reject out-of-range scalars before handing them to the signer.
      if (r <= BigInt.zero || r >= domain.n) return false;
      if (s <= BigInt.zero || s >= domain.n) return false;
      final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
        ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, domain)));
      return signer.verifySignature(message, ECSignature(r, s));
    } catch (_) {
      return false;
    }
  }

  /// Convenience wrapper for the on-disk/manifest encoding: base64 signature,
  /// base64 public key, UTF-8 message.
  static bool verifyBase64({
    required String message,
    required String signatureB64,
    required String publicKeyB64,
  }) {
    try {
      return verify(
        message: Uint8List.fromList(utf8.encode(message)),
        signature: base64Decode(signatureB64),
        publicKeyPoint: base64Decode(publicKeyB64),
      );
    } catch (_) {
      return false;
    }
  }

  /// SHA-256 of [data], lowercase hex. Used for payload integrity, which is a
  /// separate check from authenticity: the signature covers the manifest, the
  /// digest covers the (much larger) bundle the manifest points at.
  static String sha256Hex(Uint8List data) {
    final d = SHA256Digest().process(data);
    final sb = StringBuffer();
    for (final b in d) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static BigInt _toBigInt(Uint8List bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b);
    }
    return r;
  }
}

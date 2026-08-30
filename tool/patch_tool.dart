// Patch authoring tool: keygen, manifest signing, bundle packaging.
//
// Runs on a developer machine or in CI. It is the only thing that can produce a
// manifest the app accepts, because the app carries the public half of a P-256
// keypair and refuses anything it cannot verify. That asymmetry is the point:
// hot-update stays a first-party channel, and a user cannot author a patch even
// with full filesystem access.
//
// Usage:
//   dart tool/patch_tool.dart keygen [--out <dir>]
//   dart tool/patch_tool.dart sign --key <pem> --body <file> [--out <file>]
//   dart tool/patch_tool.dart manifest --spec <file> --key <pem> [--out <file>]
//   dart tool/patch_tool.dart verify --manifest <file> --pub <base64>

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:venera_patch/venera_patch.dart' show PatchSignature;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _usage();
    exit(64);
  }
  try {
    switch (args.first) {
      case 'keygen':
        _keygen(_flags(args.skip(1)));
      case 'sign':
        _sign(_flags(args.skip(1)));
      case 'manifest':
        _manifest(_flags(args.skip(1)));
      case 'verify':
        _verify(_flags(args.skip(1)));
      default:
        stderr.writeln('unknown command "${args.first}"');
        _usage();
        exit(64);
    }
  } on _ToolError catch (e) {
    stderr.writeln('error: ${e.message}');
    exit(1);
  }
}

// ---------------------------------------------------------------------------
// keygen
// ---------------------------------------------------------------------------

void _keygen(Map<String, String> flags) {
  final outDir = flags['out'] ?? 'build/patch-keys';
  Directory(outDir).createSync(recursive: true);

  final rnd = _secureRandom();
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(
      ECKeyGeneratorParameters(ECCurve_secp256r1()),
      rnd,
    ));
  final pair = gen.generateKeyPair();
  final priv = pair.privateKey;
  final pub = pair.publicKey;

  // Uncompressed SEC1 point: 0x04 || X(32) || Y(32). The form the app's
  // verifier expects, and the form that needs no ASN.1 parser on device.
  final pubB64 = base64Encode(pub.Q!.getEncoded(false));
  final privHex = priv.d!.toRadixString(16).padLeft(64, '0');

  final privPath = '$outDir/patch-signing-key.txt';
  File(privPath).writeAsStringSync('$privHex\n');
  File('$outDir/patch-public-key.txt').writeAsStringSync('$pubB64\n');

  stdout.writeln('Keypair written to $outDir/');
  stdout.writeln();
  stdout.writeln('PUBLIC KEY — paste into lib/foundation/hot_update.dart:');
  stdout.writeln("const String kPatchPublicKeyB64 = '$pubB64';");
  stdout.writeln();
  stdout.writeln('PRIVATE KEY — $privPath');
  stdout.writeln('  Store it in a secret manager (GitHub Secrets:');
  stdout.writeln('  PATCH_SIGNING_KEY) and delete the local copy. Anyone');
  stdout.writeln('  holding it can push code to every installed app.');
  stdout.writeln();
  stdout.writeln('Losing it is recoverable (ship a new public key in the next');
  stdout.writeln('release); leaking it is not.');
}

// ---------------------------------------------------------------------------
// sign
// ---------------------------------------------------------------------------

void _sign(Map<String, String> flags) {
  final keyPath = _require(flags, 'key');
  final bodyPath = _require(flags, 'body');
  final body = File(bodyPath).readAsStringSync();

  // Signed over the literal bytes of the body, which is also what the app
  // verifies and then parses. Signing a re-serialised object would require
  // canonical JSON, and signer/verifier disagreements about canonicalisation
  // are a well-worn signature-bypass class.
  final sig = _signBytes(
    Uint8List.fromList(utf8.encode(body)),
    _loadPrivateKey(keyPath),
  );
  final envelope = jsonEncode({'sig': base64Encode(sig), 'body': body});

  final out = flags['out'];
  if (out == null) {
    stdout.writeln(envelope);
  } else {
    File(out).writeAsStringSync(envelope);
    stdout.writeln('signed envelope -> $out');
  }
}

// ---------------------------------------------------------------------------
// manifest
// ---------------------------------------------------------------------------

/// Builds a signed manifest from a spec file.
///
/// The spec is the same shape as the manifest body, minus the fields this tool
/// computes: it fills in `schema`, and hashes each track's payload file to
/// produce `sha256` and `size`. Computing the digest here rather than trusting
/// a hand-written one removes the failure mode where a rebuilt bundle ships
/// with a stale digest and every device rejects it.
void _manifest(Map<String, String> flags) {
  final specPath = _require(flags, 'spec');
  final keyPath = _require(flags, 'key');
  final spec = jsonDecode(File(specPath).readAsStringSync());
  if (spec is! Map) throw _ToolError('spec is not a JSON object');

  final body = <String, Object?>{
    'schema': 1,
    ...Map<String, Object?>.from(spec),
  };

  if (body['patchVersion'] is! int) {
    throw _ToolError(
      'spec.patchVersion must be an int. It is compared numerically against '
      'the version floor compiled into each build, never by timestamp — a '
      'clock that moves backwards must not decide whether a patch applies.',
    );
  }

  final tracks = body['tracks'];
  if (tracks is! Map || tracks.isEmpty) {
    throw _ToolError('spec.tracks must be a non-empty object');
  }

  for (final entry in tracks.entries) {
    final track = entry.value;
    if (track is! Map) throw _ToolError('track "${entry.key}" is not an object');
    final payload = track['payload'];
    if (payload is! Map) continue;

    // `file` is a local path used only here; the app never sees it.
    final file = payload.remove('file');
    if (file == null) {
      if (payload['sha256'] == null || payload['url'] == null) {
        throw _ToolError(
          'track "${entry.key}" payload needs either "file" (to hash) or '
          'both "url" and "sha256"',
        );
      }
      continue;
    }
    final bytes = File(file.toString()).readAsBytesSync();
    payload['sha256'] = _sha256Hex(bytes);
    payload['size'] = bytes.length;
    if (payload['url'] == null) {
      throw _ToolError('track "${entry.key}" payload needs a "url"');
    }
    stdout.writeln(
      'track ${entry.key}: ${bytes.length} bytes, '
      'sha256 ${payload['sha256']}',
    );
  }

  final bodyJson = jsonEncode(body);
  final sig = _signBytes(
    Uint8List.fromList(utf8.encode(bodyJson)),
    _loadPrivateKey(keyPath),
  );
  final envelope = jsonEncode({'sig': base64Encode(sig), 'body': bodyJson});

  final out = flags['out'] ?? 'build/patch/manifest.json';
  File(out).parent.createSync(recursive: true);
  File(out).writeAsStringSync(envelope);
  stdout.writeln('signed manifest -> $out');
  stdout.writeln('patchVersion ${body['patchVersion']}, '
      'tracks ${tracks.keys.join(", ")}');
}

// ---------------------------------------------------------------------------
// verify
// ---------------------------------------------------------------------------

/// Checks a manifest against a public key, exactly as the app does.
///
/// Worth running in CI before publishing: a manifest the app rejects is
/// indistinguishable from no manifest at all, and the failure would only show
/// up as patches silently never arriving.
void _verify(Map<String, String> flags) {
  final manifestPath = _require(flags, 'manifest');
  final pubB64 = _require(flags, 'pub');
  final raw = File(manifestPath).readAsStringSync();
  final envelope = jsonDecode(raw);
  if (envelope is! Map) throw _ToolError('manifest is not a JSON object');
  final body = envelope['body'];
  final sig = envelope['sig'];
  if (body is! String || sig is! String) {
    throw _ToolError('manifest needs string "body" and "sig" fields');
  }

  // Deliberately the app's own verifier, not a second implementation here.
  //
  // The entire value of this command is the claim "the app would accept this".
  // A copy of the verification logic living in the tool can drift from the one
  // that actually runs on devices — and it would drift silently, in the
  // direction of the tool being more permissive, because that is the direction
  // nobody notices until a published manifest is rejected in the field.
  final ok = PatchSignature.verifyBase64(
    message: body,
    signatureB64: sig,
    publicKeyB64: pubB64,
  );

  if (!ok) {
    stderr.writeln('SIGNATURE INVALID — the app would reject this manifest');
    exit(1);
  }
  final parsed = jsonDecode(body);
  stdout.writeln('signature OK');
  if (parsed is Map) {
    stdout.writeln('  schema       ${parsed['schema']}');
    stdout.writeln('  patchVersion ${parsed['patchVersion']}');
    stdout.writeln('  minApp       ${parsed['minApp'] ?? '(any)'}');
    stdout.writeln('  maxApp       ${parsed['maxApp'] ?? '(any)'}');
    final tracks = parsed['tracks'];
    if (tracks is Map) {
      for (final e in tracks.entries) {
        final t = e.value;
        if (t is! Map) continue;
        final kills = (t['kills'] as List?)?.length ?? 0;
        final config = (t['config'] as Map?)?.length ?? 0;
        final hasPayload = t['payload'] != null;
        stdout.writeln('  track ${e.key}: $kills kill(s), '
            '$config config override(s), '
            '${hasPayload ? 'code payload' : 'no payload'}');
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

Uint8List _signBytes(Uint8List message, ECPrivateKey key) {
  // Deterministic k per RFC 6979 (HMAC-SHA256), which is what pointycastle's
  // ECDSASigner does when given a MAC. Deterministic signing means a rebuild of
  // the same body produces the same signature — handy for reproducible CI, and
  // it removes the catastrophic nonce-reuse failure mode entirely.
  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(true, PrivateKeyParameter<ECPrivateKey>(key));
  final sig = signer.generateSignature(message) as ECSignature;

  // Normalise s to the lower half. Not required for verification here, but it
  // keeps signatures canonical so the same body never yields two valid forms.
  final n = key.parameters!.n;
  final s = sig.s > (n >> 1) ? n - sig.s : sig.s;

  final out = Uint8List(64);
  _writeBigInt(sig.r, out, 0);
  _writeBigInt(s, out, 32);
  return out;
}

ECPrivateKey _loadPrivateKey(String path) {
  final text = File(path).readAsStringSync().trim();
  final hex = text.replaceAll(RegExp(r'\s'), '');
  if (hex.length != 64 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
    throw _ToolError(
      'private key file must contain 64 hex characters (got ${hex.length})',
    );
  }
  final d = BigInt.parse(hex, radix: 16);
  return ECPrivateKey(d, ECCurve_secp256r1());
}

SecureRandom _secureRandom() {
  final rnd = FortunaRandom();
  final seed = Uint8List(32);
  final r = Random.secure();
  for (var i = 0; i < seed.length; i++) {
    seed[i] = r.nextInt(256);
  }
  rnd.seed(KeyParameter(seed));
  return rnd;
}

String _sha256Hex(Uint8List data) {
  final d = SHA256Digest().process(data);
  final sb = StringBuffer();
  for (final b in d) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

void _writeBigInt(BigInt v, Uint8List out, int offset) {
  for (var i = 31; i >= 0; i--) {
    out[offset + i] = (v & BigInt.from(0xff)).toInt();
    v = v >> 8;
  }
}

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

Map<String, String> _flags(Iterable<String> args) {
  final out = <String, String>{};
  final list = args.toList();
  for (var i = 0; i < list.length; i++) {
    final a = list[i];
    if (!a.startsWith('--')) continue;
    final name = a.substring(2);
    if (i + 1 < list.length && !list[i + 1].startsWith('--')) {
      out[name] = list[++i];
    } else {
      out[name] = 'true';
    }
  }
  return out;
}

String _require(Map<String, String> flags, String name) {
  final v = flags[name];
  if (v == null || v.isEmpty) throw _ToolError('missing --$name');
  return v;
}

class _ToolError implements Exception {
  _ToolError(this.message);
  final String message;
}

void _usage() {
  stdout.writeln('''
Venera patch tool.

  keygen [--out <dir>]
      Generate a P-256 signing keypair. Prints the public key line to paste
      into lib/foundation/hot_update.dart.

  sign --key <file> --body <file> [--out <file>]
      Sign a manifest body, producing the {sig, body} envelope.

  manifest --spec <file> --key <file> [--out <file>]
      Build and sign a manifest from a spec, hashing each track's payload
      file. Spec fields: patchVersion (int, required), minApp, maxApp,
      tracks{<name>: {kills[], config{}, payload{file, url}}}.

  verify --manifest <file> --pub <base64>
      Verify exactly as the app does. Run this in CI before publishing: a
      manifest the app rejects looks identical to no manifest at all.
''');
}

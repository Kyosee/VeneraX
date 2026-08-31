import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:venera_patch/venera_patch.dart';

/// Signing side, mirroring what `tool/make_patch.dart` will do in CI.
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

  String get publicKeyB64 => base64Encode(_public.Q!.getEncoded(false));

  /// Produces the `{sig, body}` envelope the store expects.
  String envelope(String body) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(
        true,
        ParametersWithRandom(
          PrivateKeyParameter<ECPrivateKey>(_private),
          _random,
        ),
      );
    final sig =
        signer.generateSignature(Uint8List.fromList(utf8.encode(body)))
            as ECSignature;
    final out = Uint8List(64);
    out.setRange(0, 32, _pad(sig.r));
    out.setRange(32, 64, _pad(sig.s));
    return jsonEncode({'sig': base64Encode(out), 'body': body});
  }

  static Uint8List _pad(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0 && x > BigInt.zero; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }
}

String _body({
  required int patchVersion,
  String? minApp,
  String? maxApp,
  List<Map<String, Object?>> kills = const [],
  Map<String, Object?> config = const {},
}) {
  return jsonEncode({
    'schema': 1,
    'patchVersion': patchVersion,
    if (minApp != null) 'minApp': minApp,
    if (maxApp != null) 'maxApp': maxApp,
    'tracks': {
      'stable': {'kills': kills, 'config': config},
    },
  });
}

void main() {
  late Directory tmp;
  late _Signer signer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('venera_patch_store_');
    signer = _Signer();
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  PatchStore store({
    String appVersion = '2.2.12',
    int builtin = 0,
    Map<String, String> responses = const {},
  }) {
    return PatchStore(
      rootDir: tmp.path,
      publicKeyB64: signer.publicKeyB64,
      builtinPatchVersion: builtin,
      appVersion: appVersion,
      fetchText: (url) async {
        final body = responses[url];
        if (body == null) throw Exception('404 $url');
        return body;
      },
      fetchBytes: (url) async => throw Exception('no payload in these tests'),
    );
  }

  const url = 'https://example.test/manifest.json';

  group('manifest cache — the pre-network kill window', () {
    // This is the regression that a rules-only test suite missed: kill rules
    // that live only in memory are useless against the crash they exist to
    // stop. A startup crash beats the network check, and the next launch has
    // nothing to replay — so the device loops.
    test('an accepted manifest is cached for replay at next launch', () async {
      final body = _body(
        patchVersion: 5,
        kills: [
          {'id': 'translation', 'reason': 'native crash on some chips'},
        ],
      );
      final s = store(responses: {url: signer.envelope(body)});
      final res = await s.check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );
      expect(res.outcome, PatchFetchOutcome.configApplied);

      // A brand-new store, as if the app had restarted with no network.
      final reopened = store();
      final cached = await reopened.cachedManifest();
      expect(cached, isNotNull);
      expect(cached!.patchVersion, 5);
      expect(cached.tracks['stable']!.kills.single.id, 'translation');
    });

    test('cached rules survive with no network at all', () async {
      final body = _body(
        patchVersion: 7,
        kills: [
          {'id': 'webdav-startup-import', 'reason': 'startup race'},
        ],
      );
      await store(responses: {url: signer.envelope(body)}).check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );

      // Offline store: every fetch throws.
      final offline = store();
      final cached = await offline.cachedManifest();
      expect(cached, isNotNull);
      expect(
        cached!.tracks['stable']!.kills.single.id,
        'webdav-startup-import',
      );
    });

    test('config overrides are cached alongside kills', () async {
      final body = _body(
        patchVersion: 3,
        config: {'downloadThreads': 2},
      );
      await store(responses: {url: signer.envelope(body)}).check(
        manifestUrl: url,
        track: 'stable',
        platform: 'windows',
      );
      final cached = await store().cachedManifest();
      expect(cached!.tracks['stable']!.config['downloadThreads'], 2);
    });

    test('an already-installed version still refreshes the cache', () async {
      // Same patchVersion arriving twice must not lose the rules: the second
      // check returns upToDate, and an early `return` there would leave a
      // wiped cache unrepaired.
      final body = _body(
        patchVersion: 9,
        kills: [
          {'id': 'f', 'reason': 'r'},
        ],
      );
      final env = signer.envelope(body);
      await store(responses: {url: env}).check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );
      File('${tmp.path}/manifest.cache.json').deleteSync();

      final again = await store(responses: {url: env}).check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );
      expect(again.outcome, PatchFetchOutcome.configApplied);
      expect(await store().cachedManifest(), isNotNull);
    });
  });

  group('nothing unverified is ever cached', () {
    test('a forged signature leaves no cache', () async {
      final other = _Signer();
      final env = other.envelope(_body(patchVersion: 5));
      final res = await store(responses: {url: env}).check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );
      expect(res.outcome, PatchFetchOutcome.rejected);
      expect(await store().cachedManifest(), isNull);
    });

    test('a tampered body leaves no cache', () async {
      final env = jsonDecode(signer.envelope(_body(patchVersion: 5))) as Map;
      env['body'] = _body(patchVersion: 999);
      final res = await store(responses: {url: jsonEncode(env)}).check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );
      expect(res.outcome, PatchFetchOutcome.rejected);
      expect(await store().cachedManifest(), isNull);
    });

    test('an out-of-range app version leaves no cache', () async {
      // Ordering matters: the range test runs before caching, because a cached
      // body is replayed without re-validation. Anything we would reject now
      // must never reach disk.
      final body = _body(patchVersion: 5, minApp: '3.0.0');
      final res = await store(
        appVersion: '2.2.12',
        responses: {url: signer.envelope(body)},
      ).check(manifestUrl: url, track: 'stable', platform: 'android');
      expect(res.outcome, PatchFetchOutcome.rejected);
      expect(await store().cachedManifest(), isNull);
    });

    test('a version retired by the app build leaves no cache', () async {
      final body = _body(patchVersion: 4);
      final res = await store(
        builtin: 10,
        responses: {url: signer.envelope(body)},
      ).check(manifestUrl: url, track: 'stable', platform: 'android');
      expect(res.outcome, PatchFetchOutcome.upToDate);
      expect(await store().cachedManifest(), isNull);
    });

    test('an unreachable manifest leaves the existing cache intact', () async {
      final body = _body(
        patchVersion: 5,
        kills: [
          {'id': 'f', 'reason': 'r'},
        ],
      );
      await store(responses: {url: signer.envelope(body)}).check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );
      final res = await store().check(
        manifestUrl: url,
        track: 'stable',
        platform: 'android',
      );
      expect(res.outcome, PatchFetchOutcome.failed);
      // A network failure must not disable features that a valid manifest
      // enabled, nor drop rules a valid manifest imposed.
      expect(await store().cachedManifest(), isNotNull);
    });
  });

  group('rollback', () {
    test('resetToBuiltin clears the cache so rules stop applying', () async {
      final body = _body(
        patchVersion: 5,
        kills: [
          {'id': 'f', 'reason': 'r'},
        ],
      );
      final s = store(responses: {url: signer.envelope(body)});
      await s.check(manifestUrl: url, track: 'stable', platform: 'android');
      expect(await s.cachedManifest(), isNotNull);

      await s.resetToBuiltin();
      // Rolling back must undo the kills too. Leaving them in force would mean
      // the user's escape hatch silently keeps a feature disabled.
      expect(await s.cachedManifest(), isNull);
    });
  });

  group('a corrupt cache degrades, never throws', () {
    test('unparseable cache reads as "no rules"', () async {
      File('${tmp.path}/manifest.cache.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');
      // Null means "no rules", never "disable everything" — a wiped or corrupt
      // cache must not take features down.
      expect(await store().cachedManifest(), isNull);
    });

    test('missing cache reads as "no rules"', () async {
      expect(await store().cachedManifest(), isNull);
    });
  });
}

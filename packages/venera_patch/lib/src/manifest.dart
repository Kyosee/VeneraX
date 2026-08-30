import 'dart:convert';

/// Parsed patch manifest.
///
/// Wire format is a signed envelope:
///
/// ```json
/// { "sig": "<base64 r||s>", "body": "<exact JSON string that was signed>" }
/// ```
///
/// The signature covers the *literal bytes* of `body`, and `body` is parsed
/// only after the signature verifies. Signing a re-serialised object instead
/// would require canonical JSON, and disagreements between the signer's and
/// verifier's canonicalisation are a well-worn signature-bypass class. Keeping
/// the signed text verbatim removes that whole category.
class PatchManifest {
  const PatchManifest({
    required this.schema,
    required this.patchVersion,
    required this.minApp,
    required this.maxApp,
    required this.tracks,
  });

  /// Wire-format version. An unknown (newer) schema is refused rather than
  /// best-effort parsed, so a future field can never be silently ignored.
  final int schema;

  /// Monotonic counter, compared numerically — never by timestamp.
  ///
  /// The app carries a built-in floor (`kBuiltinPatchVersion`); a manifest at
  /// or below it is ignored, which is what makes a full release automatically
  /// retire every patch built for older versions. Same invariant as the WebDAV
  /// `dataVersion` rule, for the same reason: timestamps disagree across
  /// devices and clocks move backwards.
  final int patchVersion;

  final String? minApp;
  final String? maxApp;

  final Map<String, PatchTrack> tracks;

  static const int supportedSchema = 1;

  /// Verified-then-parsed constructor. [body] must already have passed
  /// signature verification.
  static PatchManifest parse(String body) {
    final json = jsonDecode(body);
    if (json is! Map) {
      throw const FormatException('manifest body is not an object');
    }
    final schema = _asInt(json['schema']);
    if (schema != supportedSchema) {
      throw FormatException('unsupported manifest schema $schema');
    }
    final rawTracks = json['tracks'];
    final tracks = <String, PatchTrack>{};
    if (rawTracks is Map) {
      for (final entry in rawTracks.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        tracks[entry.key.toString()] = PatchTrack._parse(
          Map<String, dynamic>.from(value),
        );
      }
    }
    return PatchManifest(
      schema: schema,
      patchVersion: _asInt(json['patchVersion']),
      minApp: json['minApp']?.toString(),
      maxApp: json['maxApp']?.toString(),
      tracks: tracks,
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

/// One release channel. `staging` is verified locally, `beta` by a wider
/// group, `stable` reaches everyone. A patch never skips straight to stable,
/// however urgent the bug — an unverified emergency patch can make things
/// strictly worse than the bug it fixes.
class PatchTrack {
  const PatchTrack({
    required this.kills,
    required this.config,
    required this.payload,
    this.notes = const {},
  });

  final List<KillRule> kills;

  /// L0 overlay: flat dotted keys to JSON-encodable values.
  final Map<String, Object?> config;

  /// Code payload descriptor, absent for a config/kill-only manifest.
  final PatchPayload? payload;

  /// What changed, by locale tag, for the notice shown after a fix installs.
  ///
  /// Keyed by locale (`zh_CN`, `en`, …) rather than being a single string,
  /// because it is user-facing text and the app is used in several languages;
  /// a fix that explains itself only in English is a fix most users cannot
  /// read. Absent, empty or unmatched falls back to a generic message rather
  /// than showing nothing — a change the user cannot see explained reads as
  /// unexplained behaviour drift.
  final Map<String, String> notes;

  /// Note text for [locale], falling back to English, then any entry present.
  ///
  /// Locale matching is exact first (`zh_CN`), then by language (`zh`), so a
  /// manifest written for `zh_CN` still reaches a `zh_TW` reader rather than
  /// silently degrading to English.
  String? noteFor(String locale) {
    if (notes.isEmpty) return null;
    final exact = notes[locale];
    if (exact != null && exact.isNotEmpty) return exact;
    final language = locale.split(RegExp('[_-]')).first;
    for (final entry in notes.entries) {
      if (entry.key.split(RegExp('[_-]')).first == language &&
          entry.value.isNotEmpty) {
        return entry.value;
      }
    }
    final english = notes['en'];
    if (english != null && english.isNotEmpty) return english;
    for (final value in notes.values) {
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static PatchTrack _parse(Map<String, dynamic> json) {
    final kills = <KillRule>[];
    final rawKills = json['kills'];
    if (rawKills is List) {
      for (final k in rawKills) {
        if (k is Map) {
          final rule = KillRule._parse(Map<String, dynamic>.from(k));
          if (rule != null) kills.add(rule);
        }
      }
    }
    final config = <String, Object?>{};
    final rawConfig = json['config'];
    if (rawConfig is Map) {
      for (final e in rawConfig.entries) {
        config[e.key.toString()] = e.value;
      }
    }
    final notes = <String, String>{};
    final rawNotes = json['notes'];
    if (rawNotes is Map) {
      for (final e in rawNotes.entries) {
        final value = e.value?.toString();
        if (value != null && value.isNotEmpty) {
          notes[e.key.toString()] = value;
        }
      }
    } else if (rawNotes is String && rawNotes.isNotEmpty) {
      // A bare string is accepted as the English note, so a hand-written
      // manifest for a quick fix does not need the locale map. Rejecting it
      // would make the common case the awkward one.
      notes['en'] = rawNotes;
    }
    final rawPayload = json['payload'];
    return PatchTrack(
      kills: kills,
      config: config,
      notes: notes,
      payload: rawPayload is Map
          ? PatchPayload._parse(Map<String, dynamic>.from(rawPayload))
          : null,
    );
  }
}

/// A remote circuit breaker.
///
/// This is the one mechanism that can mitigate a *native* crash: we can never
/// patch a `.so`, but we can stop the app from reaching the code that trips it.
/// The user goes from "crashes on launch" to "this feature is unavailable",
/// which is a bigger practical win than most code fixes.
class KillRule {
  const KillRule({
    required this.id,
    required this.platforms,
    required this.abis,
    required this.appVersions,
    required this.reason,
  });

  /// Feature id, matched against the string passed to `Patch.isEnabled`.
  final String id;

  /// Empty means "every platform". Values match `Platform.operatingSystem`.
  final List<String> platforms;

  /// Empty means "every ABI". Lets a rule target exactly the chips that trip a
  /// native fault (e.g. the SME1-without-SME2 parts behind the ORT SIGILL)
  /// instead of disabling the feature fleet-wide.
  final List<String> abis;

  /// Empty means "every version".
  final List<String> appVersions;

  /// Shown to the user in place of the disabled feature.
  final String reason;

  bool matches({
    required String platform,
    required String? abi,
    required String appVersion,
  }) {
    if (platforms.isNotEmpty && !platforms.contains(platform)) return false;
    if (abis.isNotEmpty && (abi == null || !abis.contains(abi))) return false;
    if (appVersions.isNotEmpty && !appVersions.contains(appVersion)) {
      return false;
    }
    return true;
  }

  static KillRule? _parse(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) return null;
    return KillRule(
      id: id,
      platforms: _strList(json['platforms']),
      abis: _strList(json['abis']),
      appVersions: _strList(json['appVersions']),
      reason: json['reason']?.toString() ?? '',
    );
  }

  static List<String> _strList(Object? v) {
    if (v is! List) return const [];
    return v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
  }
}

/// Where the code/asset bundle lives and how to validate it.
class PatchPayload {
  const PatchPayload({
    required this.url,
    required this.sha256,
    required this.size,
  });

  final String url;

  /// Lowercase hex. Checked before the bundle is opened — authenticity comes
  /// from the manifest signature, integrity from this digest.
  final String sha256;

  final int size;

  static PatchPayload? _parse(Map<String, dynamic> json) {
    final url = json['url']?.toString();
    final sha = json['sha256']?.toString();
    if (url == null || url.isEmpty || sha == null || sha.isEmpty) return null;
    return PatchPayload(
      url: url,
      sha256: sha.toLowerCase(),
      size: PatchManifest._asInt(json['size']),
    );
  }
}

/// The signed envelope, split before verification.
class PatchEnvelope {
  const PatchEnvelope({required this.body, required this.signatureB64});

  final String body;
  final String signatureB64;

  static PatchEnvelope parse(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map) {
      throw const FormatException('envelope is not an object');
    }
    final body = json['body'];
    final sig = json['sig'];
    if (body is! String || body.isEmpty) {
      throw const FormatException('envelope.body missing');
    }
    if (sig is! String || sig.isEmpty) {
      throw const FormatException('envelope.sig missing');
    }
    return PatchEnvelope(body: body, signatureB64: sig);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'manifest.dart';
import 'signature.dart';
import 'slot.dart';

/// Fetches a URL as text. Injected by the host rather than created here.
///
/// This package must never construct its own HTTP client: a bare `Dio` uses the
/// default `dart:io` adapter, which ignores the user's proxy setting and does
/// not read the system certificate store. Every request has to go through the
/// app's configured client, so the host passes one in.
typedef TextFetcher = Future<String> Function(String url);

/// Fetches a URL as bytes, same rationale as [TextFetcher].
typedef BytesFetcher = Future<List<int>> Function(String url);

/// Result of a check-and-download cycle.
enum PatchFetchOutcome {
  /// No manifest, or nothing newer than what is installed.
  upToDate,

  /// Manifest applied; it carried only kills/config, no code payload.
  configApplied,

  /// A code bundle was downloaded and staged for the next launch.
  staged,

  /// Manifest was rejected (bad signature, unsupported schema, version out of
  /// range, banned version, digest mismatch).
  rejected,

  /// Network or disk failure. Distinct from [rejected]: a transient failure
  /// should be retried, a rejection should not.
  failed,
}

class PatchCheckResult {
  const PatchCheckResult(this.outcome, {this.manifest, this.detail});

  final PatchFetchOutcome outcome;
  final PatchManifest? manifest;
  final String? detail;
}

/// On-disk patch state and the GitHub-backed fetch cycle.
///
/// Distribution uses a dedicated `patch` branch read through
/// raw.githubusercontent.com, not the GitHub API: unauthenticated API calls are
/// capped at 60/hour, while raw is CDN-served. No API token ships in the app.
class PatchStore {
  PatchStore({
    required this.rootDir,
    required this.publicKeyB64,
    required this.builtinPatchVersion,
    required this.appVersion,
    required this.fetchText,
    required this.fetchBytes,
    this.mirrors = const [],
  });

  /// Directory holding `state.json` and one subdirectory per installed patch.
  final String rootDir;

  /// SEC1 uncompressed P-256 point, base64. Compiled into the app.
  final String publicKeyB64;

  /// Version floor shipped with this build. A manifest at or below it is
  /// ignored, so a full release automatically retires patches built for older
  /// versions — no server-side bookkeeping required.
  final int builtinPatchVersion;

  final String appVersion;

  final TextFetcher fetchText;
  final BytesFetcher fetchBytes;

  /// Fallback manifest URLs, tried in order after the primary fails.
  final List<String> mirrors;

  PatchSlots _slots = PatchSlots();
  bool _loaded = false;

  PatchSlots get slots => _slots;

  String get _statePath => p.join(rootDir, 'state.json');

  /// Last signature-verified manifest body, kept verbatim.
  ///
  /// Kill rules have to be in force *before* the subsystem they protect gets a
  /// chance to run, and a network check cannot meet that deadline: it finishes
  /// seconds after launch, and a startup crash beats it outright — leaving the
  /// device in the crash loop the kill switch exists to break. So the manifest
  /// is cached on disk and replayed at launch.
  String get _manifestCachePath => p.join(rootDir, 'manifest.cache.json');

  String patchDir(PatchSlotEntry entry) => p.join(rootDir, entry.dirName);

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = File(_statePath);
      if (await f.exists()) {
        _slots = PatchSlots.fromJson(await f.readAsString());
      }
    } catch (_) {
      // A corrupt state file must not brick patching: fall back to "nothing
      // installed" rather than throwing on every launch.
      _slots = PatchSlots();
    }
  }

  Future<void> _saveState() async {
    final dir = Directory(rootDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // Atomic replace. A kill mid-write would otherwise truncate state.json, and
    // the load path resets a corrupt file — silently discarding the record of
    // which patches are installed while their directories stay on disk.
    final tmp = File('$_statePath.tmp');
    await tmp.writeAsString(jsonEncode(_slots.toJson()), flush: true);
    await tmp.rename(_statePath);
  }

  /// Replays the last verified manifest from disk.
  ///
  /// No re-verification: the file was written by us, only after its signature
  /// passed, into the app's private directory. Re-checking here would mean
  /// shipping the verified body *and* trusting the local copy anyway — the
  /// signature's job is to authenticate what arrives over the network, and it
  /// already did that.
  ///
  /// Returns null when nothing is cached or the cache is unreadable. Callers
  /// must treat that as "no rules", never as "disable everything": a wiped
  /// cache must not take features down.
  Future<PatchManifest?> cachedManifest() async {
    try {
      final f = File(_manifestCachePath);
      if (!await f.exists()) return null;
      return PatchManifest.parse(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _cacheManifest(String body) async {
    try {
      final dir = Directory(rootDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final tmp = File('$_manifestCachePath.tmp');
      await tmp.writeAsString(body, flush: true);
      await tmp.rename(_manifestCachePath);
    } catch (_) {
      // A failed cache write costs us the pre-network kill window on the next
      // launch, which is bad — but failing the whole check over it is worse.
    }
  }

  Future<void> _clearManifestCache() async {
    try {
      final f = File(_manifestCachePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Resolves what to load this launch, applying rollback when the previous
  /// launch never reported success. Call before handing anything to the VM.
  Future<PatchSlotEntry?> beginLaunch() async {
    await load();
    if (_slots.shouldRollBack) {
      final bad = _slots.rollBack();
      if (bad != null) {
        await _deleteEntry(bad);
      }
      await _saveState();
      return _slots.pending;
    }
    final pending = _slots.pending;
    if (pending != null) {
      _slots.markLaunchStarted();
      await _saveState();
    }
    return pending;
  }

  /// Called once the app is healthy. Promotes the unproven patch and deletes the
  /// one it replaced.
  Future<void> confirmLaunch() async {
    await load();
    final retired = _slots.markLaunchSucceeded();
    if (retired != null) {
      await _deleteEntry(retired);
    }
    await _saveState();
  }

  /// Discards everything and returns to the built-in implementation. Wired to
  /// the user-facing "roll back to built-in version" action.
  ///
  /// Clearing the manifest cache is part of "everything": leaving it behind
  /// would let the next launch replay the kill rules the user just rolled back,
  /// so features would stay disabled with no patch left to explain why.
  Future<void> resetToBuiltin() async {
    await load();
    for (final e in [_slots.current, _slots.next]) {
      if (e != null) await _deleteEntry(e);
    }
    _slots = PatchSlots(disabledVersions: _slots.disabledVersions);
    await _saveState();
    await _clearManifestCache();
  }

  Future<void> _deleteEntry(PatchSlotEntry entry) async {
    try {
      final d = Directory(patchDir(entry));
      if (await d.exists()) {
        await d.delete(recursive: true);
      }
    } catch (_) {
      // Leaving a stale directory behind is harmless; failing the launch over
      // it is not.
    }
  }

  /// Fetches and validates the manifest, then downloads a code bundle if the
  /// selected track carries one.
  Future<PatchCheckResult> check({
    required String manifestUrl,
    required String track,
    required String platform,
    String? abi,
  }) async {
    await load();

    String? raw;
    for (final url in [manifestUrl, ...mirrors]) {
      try {
        raw = await fetchText(url);
        if (raw.trim().isNotEmpty) break;
      } catch (_) {
        continue;
      }
    }
    if (raw == null || raw.trim().isEmpty) {
      return const PatchCheckResult(
        PatchFetchOutcome.failed,
        detail: 'manifest unreachable',
      );
    }

    final PatchEnvelope envelope;
    try {
      envelope = PatchEnvelope.parse(raw);
    } catch (e) {
      return PatchCheckResult(
        PatchFetchOutcome.rejected,
        detail: 'malformed envelope: $e',
      );
    }

    // Signature first, on the literal signed bytes. Nothing inside `body` is
    // trusted — or even parsed — until this passes.
    if (!PatchSignature.verifyBase64(
      message: envelope.body,
      signatureB64: envelope.signatureB64,
      publicKeyB64: publicKeyB64,
    )) {
      return const PatchCheckResult(
        PatchFetchOutcome.rejected,
        detail: 'signature verification failed',
      );
    }

    final PatchManifest manifest;
    try {
      manifest = PatchManifest.parse(envelope.body);
    } catch (e) {
      return PatchCheckResult(
        PatchFetchOutcome.rejected,
        detail: 'manifest parse failed: $e',
      );
    }

    if (manifest.patchVersion <= builtinPatchVersion) {
      return PatchCheckResult(
        PatchFetchOutcome.upToDate,
        manifest: manifest,
        detail: 'retired by app build',
      );
    }
    if (_slots.isDisabled(manifest.patchVersion)) {
      return PatchCheckResult(
        PatchFetchOutcome.rejected,
        manifest: manifest,
        detail: 'version banned after failed launch',
      );
    }
    // Range-checked before the "already installed" test so an out-of-range
    // manifest is never cached — a cached body is replayed at every launch
    // without re-validation, so anything we would reject now must not be
    // written.
    if (!_appVersionInRange(manifest)) {
      return PatchCheckResult(
        PatchFetchOutcome.rejected,
        manifest: manifest,
        detail: 'app version $appVersion out of range',
      );
    }

    // The manifest is authentic and applicable to this build: persist it now,
    // before deciding whether a payload needs downloading. Every path below
    // this line is an accept, and the kills/config the body carries have to
    // survive a restart to be worth anything.
    await _cacheManifest(envelope.body);

    if (manifest.patchVersion <= _slots.highestVersion) {
      return PatchCheckResult(
        PatchFetchOutcome.upToDate,
        manifest: manifest,
      );
    }

    final selected = manifest.tracks[track];
    if (selected == null) {
      return PatchCheckResult(
        PatchFetchOutcome.upToDate,
        manifest: manifest,
        detail: 'no entry for track $track',
      );
    }

    final payload = selected.payload;
    if (payload == null) {
      // Kills and config need no download and take effect immediately.
      return PatchCheckResult(
        PatchFetchOutcome.configApplied,
        manifest: manifest,
      );
    }

    try {
      final fetched = await fetchBytes(payload.url);
      final data = fetched is Uint8List
          ? fetched
          : Uint8List.fromList(fetched);
      final actual = PatchSignature.sha256Hex(data);
      if (actual != payload.sha256) {
        return PatchCheckResult(
          PatchFetchOutcome.rejected,
          manifest: manifest,
          detail: 'digest mismatch',
        );
      }
      final dirName = 'p${manifest.patchVersion}';
      final dir = Directory(p.join(rootDir, dirName));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      await dir.create(recursive: true);
      await File(
        p.join(dir.path, 'bundle.vpatch'),
      ).writeAsBytes(data, flush: true);

      final displaced = _slots.stage(
        PatchSlotEntry(
          patchVersion: manifest.patchVersion,
          track: track,
          dirName: dirName,
          sha256: payload.sha256,
        ),
      );
      if (displaced != null) await _deleteEntry(displaced);
      await _saveState();
      return PatchCheckResult(PatchFetchOutcome.staged, manifest: manifest);
    } catch (e) {
      return PatchCheckResult(
        PatchFetchOutcome.failed,
        manifest: manifest,
        detail: 'payload download failed: $e',
      );
    }
  }

  bool _appVersionInRange(PatchManifest m) {
    final min = m.minApp;
    final max = m.maxApp;
    if (min != null && min.isNotEmpty && compareVersions(appVersion, min) < 0) {
      return false;
    }
    if (max != null && max.isNotEmpty && compareVersions(appVersion, max) > 0) {
      return false;
    }
    return true;
  }
}

/// Numeric dotted-version comparison. Returns <0, 0, >0.
///
/// Missing components count as zero, so `2.2` equals `2.2.0`. Non-numeric
/// suffixes (`2.2.12-beta.1`) compare by their numeric prefix; a build-metadata
/// suffix must not make a version look newer than the release it precedes.
int compareVersions(String a, String b) {
  final pa = _parts(a);
  final pb = _parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

List<int> _parts(String v) {
  final out = <int>[];
  for (final seg in v.split('.')) {
    final m = RegExp(r'^\d+').firstMatch(seg.trim());
    out.add(m == null ? 0 : int.parse(m.group(0)!));
  }
  return out;
}

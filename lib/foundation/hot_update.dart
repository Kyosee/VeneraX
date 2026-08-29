import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;

import 'package:flutter/foundation.dart';
import 'package:venera_patch/venera_patch.dart';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/io.dart';

export 'package:venera_patch/venera_patch.dart'
    show KillSwitches, ConfigOverlay, PatchFetchOutcome;

/// Distribution root: a dedicated `patch` branch read through raw
/// githubusercontent. Not the GitHub API — unauthenticated API calls are capped
/// at 60/hour while raw is CDN-served, and no token ships in the app.
const _kPatchOwner = 'Kyosee';
const _kPatchRepo = 'VeneraX';
const _kPatchBranch = 'patch';

/// Version floor compiled into this build. Bumped on every release so a full
/// update automatically retires every patch built for an older app — the same
/// numeric-version invariant the WebDAV sync uses, for the same reason.
const int kBuiltinPatchVersion = 0;

/// Signing key for patch manifests. Empty until the release keypair is
/// generated; while empty, verification always fails and no patch can load.
/// That is the intended fail-closed default: an unsigned build must not accept
/// unsigned patches.
const String kPatchPublicKeyB64 = '';

/// Host-side wiring for the hot-update runtime.
///
/// The `venera_patch` package deliberately knows nothing about the app: it takes
/// its HTTP access by injection. That is not tidiness — a bare `Dio` uses the
/// default `dart:io` adapter, which ignores the user's proxy setting and never
/// reads the system certificate store, so patch fetches would be the one
/// network path in the app that silently disobeys its own settings.
class HotUpdate {
  HotUpdate._();

  static final HotUpdate instance = HotUpdate._();

  PatchStore? _store;
  bool _confirmScheduled = false;

  /// Whether hot-update is compiled in and usable at all.
  ///
  /// Release-only, mirroring Shorebird: in debug the developer's own source is
  /// the truth, and a stale patch shadowing an edited function produces the
  /// "I changed the code and nothing happened" confusion that costs an hour
  /// every time it happens.
  static bool get isSupported =>
      kReleaseMode && !App.isWeb && kPatchPublicKeyB64.isNotEmpty;

  /// User-facing master switch. Off means: load nothing, fetch nothing.
  bool get isEnabled =>
      isSupported && appdata.settings['enableHotUpdate'] != false;

  String get _track =>
      appdata.settings['hotUpdateTrack']?.toString() ?? 'stable';

  String get manifestUrl =>
      'https://raw.githubusercontent.com/$_kPatchOwner/$_kPatchRepo'
      '/$_kPatchBranch/manifest.json';

  /// jsDelivr serves the same branch and is reachable where raw is not. Content
  /// authenticity does not depend on the transport — the signature does — so an
  /// extra mirror costs nothing in trust.
  List<String> get _mirrors => [
    'https://cdn.jsdelivr.net/gh/$_kPatchOwner/$_kPatchRepo@$_kPatchBranch/manifest.json',
  ];

  String get _rootDir => FilePath.join(App.dataPath, 'patches');

  /// Resolves state for this launch and applies whatever is already on disk.
  ///
  /// Runs early (before heavy init) so a kill rule can take effect *before* the
  /// subsystem it disables gets a chance to crash. That ordering is the whole
  /// point of the kill switch: mitigating a native fault means not reaching it.
  Future<void> beginLaunch() async {
    KillSwitches.instance.configureDevice(
      platform: App.isWeb ? 'web' : Platform.operatingSystem,
      abi: _abi(),
      appVersion: App.version,
    );
    if (!isEnabled) {
      // Leave the registry inert. `PatchRegistry.active` stays false, so every
      // generated seam short-circuits on a static bool read.
      return;
    }
    try {
      final store = _ensureStore();
      // Cached kills/config first, before the slot bookkeeping and before any
      // subsystem initialises. This is the earliest point in the process where
      // a rule can still prevent the crash it was published to prevent.
      await _applyCachedManifest(store);
      final entry = await store.beginLaunch();
      await _applyLocal(entry);
    } catch (e, s) {
      Log.error('HotUpdate', 'beginLaunch failed: $e\n$s');
    }
  }

  /// Marks this launch healthy. Must be called only once the app is genuinely
  /// usable, not merely past `main()` — the boot marker it clears is the sole
  /// signal distinguishing a working patch from one that crashes on startup.
  void confirmLaunchSucceeded() {
    if (!isEnabled || _confirmScheduled) return;
    _confirmScheduled = true;
    Future.delayed(const Duration(seconds: 10), () async {
      try {
        await _store?.confirmLaunch();
      } catch (e) {
        Log.error('HotUpdate', 'confirmLaunch failed: $e');
      }
    });
  }

  /// Checks the remote manifest. Kills and config apply immediately; a code
  /// bundle is staged for the next launch.
  Future<PatchFetchOutcome> check() async {
    if (!isEnabled) return PatchFetchOutcome.upToDate;
    try {
      final store = _ensureStore();
      final result = await store.check(
        manifestUrl: manifestUrl,
        track: _track,
        platform: Platform.operatingSystem,
        abi: _abi(),
      );
      final manifest = result.manifest;
      if (manifest != null) {
        final track = manifest.tracks[_track];
        if (track != null) {
          KillSwitches.instance.apply(track.kills);
          ConfigOverlay.instance.apply(track.config);
        }
      }
      if (result.detail != null) {
        Log.info('HotUpdate', '${result.outcome.name}: ${result.detail}');
      }
      return result.outcome;
    } catch (e, s) {
      Log.error('HotUpdate', 'check failed: $e\n$s');
      return PatchFetchOutcome.failed;
    }
  }

  /// Discards every patch and returns to the built-in implementation. Wired to
  /// the user-facing rollback action, which exists so a user hitting a bad
  /// patch is never stuck waiting for us to publish a fix.
  Future<void> resetToBuiltin() async {
    try {
      await _ensureStore().resetToBuiltin();
    } catch (e) {
      Log.error('HotUpdate', 'reset failed: $e');
    }
    PatchRegistry.clear();
    KillSwitches.instance.clear();
    ConfigOverlay.instance.clear();
  }

  /// Replays the last verified manifest from disk.
  ///
  /// This is what makes the kill switch actually work. A rule has to be in
  /// force *before* the subsystem it protects runs, and the network check
  /// cannot meet that deadline: it lands seconds into the session, and a
  /// startup crash beats it outright — which is precisely the crash loop the
  /// kill switch exists to break (a device that dies during startup auto-import
  /// would never reach the check, so the rule would never apply).
  Future<void> _applyCachedManifest(PatchStore store) async {
    final manifest = await store.cachedManifest();
    if (manifest == null) return;
    // A manifest retired by this build must not be replayed: after a full
    // update, its kill rules describe a version that no longer exists.
    if (manifest.patchVersion <= kBuiltinPatchVersion) return;
    final track = manifest.tracks[_track];
    if (track == null) return;
    KillSwitches.instance.apply(track.kills);
    ConfigOverlay.instance.apply(track.config);
  }

  /// Loads the code overrides carried by an installed bundle.
  ///
  /// Failure here is deliberately quiet: the app keeps running its built-in
  /// implementations. A patch that cannot load is a patch that does nothing,
  /// which is the correct outcome — the alternative is refusing to start.
  Future<void> _applyLocal(PatchSlotEntry? entry) async {
    if (entry == null) return;
    try {
      final file = File(
        FilePath.join(_ensureStore().patchDir(entry), 'bundle.vpatch'),
      );
      if (!await file.exists()) return;
      final bytes = await file.readAsBytes();

      // Re-check the digest recorded when the bundle was staged. The signature
      // authenticated it on arrival; this catches storage corruption since —
      // a truncated file would otherwise reach the loader as a malformed
      // payload and read as a tooling bug rather than a damaged download.
      final digest = PatchSignature.sha256Hex(bytes);
      if (digest != entry.sha256) {
        Log.error('HotUpdate', 'bundle digest mismatch; ignoring patch');
        return;
      }

      final program = VirLoader(host: _hostBridge()).loadJson(
        utf8.decode(bytes),
      );
      final table = VmOverrideBinder.bind(program);
      if (table.isEmpty) return;

      PatchRegistry.onOverrideFailed = (id, error) {
        Log.error('HotUpdate', 'override #$id quarantined: $error');
      };
      PatchRegistry.installOverrides(table);
      Log.info(
        'HotUpdate',
        'patch v${entry.patchVersion} active (${table.length} override(s))',
      );
    } catch (e, s) {
      // Includes PatchLoadFault: a payload built against a different surface
      // than this binary. Falling back to built-in behaviour is right, and the
      // dual-slot rollback handles the case where it keeps happening.
      Log.error('HotUpdate', 'patch load failed: $e\n$s');
      PatchRegistry.clear();
    }
  }

  /// The sandbox boundary handed to the interpreter.
  ///
  /// Core `dart:core` bindings only, for now. Stage 3 layers the app's own
  /// generated surface on top via [LayeredHostBridge]; until then a patch can
  /// reach exactly what [CoreBindings] exposes and nothing else.
  HostBridge _hostBridge() => const CoreBindings();

  PatchStore _ensureStore() {
    return _store ??= PatchStore(
      rootDir: _rootDir,
      publicKeyB64: kPatchPublicKeyB64,
      builtinPatchVersion: kBuiltinPatchVersion,
      appVersion: App.version,
      fetchText: _fetchText,
      fetchBytes: _fetchBytes,
      mirrors: _mirrors,
    );
  }

  static Future<String> _fetchText(String url) async {
    final res = await AppDio().get<String>(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return res.data ?? '';
  }

  static Future<List<int>> _fetchBytes(String url) async {
    final res = await AppDio().get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    return res.data ?? const [];
  }

  /// Native ABI, used to scope a kill rule to exactly the chips that trip a
  /// native fault. Without it, the only remedy for something like the ORT
  /// SME2 illegal-instruction crash would be disabling translation for every
  /// Android user rather than the affected parts.
  String? _abi() {
    if (App.isWeb) return null;
    return switch (Abi.current()) {
      Abi.androidArm64 => 'arm64-v8a',
      Abi.androidArm => 'armeabi-v7a',
      Abi.androidX64 => 'x86_64',
      Abi.iosArm64 => 'ios-arm64',
      Abi.macosArm64 => 'macos-arm64',
      Abi.macosX64 => 'macos-x64',
      Abi.windowsX64 => 'windows-x64',
      Abi.windowsArm64 => 'windows-arm64',
      Abi.linuxX64 => 'linux-x64',
      Abi.linuxArm64 => 'linux-arm64',
      _ => null,
    };
  }
}

/// Reads a setting through the config overlay.
///
/// A patch can retune a threshold, a URL, or a default without shipping code —
/// the cheapest possible fix, and the only one that needs no interpreter.
/// Falls through to the stored setting whenever no override is present.
T? patchedSetting<T>(String key) {
  final overlay = ConfigOverlay.instance;
  if (overlay.has(key)) {
    final v = overlay.typed<T>(key);
    if (v != null) return v;
  }
  final raw = appdata.settings[key];
  return raw is T ? raw : null;
}

/// Whether a feature is allowed to run on this device.
///
/// Guard the *entry point* of anything that can take the process down —
/// on-device inference, archive extraction, startup auto-import. This is the
/// only mechanism in the whole design that can mitigate a native crash: we can
/// never patch a `.so`, but we can stop the app from reaching it. "This feature
/// is temporarily unavailable" beats "crashes on launch" by a wide margin.
bool isFeatureEnabled(String featureId) =>
    KillSwitches.instance.isEnabled(featureId);

/// Why [featureId] is disabled, for display in place of the feature. Null when
/// it is enabled.
String? featureDisabledReason(String featureId) =>
    KillSwitches.instance.reasonFor(featureId);

import 'package:venera_patch/venera_patch.dart';

/// Feature ids the app checks against remotely-published kill rules.
///
/// A kill switch is the only tool that helps with a fault *below* Dart. A crash
/// inside a `.so` can never be patched — the defect is compiled ARM, and the
/// patch runtime is an interpreter for Dart — but the code path that reaches it
/// can be closed remotely. The user goes from "crashes the moment I open this"
/// to "this feature is unavailable", which is the difference between an app
/// that cannot be used and one that is missing a feature.
///
/// Two entries in this repo's history are exactly that shape:
///
/// * **#169** — `onnxruntime-android 1.23.0` dispatches SME2 kernels after
///   checking only for SME1, so OCR raises `SIGILL` on chips that report SME
///   without usable SME2. The dispatch happens once at library init, with no
///   `getenv` to steer it, so by the time any Dart runs the choice is already
///   made. Fixing it meant pinning the dependency and rebuilding. Closing
///   translation on the affected ABI does not.
/// * **zip `openAndExtract`** — a double free that aborted in `libmalloc`,
///   surfacing as unrelated crashes wherever the corrupted heap was next
///   touched. Its blast radius covered sync, download and import.
///
/// ## Ids are a published contract
///
/// A rule names a feature by this string, and rules outlive the build that
/// created them: a device on an older version keeps applying a manifest written
/// for a newer one. So **never rename an id and never repurpose one** — a
/// renamed id silently stops matching, which reads as "the kill switch didn't
/// work" during exactly the incident it was published for.
///
/// ## Granularity
///
/// Each id names a *user-visible capability*, not an internal function. The
/// author of a rule is choosing what to take away from a user mid-incident, and
/// that decision is only meaningful in those terms.
abstract final class KillIds {
  /// On-device OCR and image translation. The #169 SIGILL site.
  static const imageTranslation = 'imageTranslation';

  /// Automatic WebDAV upload/download. Leaves manual sync reachable, so a user
  /// can still get their data off a device whose automatic path is broken.
  static const webdavAutoSync = 'webdavAutoSync';

  /// Applying a downloaded backup at startup. Its own crash denies the user
  /// every later launch, so it is worth being able to close on its own.
  static const webdavStartupImport = 'webdavStartupImport';

  /// Archive extraction: `.cbz` import, downloaded archives, WebDAV image
  /// bundles. The zip double-free site.
  static const archiveExtract = 'archiveExtract';

  /// Background download execution. Distinct from browsing what is already
  /// downloaded, which stays available.
  static const downloads = 'downloads';

  // Deliberately absent: on-device LLM inference (`venera_llama`). The package
  // has no reference anywhere in `lib/`, so publishing an id for it would
  // advertise a switch that controls nothing — and a rule that appears to take
  // effect while changing nothing is worse than no switch at all, because it
  // ends the search for the real cause.

  /// Every id above, for the diagnostics screen and for tests that assert the
  /// published set does not drift.
  static const List<String> all = [
    imageTranslation,
    webdavAutoSync,
    webdavStartupImport,
    archiveExtract,
    downloads,
  ];
}

/// Whether [featureId] may run.
///
/// Defaults to enabled: a missing, unreachable or unparseable manifest must
/// never disable anything. The failure mode of getting that backwards is an app
/// that silently loses features because a CDN had a bad day.
bool featureEnabled(String featureId) =>
    KillSwitches.instance.isEnabled(featureId);

/// Why [featureId] is unavailable, for display. Null when it is enabled.
///
/// Rules carry a reason so the UI can say *something* rather than failing
/// mutely — a feature that vanishes with no explanation reads as a bug, and
/// generates the support traffic the kill switch was meant to avoid.
String? featureDisabledReason(String featureId) =>
    KillSwitches.instance.reasonFor(featureId);

/// Config keys a patch may override without a release.
///
/// These shadow *defaults* only — a value the user has explicitly chosen always
/// wins, and dropping the overlay restores built-in behaviour exactly. That
/// distinction is what makes remote tuning safe: it can correct a bad default,
/// never overwrite a user's decision.
///
/// Same permanence rule as [KillIds]: these strings are a published contract.
abstract final class ConfigKeys {
  /// Concurrent download slots. The most commonly mistuned value in the app,
  /// and the one most likely to need a per-fleet correction.
  static const downloadThreads = 'downloadThreads';

  /// OCR worker pool size. Too high oversubscribes the CPU and makes
  /// translation slower rather than faster; the right value is device-shaped.
  static const ocrWorkers = 'ocrWorkers';

  /// Seconds before an image request is abandoned.
  static const imageTimeoutSeconds = 'imageTimeoutSeconds';

  /// Backups retained per platform on the WebDAV server.
  static const backupRetention = 'backupRetention';

  static const List<String> all = [
    downloadThreads,
    ocrWorkers,
    imageTimeoutSeconds,
    backupRetention,
  ];
}

/// Built-in defaults for the overridable keys, as shipped in [Settings].
///
/// Duplicated from `appdata.dart` on purpose: `Settings` merges defaults and
/// stored values into one map, so at read time there is no way to ask "was this
/// ever written". Comparing against the shipped default is the only available
/// approximation of "did the user choose this".
///
/// `feature_flags_test.dart` pins each of these to the live `appdata.settings`
/// value on a fresh install. Without that test a default could be retuned in
/// `appdata.dart` and this copy would quietly start reporting every user as
/// having made a choice — which would disable remote tuning entirely, silently.
abstract final class ConfigDefaults {
  static const int downloadThreads = 5;
  static const int ocrWorkers = 0;
  static const int backupRetention = 10;

  /// Not a user setting — a compile-time const in `network/images.dart`. There
  /// is no user choice to respect, so an overlay always applies.
  static const int imageTimeoutSeconds = 30;
}

/// Reads an int config value, letting a published override shadow the *default*.
///
/// [current] is what the build would have used (normally `appdata.settings[...]`)
/// and [builtinDefault] is the value shipped in [Settings]. When they differ the
/// user has made a choice and it wins outright; only an untouched default can be
/// shadowed.
///
/// That asymmetry is the whole safety property. An overlay that outranked user
/// settings would produce the worst shape of bug this mechanism can have: a
/// person changes a value, watches it not take effect, and has no way to see
/// why — the setting screen shows their number while the app runs ours. Remote
/// tuning exists to correct a bad default for a fleet, never to overrule someone
/// who already decided.
///
/// Edge case, deliberately accepted: a user who explicitly picks the same value
/// as the default is indistinguishable from one who never touched it, so an
/// overlay may shadow that. [Settings] merges defaults and stored values into one
/// map, so there is no "was this ever written" bit to consult.
int configInt(String key, int current, int builtinDefault) {
  if (current != builtinDefault) return current;
  return ConfigOverlay.instance.typed<int>(key) ?? current;
}

/// Reads a bool config value. Same default-only rule as [configInt].
bool configBool(String key, bool current, bool builtinDefault) {
  if (current != builtinDefault) return current;
  return ConfigOverlay.instance.typed<bool>(key) ?? current;
}

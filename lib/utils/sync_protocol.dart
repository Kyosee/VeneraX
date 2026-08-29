/// Pure decision logic for WebDAV data sync.
///
/// Every rule that decides sync DIRECTION (upload vs download), VERSION
/// numbers, or FILE selection lives here as a pure function so the whole
/// protocol is unit-testable and auditable in one place. IO, locking and UI
/// stay in `data_sync.dart`; nothing in this file may import app state.
///
/// ## Protocol summary
///
/// The server holds whole-library snapshots named
/// `<days-since-epoch>-<version>.<platform>.venera`. The numeric `version` is
/// the only ordering signal: higher wins (last-writer-wins). Devices track
/// their own position in `appdata.settings['dataVersion']`.
///
/// - Download: pull the highest-version backup if it is newer than local.
/// - Automatic upload: allowed only when the device is NOT behind the server
///   ([shouldSkipStaleUpload]); a stale device downloads to catch up instead
///   (#86). The new backup is stamped [nextSyncVersion] = above both local and
///   server max (#80).
/// - Explicit upload (manual button / local import / headless CLI): always
///   wins (`force`), preserving "this device is the source of truth" intent.
/// - Retention: after a successful upload, every platform keeps its
///   [backupRetentionPerPlatform] newest backups
///   ([backupsBeyondPlatformRetention]) so a bad upload can be rolled back
///   from the server's history.
library;

// The hot-update runtime. Not app state: it is a leaf package holding the seam
// gate (a static bool) and the override table, so importing it here keeps this
// file's "pure decision logic, no app state" rule intact.
import 'package:venera_patch/venera_patch.dart';

/// The version number to stamp on a freshly uploaded WebDAV backup.
///
/// It must beat BOTH the local version and the highest version already on the
/// server. Deriving it from the local version alone let a device whose local
/// version trailed the server — a fresh device, or one that just imported a
/// foreign archive carrying an unrelated lower `dataVersion` — upload a backup
/// that the numeric version-based sync direction treated as "older", so other
/// devices never pulled it (issue #80). Pure function, easy to unit-test.
int nextSyncVersion(int localVersion, int remoteMaxVersion) =>
    (localVersion > remoteMaxVersion ? localVersion : remoteMaxVersion) + 1;

/// Whether an automatic upload must be skipped because this device is behind
/// the server, and should download first instead of overwriting newer remote
/// data with its own stale snapshot (issue #86).
///
/// Sync is a whole-library snapshot with last-writer-wins keyed on the numeric
/// version. If a device holding older data ([localVersion] < [remoteMaxVersion])
/// uploads, [nextSyncVersion] stamps that stale snapshot with `remoteMax + 1`,
/// making every other device pull the old data back and revert the newer data
/// they had. Guarding automatic uploads against this is the fix.
///
/// [force] uploads are explicit "publish, this is the source of truth" actions
/// (manual upload button, local-file import, headless CLI) and intentionally
/// bypass the guard, preserving the #80 "always wins" behavior. Pure function.
bool shouldSkipStaleUpload({
  required bool force,
  required int localVersion,
  required int remoteMaxVersion,
}) =>
    !force && remoteMaxVersion > localVersion;

/// Sanity ceiling for a believable sync version.
///
/// Versions advance by +1 per upload; even a decade of hourly uploads stays
/// under 100k. Foreign or corrupted archives, however, may carry a
/// milliseconds-since-epoch value (~1.7e12) in `dataVersion`. Accepting one
/// through the max-merge would permanently inflate the whole fleet's version
/// lineage, and a near-int64 value would overflow [nextSyncVersion] into a
/// negative number, inverting every subsequent direction decision.
const int maxReasonableDataVersion = 10000000;

/// Merges an incoming backup's `dataVersion` into the local one.
///
/// Normal rule: never move backwards — `max(local, incoming)` — so restoring
/// an older backup cannot make this device look "behind" and re-enter the
/// stale-overwrite loop. Additionally, an incoming version beyond
/// [maxReasonableDataVersion] is treated as foreign garbage and ignored (the
/// local version is kept). Pure function.
int mergeIncomingDataVersion(int localVersion, int incomingVersion) {
  if (incomingVersion < 0 || incomingVersion > maxReasonableDataVersion) {
    return localVersion;
  }
  return localVersion > incomingVersion ? localVersion : incomingVersion;
}

/// Highest backup version present among [fileNames], or 0 when none parse.
///
/// Compares by numeric version (via [RemoteBackupInfo.fromFileName]), never by
/// file-name string order — `…-10.venera` outranks `…-9.venera`. Skips null and
/// non-`.venera` entries. Pure function, easy to unit-test.
int maxBackupVersion(Iterable<String?> fileNames) {
  var max = 0;
  for (final name in fileNames) {
    if (name == null || !name.endsWith('.venera')) continue;
    final v = RemoteBackupInfo.fromFileName(name).version;
    if (v > max) max = v;
  }
  return max;
}

/// Whether the newest backup on the server is the very file this device
/// uploaded but never confirmed (#133).
///
/// An upload PUT can succeed server-side while the client still reports
/// failure — the response body fails to decode, the request times out after
/// the server committed, or the process dies before the local `dataVersion`
/// is adopted (version adoption is deliberately publish-first). The server is
/// then left holding an "orphan" backup: this device's own snapshot, stamped
/// one version above the device's local claim. On the next sync the device
/// sees itself as behind, pulls its own stale snapshot back, and every read
/// made since that export is reverted — then re-uploaded one version higher,
/// spreading the rollback to the whole fleet.
///
/// Matching the file name recorded immediately before the PUT (plus the size,
/// when both sides report one — a size mismatch means a truncated PUT whose
/// content must NOT be claimed) lets the device adopt the orphan's version
/// instead of downloading it. Pure function.
bool isOwnPendingPublish({
  required String? claimedFileName,
  required int? claimedSize,
  required String remoteFileName,
  required int? remoteSize,
}) {
  if (claimedFileName == null || claimedFileName != remoteFileName) {
    return false;
  }
  if (claimedSize != null && remoteSize != null && claimedSize != remoteSize) {
    return false;
  }
  return true;
}

/// Automation tier for WebDAV data sync (#114). Stored PER DEVICE (in
/// implicitData, never synced): cadence is a property of the device and its
/// connection — a phone on a metered plan and a desktop on wifi legitimately
/// want different tiers.
enum WebdavSyncMode {
  /// Upload shortly (2s debounce) after every data change — the historical
  /// behavior and the default.
  realtime,

  /// Changes only mark a persistent "pending changes" account; one merged
  /// upload settles it at the session boundaries (background/screen-off on
  /// Android, resume, startup, window close on desktop), at the latest a
  /// fixed age after the first unsynced change, or manually.
  dataSaver,

  /// Never upload automatically. Downloads (startup/resume checks) still run
  /// so the device keeps up with the fleet; uploads happen only through the
  /// home sync button or the settings page.
  manual,
}

/// Resolves a persisted sync-mode name, falling back to the legacy
/// `webdavAutoSync` boolean for devices configured before the tiers existed:
/// `false` meant "no automatic upload at all" → [WebdavSyncMode.manual];
/// anything else keeps the historical always-on behavior → realtime.
/// Pure function, easy to unit-test.
WebdavSyncMode syncModeFromName(String? name, {bool? legacyAutoSync}) {
  for (final mode in WebdavSyncMode.values) {
    if (mode.name == name) return mode;
  }
  if (legacyAutoSync == false) return WebdavSyncMode.manual;
  return WebdavSyncMode.realtime;
}

/// How many backups each platform keeps on the WebDAV server.
///
/// Retention is per platform tag (android / ios / win / …) so that one very
/// active device can never rotate another platform's only backups away, and
/// every device keeps a few rollback points of its own lineage: if a stale or
/// misbehaving device publishes bad data as the newest version, the previous
/// good snapshots are still on the server for a manual restore.
const int backupRetentionPerPlatform = 10;

/// Clamps the user-configurable per-platform retention count (#114) to a safe
/// range. The setting syncs fleet-wide through settings, so a foreign or
/// corrupt value must not be able to rotate away the rollback margin the
/// retention exists for (floor 3) or hoard unbounded junk (cap 100). Anything
/// non-numeric falls back to [backupRetentionPerPlatform]. Pure function.
int sanitizedBackupRetention(dynamic value) {
  final v = value is num
      ? value.toInt()
      : int.tryParse(value?.toString() ?? '') ?? backupRetentionPerPlatform;
  if (v < 3) return 3;
  if (v > 100) return 100;
  return v;
}

/// Backups to delete so every platform keeps at most [keepPerPlatform] of its
/// newest versions. The just-uploaded [newFileName] counts toward its
/// platform's quota and is never returned.
///
/// Grouping is by the platform tag parsed from each file name; legacy or
/// foreign names without one share the 'unknown' bucket, so old junk rotates
/// out too. Ranking within a platform is by numeric version — never file-name
/// string order (`…-100` outranks `…-99`).
///
/// This replaces two older rules with failure modes the fleet actually hit:
/// one-backup-per-day-per-platform could delete the last good snapshot
/// uploaded minutes before a bad one, and a global 10-file cap pruned by
/// lowest version fleet-wide, which starved an inactive platform of every
/// backup it had. Callers must delete these only AFTER the new backup is
/// safely on the server. Pure function.
List<String> backupsBeyondPlatformRetention({
  required Iterable<String?> fileNames,
  required String newFileName,
  int keepPerPlatform = backupRetentionPerPlatform,
}) {
  final byPlatform = <String, List<RemoteBackupInfo>>{};
  void add(String name) {
    final info = RemoteBackupInfo.fromFileName(name);
    byPlatform.putIfAbsent(info.platform, () => []).add(info);
  }

  var listedNewFile = false;
  for (final name in fileNames) {
    if (name == null || !name.endsWith('.venera')) continue;
    if (name == newFileName) listedNewFile = true;
    add(name);
  }
  // The caller lists the directory BEFORE uploading, so the new backup is
  // normally not in the listing yet — count it toward its platform's quota.
  if (!listedNewFile) {
    add(newFileName);
  }

  final result = <String>[];
  for (final group in byPlatform.values) {
    if (group.length <= keepPerPlatform) continue;
    group.sort((a, b) => b.version.compareTo(a.version));
    for (final info in group.skip(keepPerPlatform)) {
      if (info.fileName == newFileName) continue;
      result.add(info.fileName);
    }
  }
  return result;
}

class RemoteBackupInfo {
  final String fileName;
  final int version;
  final String platform;
  final DateTime date;
  final DateTime? mTime;

  RemoteBackupInfo({
    required this.fileName,
    required this.version,
    required this.platform,
    required this.date,
    this.mTime,
  });

  /// The most precise timestamp available for display: prefer the WebDAV
  /// last-modified time (has hour/minute/second) and fall back to the
  /// day-precision date parsed from the file name.
  DateTime get effectiveDate => mTime ?? date;

  factory RemoteBackupInfo.fromFileName(String name, {DateTime? mTime}) {
    var parts = name.replaceAll('.venera', '').split('-');
    var leadingSegment = int.tryParse(parts.firstOrNull ?? '') ?? 0;
    var versionStr = parts.elementAtOrNull(1)?.split('.').first ?? '0';
    var version = int.tryParse(versionStr) ?? 0;
    var platform = 'unknown';
    var dotParts = parts.elementAtOrNull(1)?.split('.') ?? [];
    if (dotParts.length >= 2) {
      platform = dotParts[1];
    }
    return RemoteBackupInfo(
      fileName: name,
      version: version,
      platform: platform,
      date: _dateFromLeadingSegment(leadingSegment),
      mTime: mTime,
    );
  }

  static const int _msPerDay = 86400000;

  /// Upper bound of [DateTime.fromMillisecondsSinceEpoch]'s valid range.
  static const int _maxValidMs = 8640000000000000;

  /// Resolves the date encoded in a backup file name's leading segment.
  ///
  /// The segment is normally days-since-epoch (~5 digits). Older and foreign
  /// backups instead store a full `millisecondsSinceEpoch` (~13 digits); blindly
  /// multiplying that by [_msPerDay] overflows 64-bit int on Android and throws
  /// a RangeError that aborts the entire directory scan (issue #51). So multiply
  /// only when the value is small enough to be a real day count, otherwise treat
  /// it as milliseconds, and clamp so the constructor can never throw.
  static DateTime _dateFromLeadingSegment(int value) {
    // Seam. Hand-written for now; build_runner generates these in stage 3.
    //
    // This function is the first seam because it is the shape the mechanism is
    // for: pure, int in / DateTime out, and the site of a real field bug (#51)
    // whose fix was a one-line change to a numeric guard. Re-running the
    // original after a machinery failure is harmless, which is what makes the
    // fallback in [patched] safe here.
    return patched(
      SeamIds.backupDateFromLeadingSegment,
      [value],
      () => _dateFromLeadingSegmentOrig(value),
    );
  }

  static DateTime _dateFromLeadingSegmentOrig(int value) {
    var ms =
        value.abs() <= _maxValidMs ~/ _msPerDay ? value * _msPerDay : value;
    if (ms > _maxValidMs) ms = _maxValidMs;
    if (ms < -_maxValidMs) ms = -_maxValidMs;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }
}

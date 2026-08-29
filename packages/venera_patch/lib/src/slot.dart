import 'dart:convert';

/// Two-slot patch state with launch-proven promotion.
///
/// Borrowed from Shorebird's model, and it replaces a probation-counter scheme
/// that had strictly more states to get wrong: at most two patches exist, and
/// the previous one is deleted only once its successor has survived a launch.
/// Self-healing then falls out of the structure instead of being bolted on.
///
/// The state machine:
///
/// ```
///   (none)  --install-->  next (unproven)
///   next    --launch ok-->  current   (old current deleted)
///   next    --launch bad--> deleted   (current stays)
/// ```
///
/// "Launch bad" is detected by absence: [markLaunchStarted] persists a boot
/// marker before the patch runs, and [markLaunchSucceeded] clears it once the
/// app reaches a healthy state. A marker still present at the next launch means
/// the previous launch never got there.
class PatchSlots {
  PatchSlots({
    this.current,
    this.next,
    this.bootMarker = 0,
    this.disabledVersions = const {},
  });

  /// The patch proven to survive a launch. May be null (clean install).
  PatchSlotEntry? current;

  /// Installed but not yet launch-proven.
  PatchSlotEntry? next;

  /// Consecutive launches that started but never reported success.
  int bootMarker;

  /// patchVersions banned after a failed launch. A rolled-back patch must not
  /// be re-downloaded and re-crashed on the next check — without this the
  /// device would loop, which is exactly the download/crash cycle the WebDAV
  /// startup-import bug produced.
  Set<int> disabledVersions;

  /// Boot failures tolerated before rollback. Two, not one: a single failure
  /// can be an unrelated OOM kill or a user force-quitting during startup.
  static const int failureThreshold = 2;

  /// The entry that should be loaded this launch — the unproven one gets its
  /// chance first, otherwise the proven one.
  PatchSlotEntry? get pending => next ?? current;

  bool isDisabled(int patchVersion) => disabledVersions.contains(patchVersion);

  /// Highest version installed in either slot; the floor for accepting a new
  /// manifest.
  int get highestVersion {
    final a = current?.patchVersion ?? 0;
    final b = next?.patchVersion ?? 0;
    return a > b ? a : b;
  }

  /// Records a new patch into the unproven slot. Returns the entry it displaced
  /// (if any) so the caller can delete its files.
  PatchSlotEntry? stage(PatchSlotEntry entry) {
    final displaced = next;
    next = entry;
    return displaced;
  }

  /// Called before the patch is handed to the VM.
  void markLaunchStarted() => bootMarker++;

  /// Called once the app is healthy. Promotes [next] to [current] and returns
  /// the retired entry for deletion.
  PatchSlotEntry? markLaunchSucceeded() {
    bootMarker = 0;
    final staged = next;
    if (staged == null) return null;
    final retired = current;
    current = staged;
    next = null;
    return retired;
  }

  /// Whether the accumulated boot marker means the pending patch is bad.
  bool get shouldRollBack => bootMarker >= failureThreshold;

  /// Discards the pending patch and bans its version. Returns the entry to
  /// delete.
  PatchSlotEntry? rollBack() {
    bootMarker = 0;
    final bad = next ?? current;
    if (bad != null) {
      disabledVersions = {...disabledVersions, bad.patchVersion};
    }
    if (next != null) {
      next = null;
    } else {
      current = null;
    }
    return bad;
  }

  Map<String, Object?> toJson() => {
    'current': current?.toJson(),
    'next': next?.toJson(),
    'bootMarker': bootMarker,
    'disabledVersions': disabledVersions.toList(),
  };

  static PatchSlots fromJson(Object? raw) {
    if (raw is String) {
      try {
        return fromJson(jsonDecode(raw));
      } catch (_) {
        return PatchSlots();
      }
    }
    if (raw is! Map) return PatchSlots();
    return PatchSlots(
      current: PatchSlotEntry.fromJson(raw['current']),
      next: PatchSlotEntry.fromJson(raw['next']),
      bootMarker: _asInt(raw['bootMarker']),
      disabledVersions: (raw['disabledVersions'] is List)
          ? (raw['disabledVersions'] as List)
                .map(_asInt)
                .where((v) => v > 0)
                .toSet()
          : const {},
    );
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }
}

/// One installed patch on disk.
class PatchSlotEntry {
  const PatchSlotEntry({
    required this.patchVersion,
    required this.track,
    required this.dirName,
    required this.sha256,
  });

  final int patchVersion;
  final String track;

  /// Directory name (not a full path) under the patch root. Storing a relative
  /// name keeps the state file valid across the app-support path changes that
  /// happen on iOS reinstalls and container migrations.
  final String dirName;

  final String sha256;

  Map<String, Object?> toJson() => {
    'patchVersion': patchVersion,
    'track': track,
    'dirName': dirName,
    'sha256': sha256,
  };

  static PatchSlotEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final dir = raw['dirName']?.toString();
    if (dir == null || dir.isEmpty) return null;
    return PatchSlotEntry(
      patchVersion: PatchSlots._asInt(raw['patchVersion']),
      track: raw['track']?.toString() ?? 'stable',
      dirName: dir,
      sha256: raw['sha256']?.toString() ?? '',
    );
  }
}

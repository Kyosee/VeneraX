/// The call a seam performs.
///
/// A seam is the two lines wrapped around a function body that let a patch take
/// it over. Seams are generated across the whole codebase (or, for now, written
/// by hand at a few hot spots), so the *uninstalled* cost is paid by every call
/// in the app — which is why the fast path is a static bool read and nothing
/// else. No map probe, no null check on an object field, no singleton getter.
///
/// ## Where a seam may go
///
/// Only on a function where **re-running the original after a mid-call fault is
/// safe**. When the VM faults partway through an override, this falls back to
/// the original implementation — so if the override had already written a file,
/// inserted a row, or fired a request, that work happens twice.
///
/// In practice that means pure computation: parsing, comparison, normalisation,
/// predicate evaluation. Which is also where small bugs actually live, so the
/// constraint costs less than it sounds like. A function with side effects can
/// still be patched, but the seam belongs at a level where the whole unit of
/// work is inside the override, not straddling it.
///
/// ## Never here
///
/// Never on a per-frame or per-image path. The interpreter is ~23x native, so a
/// patched function on the decode or render path turns a fix into a visible
/// stutter. Seams on those paths are worse than no seam at all.
library;

import 'registry.dart';

/// Runs the installed override for [id], or [orig] when there is none.
///
/// [args] are the arguments the override receives. [orig] is passed through to
/// the override as well, so a patch can call the original and adjust its result
/// rather than reimplementing it — a far smaller change, and one that inherits
/// the original's edge-case handling instead of having to rediscover it.
///
/// A [PatchVmError] means the machinery failed, so the original runs and the
/// override is already quarantined (the binder does that) — later calls skip
/// straight through. Anything else the override throws propagates untouched: it
/// is the patched code's own exception and must behave exactly as the original's
/// would.
T patched<T>(int id, List<Object?> args, T Function() orig) {
  if (!PatchRegistry.active) return orig();
  final fn = PatchRegistry.lookup(id);
  if (fn == null) return orig();
  try {
    return fn(args, orig) as T;
  } on PatchVmError {
    // Machinery failure: the override cannot be trusted to produce a correct
    // answer, so fall back. Safe only because seams sit on functions where
    // re-running the original is harmless — see the library doc.
    return orig();
  } on TypeError {
    // The override returned something that is not a T. That is a tooling
    // inconsistency (the payload disagrees with the seam's signature), not a
    // patch-logic error, so it gets the same fallback-and-quarantine treatment.
    PatchRegistry.quarantine(id, StateError('override #$id returned a non-$T'));
    return orig();
  }
}

/// Async variant. Same rules; the override's Future is awaited by the caller.
Future<T> patchedAsync<T>(
  int id,
  List<Object?> args,
  Future<T> Function() orig,
) async {
  if (!PatchRegistry.active) return orig();
  final fn = PatchRegistry.lookup(id);
  if (fn == null) return orig();
  try {
    final result = fn(args, orig);
    if (result is Future) return await result as T;
    return result as T;
  } on PatchVmError {
    return orig();
  } on TypeError {
    PatchRegistry.quarantine(id, StateError('override #$id returned a non-$T'));
    return orig();
  }
}

/// Stable ids for the seams in this build.
///
/// Ids are assigned here rather than derived from names because a rename must
/// not silently retarget a patch: changing a function's name leaves its id
/// alone, and *removing* a seam frees an id that must never be reused. The
/// surface manifest emitted at build time records the mapping so the patch
/// compiler can verify a payload targets the ids this binary actually has.
abstract final class SeamIds {
  /// `RemoteBackupInfo._dateFromLeadingSegment` — days-vs-milliseconds
  /// disambiguation for a backup file name's leading segment. Site of the #51
  /// 64-bit overflow that aborted the whole directory scan.
  static const int backupDateFromLeadingSegment = 0x0001;

  /// `RemoteBackupInfo.fromFileName` — the whole file-name parser.
  ///
  /// RESERVED: the id is taken, but no [patched] call site exists yet, so it is
  /// absent from [installed] and a patch cannot name it. An id that once meant
  /// one function must never come to mean another — a patch built against the
  /// older meaning would install cleanly and override the wrong code — so it
  /// stays declared here rather than being freed for reuse.
  static const int backupInfoFromFileName = 0x0002;

  /// `_compareVersion` in the About page — "is this release newer than us".
  ///
  /// Pure, two strings in, bool out, and re-running it is free. It also gates
  /// whether the update prompt appears at all, so a bug here is invisible in the
  /// worst way: users simply stop being offered updates, including the update
  /// that would fix it.
  static const int compareAppVersions = 0x0003;

  /// `nextSyncVersion` — the version stamped on a fresh WebDAV backup.
  ///
  /// Site of #80: deriving it from the local version alone let a device whose
  /// version trailed the server upload a backup everyone else read as "older"
  /// and never pulled.
  static const int nextSyncVersion = 0x0004;

  /// `shouldSkipStaleUpload` — whether an automatic upload must stand down.
  ///
  /// Site of #86: a device holding older data uploading it stamped as newest,
  /// making the whole fleet pull the stale snapshot back and revert real reads.
  /// The worst class of bug this app has, and a pure predicate.
  static const int shouldSkipStaleUpload = 0x0005;

  /// `mergeIncomingDataVersion` — folding a restored backup's version into ours.
  ///
  /// Guards the sanity ceiling that keeps a foreign millisecond timestamp from
  /// inflating the fleet's whole version lineage, and keeps `nextSyncVersion`
  /// from overflowing into a negative that inverts every later direction call.
  static const int mergeIncomingDataVersion = 0x0006;

  /// `isOwnPendingPublish` — "is the newest remote file the one we just PUT".
  ///
  /// Site of #133: an upload that succeeded server-side but reported failure
  /// left an orphan the device then pulled back, reverting every read since the
  /// export and re-uploading the rollback to everyone.
  static const int isOwnPendingPublish = 0x0007;

  /// `shouldRequireDisclaimerConsent` — whether the launch is gated behind the
  /// user agreement.
  ///
  /// The consent page already exists and is already reachable from settings;
  /// this seam decides only whether a launch is routed through it. That makes a
  /// legal-text or first-run-consent requirement a published decision rather
  /// than a release — which matters because the requirement usually arrives from
  /// outside on someone else's timetable.
  ///
  /// Pure: two booleans in, one out, and re-running it costs nothing. It runs in
  /// `build`, so an override is read on every rebuild rather than cached.
  static const int disclaimerGate = 0x0008;

  /// `isBlocked` — the first blocked keyword matched by a comic, or null.
  ///
  /// Runs for every tile in every list. The seam exists because "my blocklist
  /// doesn't catch X" is the single most common filtering complaint, and each
  /// variant (case-insensitive, whole-word, subtitle-only) is a different
  /// predicate rather than a different setting.
  static const int comicIsBlocked = 0x0009;

  /// `blockedTagOf` — the first tag-blocklist entry matched by a tag list.
  ///
  /// Separate from [comicIsBlocked] because the matching rules genuinely differ:
  /// substring rather than equality, and the localized tag text participates.
  static const int blockedTagOf = 0x000A;

  /// `historySourceLabel` — the display name for a source key in history.
  ///
  /// Feeds the filter chips, the keyword match, and the chip ordering, so one
  /// override changes what a search finds and how the filter list sorts.
  ///
  /// RESERVED: the id is claimed but no [patched] call site exists yet. The
  /// function is duplicated across the history and read-later pages, and a seam
  /// on one copy would silently leave the other unpatched — worse than no seam,
  /// because the fix would look applied. Deduplicate first, then install.
  static const int historySourceLabel = 0x000B;

  /// Seam name to id — **only** for seams with a live [patched] call site.
  ///
  /// This is what the surface manifest publishes, and the distinction is
  /// load-bearing. A declared-but-uninstalled id would let a patch compile,
  /// sign, install and report success while overriding nothing at all: the
  /// registry would hold an entry no code ever looks up. That is the exact
  /// failure this whole mechanism is supposed to avoid — a fix that appears
  /// applied and isn't — so an id becomes nameable only once its seam exists.
  static const Map<String, int> installed = {
    'backupDateFromLeadingSegment': backupDateFromLeadingSegment,
    'compareAppVersions': compareAppVersions,
    'nextSyncVersion': nextSyncVersion,
    'shouldSkipStaleUpload': shouldSkipStaleUpload,
    'mergeIncomingDataVersion': mergeIncomingDataVersion,
    'isOwnPendingPublish': isOwnPendingPublish,
    'disclaimerGate': disclaimerGate,
    'comicIsBlocked': comicIsBlocked,
    'blockedTagOf': blockedTagOf,
  };
}

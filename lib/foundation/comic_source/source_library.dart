import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';

/// A remote catalog of comic sources (an `index.json` URL). The app can hold
/// many of these at once; they drive discovery and update resolution. The
/// installed copy of a source is still single-per-key on disk — libraries only
/// describe where a source can be found and which one wins when several offer
/// the same key.
class ComicSourceLibrary {
  ComicSourceLibrary({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.priority = 0,
    this.lastChecked,
  });

  /// Stable identifier derived from the normalized URL, so the same library on
  /// two devices converges to the same id after sync instead of diverging into
  /// duplicates.
  final String id;

  String name;
  String url;
  bool enabled;

  /// Ascending = checked first; the lowest value wins a same-key conflict.
  int priority;

  /// Epoch ms of the last successful catalog fetch (null = never). Device-local
  /// timing only; informational after sync.
  int? lastChecked;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'enabled': enabled,
    'priority': priority,
    'lastChecked': lastChecked,
  };

  factory ComicSourceLibrary.fromJson(Map<String, dynamic> json) {
    return ComicSourceLibrary(
      id:
          json['id']?.toString() ??
          stableLibraryId(json['url']?.toString() ?? ''),
      name: json['name']?.toString() ?? '',
      url: json['url']?.toString() ?? '',
      enabled: json['enabled'] != false,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
      lastChecked: (json['lastChecked'] as num?)?.toInt(),
    );
  }
}

/// Where an installed source came from and which libraries currently offer it.
class SourceProvenance {
  SourceProvenance({
    List<String>? libraryIds,
    this.originId,
    this.updateLibraryId,
  }) : libraryIds = libraryIds ?? [];

  /// Every enabled library whose catalog currently lists this key. Rebuilt on
  /// each full update check.
  List<String> libraryIds;

  /// The library this copy was installed from. Written once at install and kept
  /// sticky across catalog churn and update-reloads. Drives the origin badge
  /// and the removal-cascade fallback.
  String? originId;

  /// The library that won update-URL resolution (lowest priority among
  /// [libraryIds]). Recomputed on each check.
  String? updateLibraryId;

  Map<String, dynamic> toJson() => {
    'libraryIds': libraryIds,
    'originId': originId,
    'updateLibraryId': updateLibraryId,
  };

  factory SourceProvenance.fromJson(Map<String, dynamic> json) {
    return SourceProvenance(
      libraryIds:
          (json['libraryIds'] as List?)?.map((e) => e.toString()).toList() ??
          [],
      originId: json['originId']?.toString(),
      updateLibraryId: json['updateLibraryId']?.toString(),
    );
  }
}

/// Normalizes the URL parts that are case-insensitive while preserving the
/// path and query, whose casing may identify different server resources.
String canonicalLibraryUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) {
    return 'empty';
  }
  final uri = Uri.tryParse(trimmed);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    var fallback = trimmed;
    while (fallback.endsWith('/')) {
      fallback = fallback.substring(0, fallback.length - 1);
    }
    return fallback.isEmpty ? 'empty' : fallback;
  }
  final pathSegments = uri.pathSegments.toList();
  while (pathSegments.isNotEmpty && pathSegments.last.isEmpty) {
    pathSegments.removeLast();
  }
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        pathSegments: pathSegments,
      )
      .toString();
}

/// Derives a stable, cross-device id from a canonical catalog URL.
String stableLibraryId(String url) {
  return md5
      .convert(utf8.encode(canonicalLibraryUrl(url)))
      .toString()
      .substring(0, 12);
}

@visibleForTesting
String allocateLibraryId(String url, Iterable<String> usedIds) {
  final used = usedIds.toSet();
  final canonicalBytes = utf8.encode(canonicalLibraryUrl(url));
  final md5Digest = md5.convert(canonicalBytes).toString();
  final candidates = [
    md5Digest.substring(0, 12),
    md5Digest,
    sha256.convert(canonicalBytes).toString(),
  ];
  for (final candidate in candidates) {
    if (!used.contains(candidate)) {
      return candidate;
    }
  }
  throw StateError('Unable to allocate a unique library id');
}

/// Reconciles the portable origin declarations against this device's
/// [provenance] store: a key the store carries follows its `originId`, and a
/// key it does not carry is left as-is.
///
/// Leaving unknown keys alone is what makes the declarations mergeable — a
/// device only ever speaks for the sources it has installed, so two devices
/// with different source sets converge instead of erasing each other's records.
/// [removedKeys] drops declarations for sources genuinely uninstalled here.
@visibleForTesting
Map<String, String> reconcileOriginDeclarations({
  required Map<String, dynamic> provenance,
  required Map<String, String> declarations,
  Iterable<String> removedKeys = const [],
}) {
  final merged = Map<String, String>.from(declarations);
  for (final entry in provenance.entries) {
    final raw = entry.value;
    final originId = raw is Map ? raw['originId']?.toString() : null;
    if (originId != null && originId.isNotEmpty) {
      merged[entry.key] = originId;
    } else {
      merged.remove(entry.key);
    }
  }
  for (final key in removedKeys) {
    merged.remove(key);
  }
  return merged;
}

/// Applies incoming origin [declarations] onto [provenance] in place and
/// returns the keys whose governing library changed.
///
/// A declaration naming a library absent from [knownLibraryIds] is ignored: it
/// would render as "source library removed" and still fall through to another
/// offerer, which is worse than keeping what this device already knows.
/// `updateLibraryId` is cleared for every adopted key so the next check
/// recomputes the winner instead of keeping the previous one.
@visibleForTesting
Set<String> adoptOriginDeclarations({
  required Map<String, dynamic> provenance,
  required Map<String, String> declarations,
  required Set<String> knownLibraryIds,
}) {
  final changed = <String>{};
  for (final entry in declarations.entries) {
    final libraryId = entry.value;
    if (!knownLibraryIds.contains(libraryId)) continue;
    final raw = provenance[entry.key];
    final prov = raw is Map
        ? SourceProvenance.fromJson(Map<String, dynamic>.from(raw))
        : SourceProvenance();
    if (prov.originId == libraryId) continue;
    prov.originId = libraryId;
    if (!prov.libraryIds.contains(libraryId)) {
      prov.libraryIds.add(libraryId);
    }
    prov.updateLibraryId = null;
    provenance[entry.key] = prov.toJson();
    changed.add(entry.key);
  }
  return changed;
}

@visibleForTesting
ComicSourceLibrary? findLibraryByUrl(
  Iterable<ComicSourceLibrary> libraries,
  String url,
) {
  final canonical = canonicalLibraryUrl(url);
  for (final library in libraries) {
    if (canonicalLibraryUrl(library.url) == canonical) {
      return library;
    }
  }
  return null;
}

/// Derives a short, readable default library name from a catalog URL so the
/// list never shows an overlong raw URL. Prefers the host; appends a
/// distinguishing path segment when several catalogs share one host.
String defaultLibraryName(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) {
    return url.trim();
  }
  final segments = uri.pathSegments
      .where((s) => s.isNotEmpty && !s.toLowerCase().endsWith('.json'))
      .toList();
  if (segments.isEmpty) {
    return uri.host;
  }
  return "${uri.host}/${segments.last}";
}

/// Reads and mutates the ordered library registry stored in
/// `appdata.settings['comicSourceLibraries']`, plus the per-source provenance
/// map in `appdata.settings['comicSourceProvenance']`. Pure data logic; the UI
/// and the update checker call into this.
class ComicSourceLibraryManager {
  static const _librariesKey = 'comicSourceLibraries';
  static const _provenanceKey = 'comicSourceProvenance';

  /// Portable `sourceKey -> libraryId` declarations mirrored out of the
  /// provenance map. Provenance itself is device-local (its `libraryIds` and
  /// `updateLibraryId` are rebuilt by every check), but which library a source
  /// was installed from — and therefore updates through — is a choice the user
  /// made, so it has to travel with backups and sync. Kept as its own setting
  /// so it merges per key instead of one device's whole map replacing another's.
  static const _originsKey = 'comicSourceOrigins';

  static const _migratedKey = 'comicSourceLibrariesMigrated';

  /// All libraries, sorted by priority ascending (winner first).
  static List<ComicSourceLibrary> all() {
    final raw = appdata.settings[_librariesKey];
    if (raw is! List) {
      return [];
    }
    final list = raw
        .whereType<Map>()
        .map((e) => ComicSourceLibrary.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    list.sort((a, b) => a.priority.compareTo(b.priority));
    return list;
  }

  static List<ComicSourceLibrary> enabled() =>
      all().where((e) => e.enabled).toList();

  static ComicSourceLibrary? find(String id) {
    for (final lib in all()) {
      if (lib.id == id) return lib;
    }
    return null;
  }

  static ComicSourceLibrary? _findIn(
    List<ComicSourceLibrary> libraries,
    String id,
  ) {
    for (final lib in libraries) {
      if (lib.id == id) return lib;
    }
    return null;
  }

  /// Persists [libraries], re-densifies priority to list order, mirrors the
  /// primary URL into the legacy setting, then saves (which triggers sync).
  static void save(List<ComicSourceLibrary> libraries) {
    for (var i = 0; i < libraries.length; i++) {
      libraries[i].priority = i;
    }
    appdata.settings[_librariesKey] = libraries.map((e) => e.toJson()).toList();
    appdata.settings['comicSourceListUrl'] = _primaryUrlOf(libraries);
    appdata.saveData();
  }

  static String _primaryUrlOf(List<ComicSourceLibrary> libraries) {
    final sorted = List<ComicSourceLibrary>.from(libraries)
      ..sort((a, b) => a.priority.compareTo(b.priority));
    for (final lib in sorted) {
      if (lib.enabled && lib.url.isNotEmpty) return lib.url;
    }
    return '';
  }

  /// Adds a library for [url] if the current URL is not already present.
  /// Returns the (possibly pre-existing) library.
  static ComicSourceLibrary add(String name, String url) {
    final libraries = all();
    // Stored ids intentionally survive URL edits because provenance references
    // them. Deduplicate by the current URL, then allocate around any stale id.
    final existing = findLibraryByUrl(libraries, url);
    if (existing != null) {
      if (name.isNotEmpty) existing.name = name;
      save(libraries);
      return existing;
    }
    final id = allocateLibraryId(url, libraries.map((library) => library.id));
    final lib = ComicSourceLibrary(
      id: id,
      name: name.isNotEmpty ? name : defaultLibraryName(url),
      url: url,
      priority: libraries.length,
    );
    libraries.add(lib);
    save(libraries);
    return lib;
  }

  /// Updates a library's display name and/or catalog URL in place. The library
  /// id is intentionally kept stable (provenance records reference it), even if
  /// the URL — from which a fresh id would derive — changes.
  static void edit(String id, {String? name, String? url}) {
    final libraries = all();
    final lib = _findIn(libraries, id);
    if (lib == null) return;
    if (name != null && name.isNotEmpty) {
      lib.name = name;
    } else if (name != null && url != null) {
      // Name cleared: fall back to a readable default from the (new) URL.
      lib.name = defaultLibraryName(url);
    }
    if (url != null && url.isNotEmpty) {
      lib.url = url;
    }
    save(libraries);
  }

  static void setEnabled(String id, bool enabled) {
    final libraries = all();
    final lib = _findIn(libraries, id);
    if (lib == null) return;
    lib.enabled = enabled;
    save(libraries);
  }

  /// Reorders the library at [oldIndex] to [newIndex] in the priority-sorted
  /// list, then re-densifies priority. [newIndex] is a final list index
  /// (already adjusted for the removal, as `onReorderItem` reports).
  static void reorder(int oldIndex, int newIndex) {
    final libraries = all();
    if (oldIndex < 0 || oldIndex >= libraries.length) return;
    final moved = libraries.removeAt(oldIndex);
    libraries.insert(newIndex.clamp(0, libraries.length), moved);
    save(libraries);
  }

  /// Removes the library and detaches it from every provenance record. Never
  /// uninstalls a source — the installed copy is independent of discovery.
  static void remove(String id) {
    final libraries = all()..removeWhere((e) => e.id == id);
    final map = _provenanceMap();
    for (final entry in map.entries) {
      final prov = SourceProvenance.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
      prov.libraryIds.remove(id);
      if (prov.originId == id) {
        prov.originId = null;
      }
      if (prov.updateLibraryId == id) {
        prov.updateLibraryId = prov.libraryIds.isNotEmpty
            ? prov.libraryIds.first
            : null;
      }
      map[entry.key] = prov.toJson();
    }
    _applyProvenanceMap(map);
    save(libraries);
  }

  static Map<String, dynamic> _provenanceMap() {
    final raw = appdata.settings[_provenanceKey];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return {};
  }

  static Map<String, String> _originDeclarations() {
    final raw = appdata.settings[_originsKey];
    if (raw is! Map) {
      return {};
    }
    final out = <String, String>{};
    raw.forEach((key, value) {
      final id = value?.toString();
      if (id != null && id.isNotEmpty) {
        out[key.toString()] = id;
      }
    });
    return out;
  }

  /// Stages [map] as the provenance store together with the refreshed portable
  /// declarations. Every provenance write goes through here so the two never
  /// drift apart; callers that already persist afterwards use this and skip
  /// [_writeProvenanceMap].
  static void _applyProvenanceMap(
    Map<String, dynamic> map, {
    Iterable<String> removedKeys = const [],
  }) {
    appdata.settings[_provenanceKey] = map;
    appdata.settings[_originsKey] = reconcileOriginDeclarations(
      provenance: map,
      declarations: _originDeclarations(),
      removedKeys: removedKeys,
    );
  }

  static void _writeProvenanceMap(
    Map<String, dynamic> map, {
    bool sync = true,
    Iterable<String> removedKeys = const [],
  }) {
    _applyProvenanceMap(map, removedKeys: removedKeys);
    appdata.saveData(sync);
  }

  static SourceProvenance? provenanceFor(String key) {
    final raw = _provenanceMap()[key];
    if (raw is Map) {
      return SourceProvenance.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  static void setProvenance(String key, SourceProvenance provenance) {
    final map = _provenanceMap();
    map[key] = provenance.toJson();
    _writeProvenanceMap(map);
  }

  /// Batch-writes provenance for many keys in a single persist. Used by the
  /// update checker so a full check does not schedule one sync upload per
  /// source. Saved without triggering an upload — discovery state is derived
  /// and will be rebuilt on the next check anyway.
  static void setProvenanceBatch(Map<String, SourceProvenance> entries) {
    if (entries.isEmpty) return;
    final map = _provenanceMap();
    entries.forEach((key, prov) => map[key] = prov.toJson());
    _writeProvenanceMap(map, sync: false);
  }

  /// Adopts the origin declarations that arrived with a backup import or a sync
  /// download, and returns the source keys whose governing library changed.
  ///
  /// Call it after the settings have been applied, so the library list the
  /// declarations reference is already in place. Adoption never deletes a local
  /// record: a source this device has but the incoming data does not mention
  /// keeps whatever it had. Saved without scheduling an upload — the data just
  /// came from the other side.
  static Set<String> adoptSyncedOrigins() {
    final incoming = _originDeclarations();
    final map = _provenanceMap();
    final changed = adoptOriginDeclarations(
      provenance: map,
      declarations: incoming,
      knownLibraryIds: all().map((e) => e.id).toSet(),
    );
    // Reconcile even when nothing was adopted: an incoming map replaces the
    // local declarations wholesale, so this device's own ones — and, on the
    // first launch after an upgrade, the ones never mirrored out before — have
    // to be written back before they can travel.
    final reconciled = reconcileOriginDeclarations(
      provenance: map,
      declarations: incoming,
    );
    if (changed.isEmpty && mapEquals(reconciled, incoming)) {
      return const {};
    }
    _writeProvenanceMap(map, sync: false);
    return changed;
  }

  /// Records a successful catalog fetch time for [id] without triggering a sync
  /// upload (purely device-local timing).
  static void markChecked(String id) {
    final libraries = all();
    final lib = _findIn(libraries, id);
    if (lib == null) return;
    lib.lastChecked = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < libraries.length; i++) {
      libraries[i].priority = i;
    }
    appdata.settings[_librariesKey] = libraries.map((e) => e.toJson()).toList();
    appdata.saveData(false);
  }

  /// Records the origin library for a freshly installed [key]. Keeps any
  /// previously discovered library ids.
  static void recordOrigin(String key, String libraryId) {
    final prov = provenanceFor(key) ?? SourceProvenance();
    prov.originId = libraryId;
    if (!prov.libraryIds.contains(libraryId)) {
      prov.libraryIds.add(libraryId);
    }
    setProvenance(key, prov);
  }

  /// Removes a source's provenance entirely, including its portable origin
  /// declaration so the uninstall propagates instead of being re-adopted from
  /// another device. Call only on genuine uninstall, never on an update-reload
  /// (which keeps the same key).
  static void clearProvenance(String key) {
    final map = _provenanceMap();
    if (map.remove(key) != null) {
      _writeProvenanceMap(map, removedKeys: [key]);
    }
  }

  /// Folds a legacy single `comicSourceListUrl` into the library list when it
  /// is set but not yet represented as a library. Runs on every init (not
  /// one-shot): this self-heals the case where a legacy URL arrives AFTER first
  /// launch via WebDAV sync or a backup import from an old-version device, which
  /// a one-shot flag would miss — leaving the URL field populated but zero
  /// libraries and discovery silently dead.
  ///
  /// It cannot resurrect a deliberately-deleted library: deleting libraries
  /// rewrites the mirror via [save] → `_primaryUrlOf`, so a removed library's
  /// URL no longer appears in `comicSourceListUrl` and is never re-folded. Uses
  /// `saveData(false)` to avoid scheduling an upload mid-initialization.
  static void migrateIfNeeded() {
    final legacy = (appdata.settings['comicSourceListUrl']?.toString() ?? '')
        .trim();
    final libraries = all();
    final alreadyPresent =
        legacy.isEmpty || findLibraryByUrl(libraries, legacy) != null;
    if (!alreadyPresent) {
      final id = allocateLibraryId(
        legacy,
        libraries.map((library) => library.id),
      );
      libraries.add(
        ComicSourceLibrary(
          id: id,
          name: defaultLibraryName(legacy),
          url: legacy,
          priority: libraries.length,
        ),
      );
      for (var i = 0; i < libraries.length; i++) {
        libraries[i].priority = i;
      }
      appdata.settings[_librariesKey] = libraries
          .map((e) => e.toJson())
          .toList();
      appdata.settings[_migratedKey] = true;
      appdata.saveData(false);
    } else if (appdata.settings[_migratedKey] != true) {
      // Nothing to fold, but record that migration has run at least once.
      appdata.settings[_migratedKey] = true;
      appdata.saveData(false);
    }
  }
}

import 'dart:convert';

import 'package:crypto/crypto.dart';
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
      id: json['id']?.toString() ?? stableLibraryId(json['url']?.toString() ?? ''),
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

/// Derives a stable, cross-device id from a catalog URL. Normalizes case and a
/// trailing slash so the same logical library produces the same id everywhere,
/// preventing duplicate entries and orphaned provenance after sync.
String stableLibraryId(String url) {
  var normalized = url.trim().toLowerCase();
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.isEmpty) {
    normalized = 'empty';
  }
  return md5.convert(utf8.encode(normalized)).toString().substring(0, 12);
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
    appdata.settings[_librariesKey] =
        libraries.map((e) => e.toJson()).toList();
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

  /// Adds a library for [url] if one with the same derived id is not already
  /// present. Returns the (possibly pre-existing) library.
  static ComicSourceLibrary add(String name, String url) {
    final libraries = all();
    final id = stableLibraryId(url);
    // Dedup by the URL's derived id, matching against each library's CURRENT
    // url rather than its stored id: a library edited to this url has a stored
    // id derived from its old url, so an id-only match would miss it and append
    // a duplicate pointing at the same catalog.
    ComicSourceLibrary? existing = _findIn(libraries, id);
    if (existing == null) {
      for (final l in libraries) {
        if (stableLibraryId(l.url) == id) {
          existing = l;
          break;
        }
      }
    }
    if (existing != null) {
      if (name.isNotEmpty) existing.name = name;
      save(libraries);
      return existing;
    }
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
  /// list, then re-densifies priority.
  static void reorder(int oldIndex, int newIndex) {
    final libraries = all();
    if (oldIndex < 0 || oldIndex >= libraries.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
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
    appdata.settings[_provenanceKey] = map;
    save(libraries);
  }

  static Map<String, dynamic> _provenanceMap() {
    final raw = appdata.settings[_provenanceKey];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    return {};
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
    appdata.settings[_provenanceKey] = map;
    appdata.saveData();
  }

  /// Batch-writes provenance for many keys in a single persist. Used by the
  /// update checker so a full check does not schedule one sync upload per
  /// source. Saved without triggering an upload — discovery state is derived
  /// and will be rebuilt on the next check anyway.
  static void setProvenanceBatch(Map<String, SourceProvenance> entries) {
    if (entries.isEmpty) return;
    final map = _provenanceMap();
    entries.forEach((key, prov) => map[key] = prov.toJson());
    appdata.settings[_provenanceKey] = map;
    appdata.saveData(false);
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
    appdata.settings[_librariesKey] =
        libraries.map((e) => e.toJson()).toList();
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

  /// Removes a source's provenance entirely. Call only on genuine uninstall,
  /// never on an update-reload (which keeps the same key).
  static void clearProvenance(String key) {
    final map = _provenanceMap();
    if (map.remove(key) != null) {
      appdata.settings[_provenanceKey] = map;
      appdata.saveData();
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
    final legacy =
        (appdata.settings['comicSourceListUrl']?.toString() ?? '').trim();
    final libraries = all();
    final id = legacy.isEmpty ? '' : stableLibraryId(legacy);
    final alreadyPresent =
        legacy.isEmpty ||
        libraries.any((e) => e.url == legacy || e.id == id);
    if (!alreadyPresent) {
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
      appdata.settings[_librariesKey] =
          libraries.map((e) => e.toJson()).toList();
      appdata.settings[_migratedKey] = true;
      appdata.saveData(false);
    } else if (appdata.settings[_migratedKey] != true) {
      // Nothing to fold, but record that migration has run at least once.
      appdata.settings[_migratedKey] = true;
      appdata.saveData(false);
    }
  }
}

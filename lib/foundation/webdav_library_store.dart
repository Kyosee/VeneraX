import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:venera/foundation/appdata.dart';

/// One configured WebDAV comic library: an address plus the credentials and
/// folder that together form a browsable comic collection.
///
/// Several libraries coexist (#171) — someone with a NAS at home and another at
/// work keeps both and switches by tapping. Each is exposed to the rest of the
/// app as its own comic source, so reading progress, favourites and image caches
/// of two servers never mix even when both hold a same-named folder.
class WebdavLibraryConfig {
  WebdavLibraryConfig({
    required this.id,
    required this.sourceKey,
    required this.name,
    required this.url,
    required this.user,
    required this.pass,
    required this.root,
    this.enabled = true,
    this.detectLinkedFolders = false,
    this.isInherited = false,
  });

  /// Stable identifier derived from the address/account/folder, so the same
  /// logical library converges to one entry on two synced devices instead of
  /// splitting into duplicates. Kept fixed across later edits.
  final String id;

  /// The comic-source key this library is registered under. Persisted rather
  /// than recomputed: it is baked into reading history, favourites and download
  /// records, so it must never drift once handed out.
  final String sourceKey;

  String name;
  String url;
  String user;
  String pass;

  /// Folder inside the server to treat as the library root. Empty = server root.
  String root;

  /// Disabled libraries stay registered (so old history still resolves) but are
  /// hidden from the browse entry points.
  bool enabled;

  /// Re-checks entries reported as files so servers that expose traversable
  /// directory symlinks inconsistently can still surface them as comics.
  bool detectLinkedFolders;

  /// True for the implicit library derived from the data-sync credentials, which
  /// is not persisted. Editing it saves a real config in its place.
  final bool isInherited;

  /// Normalized root, always a directory path with a trailing slash.
  String get rootPath {
    final r = root.trim();
    if (r.isEmpty) return '/';
    final withSlash = r.startsWith('/') ? r : '/$r';
    return withSlash.endsWith('/') ? withSlash : '$withSlash/';
  }

  /// Name to show, never empty.
  String get displayName => name.trim().isNotEmpty
      ? name.trim()
      : defaultWebdavLibraryName(url, root);

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceKey': sourceKey,
    'name': name,
    'url': url,
    'user': user,
    'pass': pass,
    'root': root,
    'enabled': enabled,
    'detectLinkedFolders': detectLinkedFolders,
  };

  factory WebdavLibraryConfig.fromJson(Map json) {
    final url = json['url']?.toString() ?? '';
    final user = json['user']?.toString() ?? '';
    final root = json['root']?.toString() ?? '';
    final id = json['id']?.toString() ?? stableWebdavLibraryId(url, user, root);
    return WebdavLibraryConfig(
      id: id,
      // Tolerate a record written before source keys were persisted by falling
      // back to the single-library key it would have used then.
      sourceKey: json['sourceKey']?.toString().isNotEmpty == true
          ? json['sourceKey'].toString()
          : WebdavLibraryStore.legacySourceKey,
      name: json['name']?.toString() ?? '',
      url: url,
      user: user,
      pass: json['pass']?.toString() ?? '',
      root: root,
      enabled: json['enabled'] != false,
      detectLinkedFolders: json['detectLinkedFolders'] == true,
    );
  }

  WebdavLibraryConfig copyWith({
    String? name,
    String? url,
    String? user,
    String? pass,
    String? root,
    bool? enabled,
    bool? detectLinkedFolders,
  }) => WebdavLibraryConfig(
    id: id,
    sourceKey: sourceKey,
    name: name ?? this.name,
    url: url ?? this.url,
    user: user ?? this.user,
    pass: pass ?? this.pass,
    root: root ?? this.root,
    enabled: enabled ?? this.enabled,
    detectLinkedFolders: detectLinkedFolders ?? this.detectLinkedFolders,
    isInherited: isInherited,
  );
}

/// Short deterministic id for the address/account/folder triple. Normalized so
/// cosmetic differences (case, trailing slashes, stray spaces) don't produce two
/// ids for the same library.
String stableWebdavLibraryId(String url, String user, String root) {
  var u = url.trim().toLowerCase();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  var r = root.trim();
  while (r.endsWith('/')) {
    r = r.substring(0, r.length - 1);
  }
  if (!r.startsWith('/')) r = '/$r';
  final seed = '$u|${user.trim()}|$r';
  return md5.convert(utf8.encode(seed)).toString().substring(0, 12);
}

/// Readable default name for a library the user didn't name: the host, plus the
/// folder when one is set, so two collections on the same server differ.
String defaultWebdavLibraryName(String url, String root) {
  final host = Uri.tryParse(url.trim())?.host ?? '';
  var base = host.isNotEmpty ? host : url.trim();
  if (base.isEmpty) base = 'WebDAV';
  var r = root.trim();
  while (r.endsWith('/')) {
    r = r.substring(0, r.length - 1);
  }
  while (r.startsWith('/')) {
    r = r.substring(1);
  }
  return r.isEmpty ? base : '$base/$r';
}

/// Picks the source key for a new library, given the keys already in use.
///
/// Normally derives a fresh key from the library's own id. Only when
/// [adoptLegacyKey] is set does it hand out the key the single-library build
/// used, and only if nothing holds it — that key carries reading history,
/// favourites and download records, so it may go to the library those records
/// actually describe and to no other. Handing it to an unrelated library (say,
/// the next one added after the original was deleted) would make the old
/// server's entries resurface against the new one.
///
/// Pure and unit-tested: a collision here would make two libraries shadow each
/// other, and a drift would strand a library's saved state.
String allocateWebdavLibrarySourceKey(
  Iterable<String> existingKeys,
  String id, {
  bool adoptLegacyKey = false,
}) {
  final used = existingKeys.toSet();
  if (adoptLegacyKey && !used.contains(WebdavLibraryStore.legacySourceKey)) {
    return WebdavLibraryStore.legacySourceKey;
  }
  var key = '${WebdavLibraryStore.sourceKeyPrefix}$id';
  var n = 2;
  while (used.contains(key)) {
    key = '${WebdavLibraryStore.sourceKeyPrefix}$id$n';
    n++;
  }
  return key;
}

/// Converts the old single-library setting value (`[url, user, pass, root]`)
/// into a config, or null when it holds no usable address. Pure so the upgrade
/// path can be tested without touching settings storage.
WebdavLibraryConfig? webdavLibraryFromLegacySetting(Object? legacy) {
  if (legacy is! List || legacy.length < 3) return null;
  final url = legacy[0];
  if (url is! String || url.trim().isEmpty) return null;
  final user = '${legacy[1] ?? ''}'.trim();
  final root = legacy.length > 3 ? '${legacy[3] ?? ''}'.trim() : '';
  return WebdavLibraryConfig(
    id: stableWebdavLibraryId(url, user, root),
    // Keeps every existing binding (history/favourites/downloads) intact.
    sourceKey: WebdavLibraryStore.legacySourceKey,
    name: '',
    url: url.trim(),
    user: user,
    pass: '${legacy[2] ?? ''}',
    root: root,
  );
}

/// Reads and writes the list of configured WebDAV comic libraries.
///
/// State lives in settings (so it rides along with data sync) and is read back
/// on every call rather than cached — a sync download or backup restore replaces
/// the whole settings map underneath us, and a cache would keep serving the
/// configuration the user just replaced.
abstract class WebdavLibraryStore {
  static const settingsKey = 'webdavComicLibraries';

  /// The single-library setting used before multiple addresses were supported.
  static const legacySettingsKey = 'webdavComicLibrary';

  /// Records that the legacy single-library setting has been folded in.
  ///
  /// A flag rather than clearing [legacySettingsKey]: settings travel through
  /// data sync, so wiping the old key here would leave a device still on an
  /// older build with no library at all after it synced from this one.
  static const migratedKey = 'webdavComicLibrariesMigrated';

  /// Source key of the one library that existed back then. Reused by whichever
  /// library is first in line so that history, favourites and downloads
  /// recorded before the upgrade keep resolving.
  static const legacySourceKey = 'webdav_library';

  static const sourceKeyPrefix = 'webdav_library_';

  /// Whether [key] belongs to any WebDAV library, past or present. Used by the
  /// surfaces that hide these built-in sources from source management.
  static bool isLibrarySourceKey(String key) =>
      key == legacySourceKey || key.startsWith(sourceKeyPrefix);

  /// The libraries the user explicitly configured, in display order.
  static List<WebdavLibraryConfig> all() {
    final raw = appdata.settings[settingsKey];
    if (raw is! List) return const [];
    final result = <WebdavLibraryConfig>[];
    final seenKeys = <String>{};
    final seenIds = <String>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final c = WebdavLibraryConfig.fromJson(e);
      if (c.url.trim().isEmpty) continue;
      // Two records claiming one source key would collide on registration and
      // silently shadow each other; two sharing an id would collide as list
      // keys in the manage screen. Neither is reachable through the normal
      // edit paths, but a hand-edited or foreign settings payload could carry
      // it, and dropping the later copy beats crashing the page.
      if (!seenKeys.add(c.sourceKey)) continue;
      if (!seenIds.add(c.id)) continue;
      result.add(c);
    }
    return result;
  }

  /// What the app should actually expose: the configured libraries, or — when
  /// none was ever set — one implicit library borrowed from the data-sync
  /// credentials, so someone who already set up sync can browse that same
  /// server without typing anything again.
  static List<WebdavLibraryConfig> effective() {
    final own = all();
    if (own.isNotEmpty) return own;
    final inherited = inheritedFromSync();
    return inherited == null ? const [] : [inherited];
  }

  /// Libraries offered in the browse entry points (configured and enabled).
  static List<WebdavLibraryConfig> visible() =>
      effective().where((e) => e.enabled).toList();

  static bool get hasAny => effective().isNotEmpty;

  static WebdavLibraryConfig? findBySourceKey(String? sourceKey) {
    if (sourceKey == null) return null;
    for (final c in effective()) {
      if (c.sourceKey == sourceKey) return c;
    }
    return null;
  }

  static WebdavLibraryConfig? find(String id) {
    for (final c in effective()) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The implicit library built from the data-sync WebDAV credentials, or null
  /// when sync isn't configured either.
  static WebdavLibraryConfig? inheritedFromSync() {
    final raw = appdata.settings['webdav'];
    if (raw is! List || raw.length < 3) return null;
    final url = raw[0];
    if (url is! String || url.trim().isEmpty) return null;
    return WebdavLibraryConfig(
      id: stableWebdavLibraryId(url, '${raw[1] ?? ''}', ''),
      sourceKey: legacySourceKey,
      name: '',
      url: url.trim(),
      user: '${raw[1] ?? ''}'.trim(),
      pass: '${raw[2] ?? ''}',
      root: '',
      isInherited: true,
    );
  }

  /// Folds the old single-library setting into the list, once.
  ///
  /// Runs before sources are registered. Guarded by [migratedKey] rather than by
  /// the list being empty, so deleting every library doesn't resurrect the old
  /// entry on the next launch. A device that receives a legacy-only settings
  /// payload from an older peer still folds it in, since the flag travels with
  /// the same settings that carry the list.
  static void migrateIfNeeded() {
    if (appdata.settings[migratedKey] == true) return;
    final config = webdavLibraryFromLegacySetting(
      appdata.settings[legacySettingsKey],
    );
    if (config == null) {
      // Nothing to fold; still record that the fold has run so a library the
      // user later deletes doesn't get replaced by a stale legacy value.
      appdata.settings[migratedKey] = true;
      appdata.saveData(false);
      return;
    }
    if (all().isEmpty) {
      appdata.settings[settingsKey] = [config.toJson()];
    }
    appdata.settings[migratedKey] = true;
    // Folding a legacy setting at startup is not a user edit, so it must not
    // trigger a sync upload of its own (same policy as the source-library fold).
    appdata.saveData(false);
  }

  /// Adds a library and returns it, or null when [url] is blank. A repeat of an
  /// existing address/account/folder updates that entry instead of adding a
  /// second copy of it.
  static WebdavLibraryConfig? add({
    required String name,
    required String url,
    required String user,
    required String pass,
    required String root,
    bool detectLinkedFolders = false,
  }) {
    if (url.trim().isEmpty) return null;
    final list = all();
    final id = stableWebdavLibraryId(url, user, root);
    final existingIndex = list.indexWhere((e) => e.id == id);
    if (existingIndex >= 0) {
      final updated = list[existingIndex].copyWith(
        name: name.trim(),
        url: url.trim(),
        user: user.trim(),
        pass: pass,
        root: root.trim(),
        detectLinkedFolders: detectLinkedFolders,
      );
      list[existingIndex] = updated;
      _write(list);
      return updated;
    }
    final config = WebdavLibraryConfig(
      id: id,
      // Saving the implicit sync-derived library turns it into a real entry, so
      // it keeps the source key its comics were already recorded under. Matched
      // on server and account only (the inherited id is computed with no
      // folder), so also narrowing it to a subfolder still counts as the same
      // library. Any other new library gets a key of its own.
      sourceKey: allocateWebdavLibrarySourceKey(
        list.map((e) => e.sourceKey),
        id,
        adoptLegacyKey:
            list.isEmpty &&
            inheritedFromSync()?.id == stableWebdavLibraryId(url, user, ''),
      ),
      name: name.trim(),
      url: url.trim(),
      user: user.trim(),
      pass: pass,
      root: root.trim(),
      detectLinkedFolders: detectLinkedFolders,
    );
    list.add(config);
    _write(list);
    return config;
  }

  /// Edits a library in place. The id and source key stay put even when the
  /// address changes, so a server that moved to a new hostname keeps its
  /// history instead of reappearing as a fresh library.
  static WebdavLibraryConfig? update(
    String id, {
    String? name,
    String? url,
    String? user,
    String? pass,
    String? root,
    bool? enabled,
    bool? detectLinkedFolders,
  }) {
    final list = all();
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return null;
    final updated = list[index].copyWith(
      name: name?.trim(),
      url: url?.trim(),
      user: user?.trim(),
      pass: pass,
      root: root?.trim(),
      enabled: enabled,
      detectLinkedFolders: detectLinkedFolders,
    );
    if (updated.url.isEmpty) return null;
    list[index] = updated;
    _write(list);
    return updated;
  }

  static void setEnabled(String id, bool enabled) {
    update(id, enabled: enabled);
  }

  static void remove(String id) {
    final list = all()..removeWhere((e) => e.id == id);
    _write(list);
  }

  /// Moves a library within the display order. [newIndex] is a final list index
  /// with the removal already accounted for, matching what `onReorderItem`
  /// reports.
  static void reorder(int oldIndex, int newIndex) {
    final list = all();
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), item);
    _write(list);
  }

  static void _write(List<WebdavLibraryConfig> list) {
    appdata.settings[settingsKey] = list.map((e) => e.toJson()).toList();
    appdata.saveData();
  }
}

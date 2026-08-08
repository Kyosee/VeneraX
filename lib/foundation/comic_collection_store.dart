import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';

/// How a collection lays out the chapters of its members.
enum CollectionDisplayMode {
  /// One flat chapter list: every member's chapters appended in member order.
  /// For members that are each a single instalment of one story.
  flat,

  /// One group tab per member, using the existing grouped-chapter UI. For
  /// members that are each a multi-chapter volume of their own.
  tabs;

  static CollectionDisplayMode fromName(String? name) =>
      name == tabs.name ? tabs : flat;
}

/// One member comic of a collection: a reference into some other source, plus
/// the last known display fields.
///
/// The cached title/cover exist so the manage screen, the group tab labels and
/// the collection's own fallback cover still render when the member's source is
/// offline, uninstalled or slow. They are refreshed whenever the member loads
/// successfully.
class CollectionMember {
  CollectionMember({
    required this.sourceKey,
    required this.comicId,
    this.displayName = '',
    this.cachedTitle = '',
    this.cachedSubtitle = '',
    this.cachedCover = '',
  });

  final String sourceKey;
  final String comicId;

  /// User-chosen label. In [CollectionDisplayMode.tabs] this is the tab name.
  String displayName;

  String cachedTitle;
  String cachedSubtitle;
  String cachedCover;

  /// Label to show, never empty.
  String get label => displayName.trim().isNotEmpty
      ? displayName.trim()
      : (cachedTitle.trim().isNotEmpty ? cachedTitle.trim() : comicId);

  /// Identity within a collection. Two different sources may well use the same
  /// comic id, so membership is keyed on the pair.
  String get refKey => '$sourceKey/$comicId';

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'comicId': comicId,
    'displayName': displayName,
    'cachedTitle': cachedTitle,
    'cachedSubtitle': cachedSubtitle,
    'cachedCover': cachedCover,
  };

  factory CollectionMember.fromJson(Map json) => CollectionMember(
    sourceKey: json['sourceKey']?.toString() ?? '',
    comicId: json['comicId']?.toString() ?? '',
    displayName: json['displayName']?.toString() ?? '',
    cachedTitle: json['cachedTitle']?.toString() ?? '',
    cachedSubtitle: json['cachedSubtitle']?.toString() ?? '',
    cachedCover: json['cachedCover']?.toString() ?? '',
  );
}

/// A user-assembled collection: several comics, possibly from different
/// sources, presented as one comic.
///
/// Each collection is exposed to the rest of the app as its own comic source
/// (same trick as a WebDAV library), so the reader, history, favourites and
/// downloads treat it like any other comic with no changes to those paths.
class ComicCollection {
  ComicCollection({
    required this.id,
    required this.sourceKey,
    required this.name,
    required this.members,
    this.customCover = '',
    this.displayMode = CollectionDisplayMode.flat,
    required this.createdAt,
  });

  final String id;

  /// The comic-source key this collection is registered under. Persisted, never
  /// recomputed: reading history, favourites and download records are all keyed
  /// on it, so it must not drift once handed out.
  final String sourceKey;

  /// User-chosen name. Falls back to the first member's title when empty.
  String name;

  /// User-chosen cover. Falls back to the first member's cover when empty.
  String customCover;

  CollectionDisplayMode displayMode;

  List<CollectionMember> members;

  final DateTime createdAt;

  String get displayName {
    final n = name.trim();
    if (n.isNotEmpty) return n;
    for (final m in members) {
      if (m.cachedTitle.trim().isNotEmpty) return m.cachedTitle.trim();
    }
    return id;
  }

  String get displayCover {
    final c = customCover.trim();
    if (c.isNotEmpty) return c;
    for (final m in members) {
      if (m.cachedCover.trim().isNotEmpty) return m.cachedCover.trim();
    }
    return '';
  }

  /// The member whose cover the collection currently borrows, or null when the
  /// cover is the user's own. Image loading needs it: fetching that cover may
  /// require the member source's auth headers.
  CollectionMember? get coverOwner {
    if (customCover.trim().isNotEmpty) return null;
    for (final m in members) {
      if (m.cachedCover.trim().isNotEmpty) return m;
    }
    return null;
  }

  bool contains(String sourceKey, String comicId) =>
      members.any((e) => e.sourceKey == sourceKey && e.comicId == comicId);

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceKey': sourceKey,
    'name': name,
    'customCover': customCover,
    'displayMode': displayMode.name,
    'members': members.map((e) => e.toJson()).toList(),
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  factory ComicCollection.fromJson(Map json) {
    final id = json['id']?.toString() ?? '';
    final rawMembers = json['members'];
    final members = <CollectionMember>[];
    if (rawMembers is List) {
      final seen = <String>{};
      for (final e in rawMembers) {
        if (e is! Map) continue;
        final m = CollectionMember.fromJson(e);
        if (m.sourceKey.isEmpty || m.comicId.isEmpty) continue;
        // A collection inside a collection would recurse when loading chapters;
        // reject it here too, not just at the add path, since settings travel
        // between devices and could carry a hand-edited payload.
        if (ComicCollectionStore.isCollectionSourceKey(m.sourceKey)) continue;
        if (!seen.add(m.refKey)) continue;
        members.add(m);
      }
    }
    return ComicCollection(
      id: id,
      sourceKey: json['sourceKey']?.toString().isNotEmpty == true
          ? json['sourceKey'].toString()
          : '${ComicCollectionStore.sourceKeyPrefix}$id',
      name: json['name']?.toString() ?? '',
      customCover: json['customCover']?.toString() ?? '',
      displayMode: CollectionDisplayMode.fromName(
        json['displayMode']?.toString(),
      ),
      members: members,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        json['createdAt'] is int ? json['createdAt'] as int : 0,
      ),
    );
  }
}

/// Change notifier for the collection list. A thin subclass because
/// [ChangeNotifier.notifyListeners] is protected and the store is not itself a
/// notifier (it holds no state — everything is read back from settings).
class _CollectionChanges extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// Reads and writes the user's comic collections.
///
/// State lives in settings so it rides along with data sync and backups. Read
/// back on every call rather than cached: a sync download or backup restore
/// replaces the whole settings map underneath us, and a cache would keep
/// serving the configuration the user just replaced.
abstract class ComicCollectionStore {
  /// Fires whenever a collection is created, edited or removed.
  ///
  /// Settings already notify on write, but the surfaces that show comics don't
  /// listen to settings — a tile needs to know when a member's cached cover or
  /// title landed so it can stop showing a blank cover.
  static final changes = _CollectionChanges();

  static const settingsKey = 'comicCollections';

  static const sourceKeyPrefix = 'comic_collection_';

  /// Whether [key] belongs to a collection. Used to hide these built-in sources
  /// from source management, to suppress the source badge on a collection (its
  /// members may come from several sources), and to stop a collection from being
  /// added to another collection.
  static bool isCollectionSourceKey(String? key) =>
      key != null && key.startsWith(sourceKeyPrefix);

  /// Always returns a fresh, mutable list: callers add, remove and reorder in
  /// place before writing back, so handing out a const literal for the
  /// not-yet-configured case would throw on the first edit.
  static List<ComicCollection> all() {
    final result = <ComicCollection>[];
    final raw = appdata.settings[settingsKey];
    if (raw is! List) return result;
    final seenIds = <String>{};
    final seenKeys = <String>{};
    for (final e in raw) {
      if (e is! Map) continue;
      final c = ComicCollection.fromJson(e);
      if (c.id.isEmpty) continue;
      // Duplicate ids would collide as list keys in the manage screen, and
      // duplicate source keys would shadow each other on registration.
      if (!seenIds.add(c.id)) continue;
      if (!seenKeys.add(c.sourceKey)) continue;
      result.add(c);
    }
    return result;
  }

  static bool get hasAny => all().isNotEmpty;

  static ComicCollection? find(String id) {
    for (final c in all()) {
      if (c.id == id) return c;
    }
    return null;
  }

  static ComicCollection? findBySourceKey(String? sourceKey) {
    if (sourceKey == null) return null;
    for (final c in all()) {
      if (c.sourceKey == sourceKey) return c;
    }
    return null;
  }

  /// Collections that already hold the given comic.
  static List<ComicCollection> containing(String sourceKey, String comicId) =>
      all().where((c) => c.contains(sourceKey, comicId)).toList();

  /// Creates a collection. Members that are themselves collections are dropped.
  static ComicCollection create({
    String name = '',
    List<CollectionMember> members = const [],
    CollectionDisplayMode displayMode = CollectionDisplayMode.flat,
  }) {
    final list = all();
    final id = _newId(list.map((e) => e.id).toSet());
    final collection = ComicCollection(
      id: id,
      sourceKey: '$sourceKeyPrefix$id',
      name: name.trim(),
      members: _sanitize(members, const []),
      displayMode: displayMode,
      createdAt: DateTime.now(),
    );
    list.add(collection);
    _write(list);
    return collection;
  }

  static ComicCollection? update(
    String id, {
    String? name,
    String? customCover,
    CollectionDisplayMode? displayMode,
    List<CollectionMember>? members,
  }) {
    final list = all();
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return null;
    final c = list[index];
    if (name != null) c.name = name.trim();
    if (customCover != null) c.customCover = customCover.trim();
    if (displayMode != null) c.displayMode = displayMode;
    if (members != null) c.members = _sanitize(members, const []);
    _write(list);
    return c;
  }

  /// Appends members, skipping ones already present and any collection.
  /// Returns how many were actually added.
  static int addMembers(String id, List<CollectionMember> incoming) {
    final list = all();
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return 0;
    final c = list[index];
    final before = c.members.length;
    c.members = [...c.members, ..._sanitize(incoming, c.members)];
    if (c.members.length == before) return 0;
    _write(list);
    return c.members.length - before;
  }

  static void removeMember(String id, String sourceKey, String comicId) {
    final list = all();
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final c = list[index];
    c.members.removeWhere(
      (e) => e.sourceKey == sourceKey && e.comicId == comicId,
    );
    _write(list);
  }

  /// Moves a member within the collection. [newIndex] is a final list index
  /// with the removal already accounted for, matching `onReorderItem`.
  static void reorderMember(String id, int oldIndex, int newIndex) {
    final list = all();
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final members = list[index].members;
    if (oldIndex < 0 || oldIndex >= members.length) return;
    final item = members.removeAt(oldIndex);
    members.insert(newIndex.clamp(0, members.length), item);
    _write(list);
  }

  /// Writes back the display fields of a member that just loaded, so the
  /// manage screen and cover fallback survive that source going away.
  ///
  /// Silently does nothing when the collection or member is gone: this runs
  /// from a detail load the user may have already navigated away from.
  static void cacheMemberInfo(
    String id,
    String sourceKey,
    String comicId, {
    String? title,
    String? subtitle,
    String? cover,
  }) {
    final list = all();
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final member = list[index].members.firstWhere(
      (e) => e.sourceKey == sourceKey && e.comicId == comicId,
      orElse: () => CollectionMember(sourceKey: '', comicId: ''),
    );
    if (member.sourceKey.isEmpty) return;
    var changed = false;
    if (title != null && title.isNotEmpty && title != member.cachedTitle) {
      member.cachedTitle = title;
      changed = true;
    }
    if (subtitle != null && subtitle != member.cachedSubtitle) {
      member.cachedSubtitle = subtitle;
      changed = true;
    }
    if (cover != null && cover.isNotEmpty && cover != member.cachedCover) {
      member.cachedCover = cover;
      changed = true;
    }
    // Only persist on a real change: this is called on every detail load, and
    // an unconditional write would bump the sync data version each time.
    if (changed) _write(list);
  }

  static void remove(String id) {
    final list = all()..removeWhere((e) => e.id == id);
    _write(list);
  }

  static void reorder(int oldIndex, int newIndex) {
    final list = all();
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), item);
    _write(list);
  }

  /// Drops blanks, collections and anything already in [existing].
  static List<CollectionMember> _sanitize(
    Iterable<CollectionMember> incoming,
    Iterable<CollectionMember> existing,
  ) {
    final seen = existing.map((e) => e.refKey).toSet();
    final result = <CollectionMember>[];
    for (final m in incoming) {
      if (m.sourceKey.isEmpty || m.comicId.isEmpty) continue;
      if (isCollectionSourceKey(m.sourceKey)) continue;
      if (!seen.add(m.refKey)) continue;
      result.add(m);
    }
    return result;
  }

  /// Random id rather than a content hash: two devices each creating a
  /// collection with the same members mean two collections, not one.
  static String _newId(Set<String> used) {
    final rand = Random();
    while (true) {
      final id =
          '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
          '${rand.nextInt(0x10000).toRadixString(36).padLeft(4, '0')}';
      if (!used.contains(id)) return id;
    }
  }

  static void _write(List<ComicCollection> list) {
    appdata.settings[settingsKey] = list.map((e) => e.toJson()).toList();
    appdata.saveData();
    notifyChanged();
  }

  /// Announces a change to the collection list. Public so the callers that
  /// rebuild sources after an edit can also refresh what's on screen.
  static void notifyChanged() {
    // Deferred: writes happen during a detail load, which can be mid-build, and
    // notifying listeners then would rebuild during layout.
    Future.microtask(changes.ping);
  }
}

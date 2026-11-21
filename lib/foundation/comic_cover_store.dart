import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

/// Personal cover choices. Both comic IDs and source keys are opaque strings.
abstract final class ComicCoverStore {
  static const settingsKey = 'customComicCovers';
  static const inheritedWebdavKey = 'webdavInheritedCustomCovers';
  static const _collections = ComicCollectionStore.settingsKey;
  static const imageExtensions = ['jpg', 'jpeg', 'png', 'webp', 'gif'];
  static final _fileName = RegExp(
    r'^[A-Za-z0-9_-]+\.(?:jpe?g|png|webp|gif)$',
    caseSensitive: false,
  );

  static final changes = ValueNotifier<int>(0);

  static void notifyChanged() {
    changes.value++;
    ComicCollectionStore.notifyChanged();
  }

  static String? nameOf(Object? ref) {
    if (ref is! String || !ref.startsWith(ComicCollectionStore.localCoverScheme)) {
      return null;
    }
    final name = ref.substring(ComicCollectionStore.localCoverScheme.length);
    return name.length <= 200 && _fileName.hasMatch(name) ? name : null;
  }

  static File? fileFor(Object? ref) {
    final name = nameOf(ref);
    return name == null ? null : File(FilePath.join(
      App.dataPath, ComicCollectionStore.coverDirName, name,
    ));
  }

  static String? reference(String sourceKey, String comicId) {
    final sources = appdata.settings[settingsKey];
    if (sources is! Map) return null;
    final comics = sources[_storedSource(sources, sourceKey, comicId)];
    final value = comics is Map ? comics[comicId] : null;
    return nameOf(value) != null ? value as String : null;
  }

  static ComicType sourceType(String key) {
    final value = key.startsWith('Unknown:') ? int.tryParse(key.substring(8)) : null;
    return value == null ? ComicType.fromKey(key) : ComicType(value);
  }

  static String _storedSource(Map sources, String key, String id) {
    bool hasBook(String source) => sources[source] is Map && sources[source].containsKey(id);
    if (sources.isEmpty || hasBook(key)) return key;
    final type = sourceType(key);
    if (key.startsWith('Unknown:')) {
      for (final stored in sources.keys.whereType<String>()) {
        if (hasBook(stored) && sourceType(stored) == type) return stored;
      }
    } else {
      final unknown = 'Unknown:${type.value}';
      if (hasBook(unknown)) return unknown;
    }
    return key;
  }

  static Future<void> setFile(
    String sourceKey, String comicId, FileSelectResult selected,
  ) async {
    final ref = await _storeImage(selected.name, selected.saveTo);
    await setReference(sourceKey, comicId, ref);
  }

  static Future<String> _storeImage(String name, Future<void> Function(String) write) async {
    final ext = name.split('.').last.toLowerCase();
    if (!imageExtensions.contains(ext)) {
      throw const FormatException('Invalid cover image extension');
    }
    final ref = ComicCollectionStore.localCoverRef('${const Uuid().v4()}.$ext');
    final target = fileFor(ref)!;
    await installFile(target, write);
    return ref;
  }

  static Future<String?> _localMemberCover(CollectionMember member) async {
    if (!LocalManager().isInitialized || ComicType.fromKey(member.sourceKey) != ComicType.local) {
      return null;
    }
    final file = LocalManager().find(member.comicId, ComicType.local)?.coverFile;
    if (file == null || !await file.exists()) return null;
    return _storeImage(file.name, file.copyMem);
  }

  static Future<void> setMemberCover(ComicCollection collection, CollectionMember member) async {
    var ref = member.coverReference;
    if (ref.startsWith('file://')) {
      ref = await _localMemberCover(member) ?? (throw const FormatException('Missing local cover'));
    }
    await setReference(collection.sourceKey, collection.id, ref);
  }

  /// Older collections could point directly at a file on the original device.
  static Future<Map<String, dynamic>> forExport({Set<String>? collectionIds}) async {
    final covers = current;
    final choices = covers[_collections] as Map<String, dynamic>;
    for (final entry in choices.entries.toList()) {
      if (!(entry.value as String).startsWith('file://') ||
          (collectionIds != null && !collectionIds.contains(entry.key))) continue;
      final collection = ComicCollectionStore.find(entry.key);
      final member = collection?.members.where((m) => m.cachedCover == entry.value).firstOrNull;
      final ref = member == null ? null : await _localMemberCover(member);
      if (ref == null) {
        choices.remove(entry.key);
      } else {
        choices[entry.key] = ref;
        if (ComicCollectionStore.find(entry.key)?.customCover == entry.value) {
          ComicCollectionStore.update(entry.key, customCover: ref);
        }
      }
    }
    return covers;
  }

  static Future<void> reset(String sourceKey, String comicId) =>
      setReference(sourceKey, comicId, '');

  static Future<void> setReference(String sourceKey, String comicId, String ref) async {
    if (ComicCollectionStore.isCollectionSourceKey(sourceKey) &&
        ComicCollectionStore.find(comicId)?.sourceKey == sourceKey) {
      ComicCollectionStore.update(comicId, customCover: ref);
    } else {
      final sources = Map<String, dynamic>.from(appdata.settings[settingsKey] ?? {});
      sourceKey = _storedSource(sources, sourceKey, comicId);
      final comics = Map<String, dynamic>.from(sources[sourceKey] ?? {});
      if (ref.isEmpty) {
        comics.remove(comicId);
      } else {
        comics[comicId] = ref;
      }
      if (comics.isEmpty) {
        sources.remove(sourceKey);
      } else {
        sources[sourceKey] = comics;
      }
      appdata.settings[settingsKey] = sources;
    }
    notifyChanged();
    await appdata.saveData();
  }

  /// Extract portable choices without retaining mutable settings or member data.
  static Map<String, dynamic> snapshot(Map settings) {
    final sources = settings[settingsKey];
    final collections = settings[_collections];
    return {
      if (settings[inheritedWebdavKey] is String) inheritedWebdavKey: settings[inheritedWebdavKey],
      if (sources is Map) settingsKey: {
        for (final source in sources.entries)
          if (source.key is String && source.value is Map)
            source.key as String: {
              for (final comic in (source.value as Map).entries)
                if (comic.key is String && nameOf(comic.value) != null)
                  comic.key as String: comic.value,
            },
      },
      if (collections is List) _collections: {
        for (final collection in collections.whereType<Map>())
          if (collection['id'] is String &&
              collection['customCover'] is String &&
              (collection['customCover'] as String).isNotEmpty)
            collection['id'] as String: collection['customCover'],
      },
    };
  }

  static Set<String> fileNames(Map covers) {
    final singles = covers[settingsKey];
    final collections = covers[_collections];
    return {
      if (singles is Map)
        for (final comics in singles.values.whereType<Map>())
          ...comics.values.map(nameOf).nonNulls,
      if (collections is Map) ...collections.values.map(nameOf).nonNulls,
    };
  }

  /// At startup no in-process export or restore is still reading an old choice.
  static Future<void> pruneUnusedAtStartup(Map settings) async {
    final directory = Directory(FilePath.join(App.dataPath, ComicCollectionStore.coverDirName));
    try {
      if (!await directory.exists()) return;
      final used = fileNames(snapshot(settings));
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && _fileName.hasMatch(entry.name) && !used.contains(entry.name)) {
          await entry.deleteIgnoreError();
        }
      }
    } on FileSystemException {
      // A busy or inaccessible cover directory can be retried on the next launch.
    }
  }

  /// Installs a complete image before exposing its permanent name to readers.
  static Future<void> installFile(File target, Future<void> Function(String) write) async {
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.${const Uuid().v4()}.tmp');
    try {
      await write(temp.path);
      if (await temp.length() == 0) throw const FormatException('Empty cover image');
      await temp.rename(target.path);
    } finally {
      await temp.deleteIgnoreError();
    }
  }

  static Future<void> installFiles(Map covers, Directory root, {bool requireAll = true}) async {
    for (final name in fileNames(covers)) {
      final target = fileFor(ComicCollectionStore.localCoverRef(name))!;
      final source = File(FilePath.join(root.path, ComicCollectionStore.coverDirName, name));
      if (await source.exists()) {
        await installFile(target, (path) async { await source.copy(path); });
      } else if (requireAll && !await target.exists()) {
        throw const FormatException('Missing custom cover image');
      }
    }
  }

  static Future<void> requireFiles(Map covers) async {
    for (final name in fileNames(covers)) {
      final file = fileFor(ComicCollectionStore.localCoverRef(name))!;
      if (!await file.exists() || await file.length() == 0) {
        throw const FormatException('Missing custom cover image');
      }
    }
  }

  /// A missing section belongs to an older/partial backup; an empty one resets it.
  static void applyToSettings(Map settings, Map covers) {
    if (covers[settingsKey] is Map) settings[settingsKey] = covers[settingsKey];
    final choices = covers[_collections];
    final collections = settings[_collections];
    if (choices is Map && collections is List) {
      settings[_collections] = [
        for (final collection in collections)
          if (collection is Map)
            {...collection, 'customCover': choices[collection['id']] ?? ''}
          else
            collection,
      ];
    }
  }

  static Map<String, dynamic> get current => snapshot({
    settingsKey: appdata.settings[settingsKey] ?? const {},
    _collections: appdata.settings[_collections] ?? const [],
  });
}

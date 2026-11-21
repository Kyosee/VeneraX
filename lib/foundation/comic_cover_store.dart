import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/utils/io.dart';

/// Personal cover choices. Both comic IDs and source keys are opaque strings.
abstract final class ComicCoverStore {
  static const settingsKey = 'customComicCovers';
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
    final comics = sources[sourceKey];
    final value = comics is Map ? comics[comicId] : null;
    return nameOf(value) != null ? value as String : null;
  }

  static Future<void> setFile(
    String sourceKey, String comicId, FileSelectResult selected,
  ) async {
    final ext = selected.name.split('.').last.toLowerCase();
    if (!imageExtensions.contains(ext)) {
      throw const FormatException('Invalid cover image extension');
    }
    final ref = ComicCollectionStore.localCoverRef('${const Uuid().v4()}.$ext');
    final target = fileFor(ref)!;
    await target.parent.create(recursive: true);
    try {
      await selected.saveTo(target.path);
      if (await target.length() == 0) throw const FormatException('Empty cover image');
    } catch (_) {
      await target.deleteIgnoreError();
      rethrow;
    }
    await setReference(sourceKey, comicId, ref);
  }

  static Future<void> reset(String sourceKey, String comicId) =>
      setReference(sourceKey, comicId, '');

  static Future<void> setReference(String sourceKey, String comicId, String ref) async {
    if (ComicCollectionStore.isCollectionSourceKey(sourceKey) &&
        ComicCollectionStore.find(comicId)?.sourceKey == sourceKey) {
      ComicCollectionStore.update(comicId, customCover: ref);
    } else {
      final sources = Map<String, dynamic>.from(appdata.settings[settingsKey] ?? {});
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

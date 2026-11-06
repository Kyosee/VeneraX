import 'package:venera/foundation/appdata.dart';

/// Where the reader moved the gallery's pairing by hand, per chapter: the
/// 0-based images a screen starts at. Synced with the user's settings.
abstract class GalleryPageShifts {
  static const settingKey = 'galleryPageShifts';

  static String _comicKey(String cid, String sourceKey) => '$cid@$sourceKey';

  static Map<String, dynamic> _stringKeyed(Object? raw) => {
    if (raw is Map)
      for (final e in raw.entries)
        if (e.key is String) e.key as String: e.value,
  };

  static Set<int> load(String cid, String sourceKey, String chapterId) {
    final all = appdata.settings[settingKey];
    final comic = all is Map ? all[_comicKey(cid, sourceKey)] : null;
    final stored = comic is Map ? comic[chapterId] : null;
    if (stored is! List) return const {};
    return {
      for (final i in stored)
        if (i is int) i,
    };
  }

  /// Saves [shifts] for the chapter; an empty set removes its entry, and the
  /// comic's once none of its chapters has any.
  static Future<void> save(
    String cid,
    String sourceKey,
    String chapterId,
    Set<int> shifts,
  ) {
    final all = _stringKeyed(appdata.settings[settingKey]);
    final key = _comicKey(cid, sourceKey);
    final comic = _stringKeyed(all[key]);
    if (shifts.isEmpty) {
      comic.remove(chapterId);
    } else {
      comic[chapterId] = shifts.toList()..sort();
    }
    if (comic.isEmpty) {
      all.remove(key);
    } else {
      all[key] = comic;
    }
    appdata.settings[settingKey] = all;
    return appdata.saveData();
  }
}

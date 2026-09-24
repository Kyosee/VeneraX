import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';

/// Flat indices whose title repeats an earlier entry **within the same scope**.
///
/// [scopes] partitions the flat index space; pass null to treat everything as
/// one scope. Indices covered by no scope are never reported. Titles are
/// compared trimmed; blank titles are skipped, since collapsing them would hide
/// unrelated chapters that merely lack a name.
Set<int> findDuplicateTitleIndices({
  required int count,
  required String Function(int index) titleOf,
  List<List<int>>? scopes,
}) {
  final res = <int>{};
  for (final scope in scopes ?? [List.generate(count, (i) => i)]) {
    final seen = <String>{};
    for (final i in scope) {
      if (i < 0 || i >= count) continue;
      final title = titleOf(i).trim();
      if (title.isEmpty) continue;
      if (!seen.add(title)) res.add(i);
    }
  }
  return res;
}

/// The first chapter reached from [from] by repeated [step] that isn't hidden,
/// or null when none is reachable. 1-based, mirroring reader chapter numbers.
/// [order] contains the original chapter numbers in custom reading order.
///
/// The first step may leave [from]'s group, as plain `±1` always has. Skipping
/// hidden chapters must not carry us further than that, though: callers guard
/// group edges separately, and a skip that crossed a second boundary would slip
/// past that guard.
int? nextVisibleChapter({
  required int from,
  required int step,
  required int maxChapter,
  required bool Function(int chapter) isHidden,
  required int Function(int chapter) groupOf,
  List<int>? order,
}) {
  if (step != 1 && step != -1) return null;
  var position = order?.indexOf(from) ?? from - 1;
  if (position < 0 || from < 1 || from > maxChapter) return null;
  int? chapterAt(int index) {
    if (index < 0 || index >= (order?.length ?? maxChapter)) return null;
    final chapter = order?[index] ?? index + 1;
    return chapter >= 1 && chapter <= maxChapter ? chapter : null;
  }

  var c = chapterAt(position += step);
  if (c == null) return null;
  if (!isHidden(c)) return c;
  // The landing chapter is hidden, so we must keep stepping — but only inside
  // [from]'s own group. Crossing a boundary is a single deliberate step the
  // caller guards separately (isLastChapterOfGroup); searching on past one
  // would slip through that guard and drop the reader mid-group.
  final group = groupOf(from);
  do {
    c = chapterAt(position += step);
    if (c == null || groupOf(c) != group) return null;
  } while (isHidden(c));
  return c;
}

extension ChapterDuplicateDetection on ComicChapters {
  /// Flat 0-based indices of chapters whose title repeats an earlier chapter of
  /// the SAME group. Groups stay independent on purpose: separate editions
  /// ("English", "Español") may each legitimately carry a "第一话".
  Set<int> duplicateTitleIndices() {
    final all = titles.toList();
    List<List<int>>? scopes;
    if (isGrouped) {
      scopes = [];
      var flat = 0;
      for (final name in groups) {
        final size = getGroup(name).length;
        scopes.add(List.generate(size, (i) => flat + i));
        flat += size;
      }
    }
    return findDuplicateTitleIndices(
      count: all.length,
      titleOf: (i) => all[i],
      scopes: scopes,
    );
  }
}

/// Per-comic "hide duplicate chapters" switch.
///
/// Device-local (implicitData, not part of the backup whitelist): it only
/// changes how one comic's chapter list is rendered, and every consumer treats
/// the flat chapter index as authoritative, so a device that has it off still
/// reads and downloads exactly the same chapters.
abstract class ChapterDuplicatePrefs {
  static const _prefKey = 'hideDuplicateChapters';

  static bool isHidden(String cid, String sourceKey) {
    final stored = appdata.implicitData[_prefKey];
    if (stored is! Map) return false;
    return stored['$cid@$sourceKey'] == true;
  }

  static void setHidden(String cid, String sourceKey, bool value) {
    final stored = appdata.implicitData[_prefKey];
    final map = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    final comicKey = '$cid@$sourceKey';
    if (value) {
      map[comicKey] = true;
    } else {
      map.remove(comicKey);
    }
    appdata.implicitData[_prefKey] = map;
    appdata.writeImplicitData();
  }
}

/// Per-comic chapter order overrides keyed by stable chapter IDs.
///
/// The source chapter map remains untouched so history, local paths, and
/// downloaded-chapter IDs keep their existing meaning. New source chapters are
/// appended in source order and removed chapters are ignored automatically.
abstract class ChapterOrderPrefs {
  static const settingKey = 'chapterOrderOverrides';

  static String _comicKey(String cid, String sourceKey) => '$cid@$sourceKey';

  static Map<String, dynamic> _overrides() {
    final raw = appdata.settings[settingKey];
    if (raw is! Map) return <String, dynamic>{};
    return {
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  static dynamic _storedOrder(String cid, String sourceKey, {String? group}) {
    final overrides = appdata.settings[settingKey];
    if (overrides is! Map) return null;
    final raw = overrides[_comicKey(cid, sourceKey)];
    if (group == null) return raw is List ? raw : null;
    if (raw is! Map) return null;
    final groups = raw['groups'];
    return groups is Map ? groups[group] : null;
  }

  static List<int> _orderedIndices(List<String> ids, dynamic stored) {
    final indexById = <String, int>{};
    for (var i = 0; i < ids.length; i++) {
      indexById.putIfAbsent(ids[i], () => i);
    }
    final result = <int>[];
    final used = <int>{};
    if (stored is List) {
      for (final value in stored) {
        final index = value is String ? indexById[value] : null;
        if (index != null && used.add(index)) result.add(index);
      }
    }
    for (var i = 0; i < ids.length; i++) {
      if (used.add(i)) result.add(i);
    }
    return result;
  }

  /// Returns raw flat indices in the user's display order.
  static List<int> orderedIndices(
    ComicChapters chapters,
    String cid,
    String sourceKey,
  ) {
    if (!chapters.isGrouped) {
      return _orderedIndices(
        chapters.ids.toList(),
        _storedOrder(cid, sourceKey),
      );
    }
    final result = <int>[];
    var offset = 0;
    for (final group in chapters.groups) {
      final ids = chapters.getGroup(group).keys.toList();
      result.addAll(
        _orderedIndices(
          ids,
          _storedOrder(cid, sourceKey, group: group),
        ).map((index) => offset + index),
      );
      offset += ids.length;
    }
    return result;
  }

  /// Returns raw within-group indices in the user's display order.
  static List<int> orderedIndicesForGroup(
    ComicChapters chapters,
    String cid,
    String sourceKey,
    int groupIndex,
  ) {
    if (!chapters.isGrouped ||
        groupIndex < 0 ||
        groupIndex >= chapters.groupCount) {
      return const [];
    }
    final groupName = chapters.groups.elementAt(groupIndex);
    final ids = chapters.getGroup(groupName).keys.toList();
    return _orderedIndices(ids, _storedOrder(cid, sourceKey, group: groupName));
  }

  static bool hasCustomOrder(
    ComicChapters chapters,
    String cid,
    String sourceKey,
  ) {
    final order = orderedIndices(chapters, cid, sourceKey);
    for (var i = 0; i < order.length; i++) {
      if (order[i] != i) return true;
    }
    return false;
  }

  /// Saves a complete raw-index permutation for a comic, omitting identity
  /// permutations so source updates continue to follow their natural order.
  static Future<void> save(
    ComicChapters chapters,
    String cid,
    String sourceKey,
    List<int> orderedFlatIndices,
  ) {
    final overrides = _overrides();
    final key = _comicKey(cid, sourceKey);
    if (!chapters.isGrouped) {
      final ids = chapters.ids.toList();
      final order = _sanitizePermutation(orderedFlatIndices, ids.length);
      final values = order.map((index) => ids[index]).toList();
      if (_isIdentity(order)) {
        overrides.remove(key);
      } else {
        overrides[key] = values;
      }
    } else {
      final groups = <String, dynamic>{};
      var offset = 0;
      for (final groupName in chapters.groups) {
        final ids = chapters.getGroup(groupName).keys.toList();
        final count = ids.length;
        final local = orderedFlatIndices
            .where((index) => index >= offset && index < offset + count)
            .map((index) => index - offset)
            .toList();
        final order = _sanitizePermutation(local, count);
        if (!_isIdentity(order)) {
          groups[groupName] = order.map((index) => ids[index]).toList();
        }
        offset += count;
      }
      if (groups.isEmpty) {
        overrides.remove(key);
      } else {
        overrides[key] = {'groups': groups};
      }
    }
    return _write(overrides);
  }

  static Future<void> reset(String cid, String sourceKey) {
    final overrides = _overrides()..remove(_comicKey(cid, sourceKey));
    return _write(overrides);
  }

  static Future<void> _write(Map<String, dynamic> overrides) async {
    final previous = appdata.settings[settingKey];
    appdata.settings[settingKey] = overrides;
    try {
      await appdata.saveData();
    } catch (_) {
      appdata.settings[settingKey] = previous;
      rethrow;
    }
  }

  static List<int> _sanitizePermutation(List<int> values, int length) {
    final result = <int>[];
    final used = <int>{};
    for (final value in values) {
      if (value >= 0 && value < length && used.add(value)) result.add(value);
    }
    for (var i = 0; i < length; i++) {
      if (used.add(i)) result.add(i);
    }
    return result;
  }

  static bool _isIdentity(List<int> values) {
    for (var i = 0; i < values.length; i++) {
      if (values[i] != i) return false;
    }
    return true;
  }
}

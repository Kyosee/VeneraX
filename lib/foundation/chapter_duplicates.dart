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

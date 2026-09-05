import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/utils/translations.dart';

/// Which favorite folders follow-updates covers, and how often each comic is
/// re-checked.
///
/// The scope is either "every folder" — which keeps covering folders created
/// later — or an explicit list. Both are device-local (see
/// `Appdata._disableSync`): folders differ between devices, and which of them
/// a device tracks is its own choice. The re-check interval is a preference and
/// does sync.
abstract class FollowUpdateScope {
  static const foldersKey = 'followUpdatesFolders';
  static const allFoldersKey = 'followUpdatesAllFolders';
  static const intervalKey = 'followUpdatesIntervalHours';
  static const checkOnStartKey = 'followUpdatesCheckOnStart';
  static const fixedTimeKey = 'followUpdatesFixedTime';
  static const migratedKey = 'followUpdatesFoldersMigrated';

  /// The single-folder setting this scope replaced. Left as it is on disk, so
  /// an older build still finds its choice; read only by the migration below.
  static const legacyFolderKey = 'followUpdatesFolder';

  static const intervalOptions = [1, 3, 6, 12, 24, 48, 72, 168];

  /// Matches the previous hard-coded "checked less than a day ago" gate.
  static const defaultIntervalHours = 24;

  static bool get allFolders => appdata.settings[allFoldersKey] == true;

  /// The persisted selection as stored, including folders that no longer exist.
  static List<String> get selected {
    var raw = appdata.settings[foldersKey];
    if (raw is! List) {
      return const [];
    }
    return raw.whereType<String>().toList();
  }

  /// Whether the user has set up follow-updates at all. True with an empty
  /// [folders] when "all folders" is on but the store has none yet.
  static bool get isConfigured => allFolders || selected.isNotEmpty;

  /// Narrows the persisted selection to folders that still exist, keeping the
  /// store's own order and dropping duplicates. Pure, for testing.
  static List<String> resolveFolders({
    required bool allFolders,
    required List<String> selected,
    required Iterable<String> existing,
  }) {
    if (allFolders) {
      return List.of(existing);
    }
    var wanted = selected.toSet();
    return existing.where(wanted.contains).toList();
  }

  /// Folders a check actually runs over. Empty while the favorites store is
  /// down, so callers treat that as "nothing to check" rather than throwing.
  ///
  /// Reads the store's cached folder set: this is called per comic card and per
  /// rebuild, and [LocalFavoritesManager.folderNames] re-queries sqlite_master
  /// plus a schema check per folder on every call (#263).
  static List<String> folders() {
    var manager = LocalFavoritesManager();
    if (!manager.isInitialized) {
      return const [];
    }
    // Nothing selected and not "all folders" — skip touching the store at all,
    // which is the common case for users who never configured follow-updates.
    if (!allFolders && selected.isEmpty) {
      return const [];
    }
    return resolveFolders(
      allFolders: allFolders,
      selected: selected,
      existing: manager.folderNamesCached,
    );
  }

  static int get intervalHours {
    var value = appdata.settings[intervalKey];
    if (value is num && value >= 1) {
      return value.toInt();
    }
    return defaultIntervalHours;
  }

  /// Whether one check runs right after the app starts.
  static bool get checkOnStart => appdata.settings[checkOnStartKey] != false;

  /// Time of day ("HH:mm") automatic checks wait for, or empty for any time.
  static String get fixedTime {
    var value = appdata.settings[fixedTimeKey];
    return value is String ? value : '';
  }

  /// Parses a stored "HH:mm", returning null when unset or malformed. Pure.
  static ({int hour, int minute})? parseFixedTime(String value) {
    var parts = value.split(':');
    if (parts.length != 2) {
      return null;
    }
    var hour = int.tryParse(parts[0]);
    var minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return null;
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      return null;
    }
    return (hour: hour, minute: minute);
  }

  /// Whether the daily time gate lets an automatic check run at [now]. An unset
  /// or malformed value means "no gate", so a bad string can't stop checks
  /// entirely. Pure, for testing.
  static bool isPastFixedTime(String value, DateTime now) {
    var time = parseFixedTime(value);
    if (time == null) {
      return true;
    }
    var scheduled = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );
    return !now.isBefore(scheduled);
  }

  /// Whether a comic last checked at [lastCheck] is due for another check.
  /// Pure, for testing.
  static bool isDue(DateTime? lastCheck, {DateTime? now, int? interval}) {
    if (lastCheck == null) {
      return true;
    }
    var hours = interval ?? intervalHours;
    var reference = now ?? DateTime.now();
    return !reference.isBefore(lastCheck.add(Duration(hours: hours)));
  }

  static String describeFixedTime(String value) {
    return parseFixedTime(value) == null ? "Any time".tl : value;
  }

  static String describeInterval(int hours) {
    if (hours == 1) {
      return "Every hour".tl;
    }
    return "Every @a hours".tlParams({'a': hours});
  }

  /// Short label for a set of followed folders, e.g. in a task title.
  static String describeFolders(List<String> folders) {
    if (folders.isEmpty) {
      return "No folder selected".tl;
    }
    if (folders.length == 1) {
      return folders.first;
    }
    return "@a folders".tlParams({'a': folders.length});
  }

  /// Persists a scope choice. Written without a sync upload: it is local
  /// configuration, and pushing it would overwrite other devices' own scope.
  static Future<void> save({
    required bool allFolders,
    required List<String> folders,
  }) async {
    appdata.settings[allFoldersKey] = allFolders;
    appdata.settings[foldersKey] = List.of(folders);
    await appdata.saveData(false);
  }

  /// Persists the schedule preferences. Unlike the folder scope these are plain
  /// preferences, so they ride the normal sync upload.
  static Future<void> saveSchedule({
    required int intervalHours,
    required bool checkOnStart,
    required String fixedTime,
  }) async {
    appdata.settings[intervalKey] = intervalHours;
    appdata.settings[checkOnStartKey] = checkOnStart;
    appdata.settings[fixedTimeKey] = fixedTime;
    await appdata.saveData();
  }

  /// One-shot migration of the single-folder setting into the folder list.
  /// Guarded by its own flag (which never syncs) so a user who later clears the
  /// selection isn't re-seeded from the stale legacy key on the next launch.
  static void migrateLegacyIfNeeded() {
    if (appdata.settings[migratedKey] == true) {
      return;
    }
    appdata.settings[migratedKey] = true;
    var legacy = appdata.settings[legacyFolderKey];
    if (legacy is String &&
        legacy.isNotEmpty &&
        !allFolders &&
        selected.isEmpty) {
      appdata.settings[foldersKey] = [legacy];
    }
  }
}

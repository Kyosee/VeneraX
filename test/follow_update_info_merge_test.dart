import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/favorites.dart';

// A WebDAV sync download applies a backup by wholesale-replacing
// local_favorite.db. Follow-update bookkeeping (has_new_update /
// last_update_time / last_check_time) is written by THIS device's update
// checks and may be missing or stale in the incoming backup — the swap used
// to silently erase every unread update mark while the follow-update task
// history kept showing them (#106). These tests validate the
// snapshot-before / merge-after pair used by importAppData.

const _folder = "favorites";

Database _folderDb({bool withUpdateColumns = true, bool withFlagTime = true}) {
  final db = sqlite3.openInMemory();
  final flagTimeCol = withUpdateColumns && withFlagTime
      ? ", flag_update_time int"
      : "";
  final extra = withUpdateColumns
      ? ", last_update_time TEXT, has_new_update int, last_check_time int$flagTimeCol"
      : "";
  db.execute("""
    create table "$_folder" (
      id text,
      name text,
      author text,
      type int,
      tags text,
      cover_path text,
      time text,
      display_order int
      $extra,
      primary key (id, type)
    );
  """);
  return db;
}

void _insert(
  Database db,
  String id, {
  String? updateTime,
  int? hasNewUpdate,
  int? lastCheckTime,
  int? flagUpdateTime,
  bool bare = false,
}) {
  if (bare) {
    db.execute(
      'insert into "$_folder" (id, name, author, type, tags, cover_path, time, display_order) '
      'values (?, ?, ?, ?, ?, ?, ?, ?);',
      [id, "n$id", "a", 1, "", "c", "t", 0],
    );
    return;
  }
  final hasFlagTimeCol = db
      .select('pragma table_info("$_folder");')
      .any((e) => e["name"] == "flag_update_time");
  if (hasFlagTimeCol) {
    db.execute(
      'insert into "$_folder" (id, name, author, type, tags, cover_path, time, display_order, '
      'last_update_time, has_new_update, last_check_time, flag_update_time) '
      'values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [id, "n$id", "a", 1, "", "c", "t", 0, updateTime, hasNewUpdate, lastCheckTime, flagUpdateTime],
    );
    return;
  }
  db.execute(
    'insert into "$_folder" (id, name, author, type, tags, cover_path, time, display_order, '
    'last_update_time, has_new_update, last_check_time) '
    'values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    [id, "n$id", "a", 1, "", "c", "t", 0, updateTime, hasNewUpdate, lastCheckTime],
  );
}

Row _row(Database db, String id) =>
    db.select('select * from "$_folder" where id == ?;', [id]).first;

void main() {
  test('snapshot captures only rows with follow-update data', () {
    final db = _folderDb();
    _insert(db, "flagged", updateTime: "2026-07-01", hasNewUpdate: 1, lastCheckTime: 100);
    _insert(db, "checked", updateTime: "2026-06-01", hasNewUpdate: 0, lastCheckTime: 50);
    _insert(db, "untouched");

    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(db);

    expect(snapshot.keys, [_folder]);
    final ids = snapshot[_folder]!.map((r) => r.id).toSet();
    expect(ids, {"flagged", "checked"});
    final flagged = snapshot[_folder]!.firstWhere((r) => r.id == "flagged");
    expect(flagged.hasNewUpdate, true);
    expect(flagged.lastUpdateTime, "2026-07-01");
    expect(flagged.lastCheckTime, 100);
  });

  test('local unread flag survives importing a backup without it (#106)', () {
    final local = _folderDb();
    _insert(local, "c1", updateTime: "2026-07-05", hasNewUpdate: 1, lastCheckTime: 200);
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    // Incoming backup: same comic, checked earlier, no update mark.
    final imported = _folderDb();
    _insert(imported, "c1", updateTime: "2026-06-01", hasNewUpdate: 0, lastCheckTime: 100);

    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    final row = _row(imported, "c1");
    expect(row["has_new_update"], 1, reason: "unread mark must survive the import");
    expect(row["last_update_time"], "2026-07-05",
        reason: "fresher local check wins, or the next check re-flags a read comic");
    expect(row["last_check_time"], 200);
  });

  test('imported flag is kept when local has none', () {
    final local = _folderDb();
    _insert(local, "c1", updateTime: "2026-06-01", hasNewUpdate: 0, lastCheckTime: 100);
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    final imported = _folderDb();
    _insert(imported, "c1", updateTime: "2026-07-05", hasNewUpdate: 1, lastCheckTime: 200);

    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    final row = _row(imported, "c1");
    expect(row["has_new_update"], 1);
    expect(row["last_update_time"], "2026-07-05",
        reason: "backup checked more recently; its baseline must not be rolled back");
    expect(row["last_check_time"], 200);
  });

  test('a local read clears the flag on a backup that still has it (#106 regression)', () {
    // The reported win->iOS bug: device A read a followed comic (flag -> 0,
    // stamped), uploaded; device B imports a backup where the comic is still
    // flagged from an older check. The read is newer, so it must win — the
    // comic must leave B's follow list. The old sticky OR kept it forever.
    final local = _folderDb();
    _insert(local, "c1",
        updateTime: "2026-07-05",
        hasNewUpdate: 0,
        lastCheckTime: 300,
        flagUpdateTime: 300);
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    final imported = _folderDb();
    _insert(imported, "c1",
        updateTime: "2026-07-01",
        hasNewUpdate: 1,
        lastCheckTime: 100,
        flagUpdateTime: 100);

    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    final row = _row(imported, "c1");
    expect(row["has_new_update"], 0,
        reason: "newer read clears the flag across devices");
    expect(row["flag_update_time"], 300);
  });

  test('a newer remote flag wins over an older local read', () {
    // Symmetric direction: the backup was checked-and-flagged AFTER this
    // device read the comic, so the fresh update mark must be adopted.
    final local = _folderDb();
    _insert(local, "c1",
        hasNewUpdate: 0, lastCheckTime: 100, flagUpdateTime: 100);
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    final imported = _folderDb();
    _insert(imported, "c1",
        hasNewUpdate: 1, lastCheckTime: 300, flagUpdateTime: 300);

    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    final row = _row(imported, "c1");
    expect(row["has_new_update"], 1,
        reason: "the more recent flag assertion wins");
    expect(row["flag_update_time"], 300);
  });

  test('a dated local read wins over an undated (legacy) remote flag', () {
    // The other device predates the flag_update_time column, so its flag is
    // undated. A dated read is by definition from a newer build => newer.
    final local = _folderDb();
    _insert(local, "c1",
        hasNewUpdate: 0, lastCheckTime: 300, flagUpdateTime: 300);
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    final imported = _folderDb(withFlagTime: false);
    _insert(imported, "c1", hasNewUpdate: 1, lastCheckTime: 100);

    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    final row = _row(imported, "c1");
    expect(row["has_new_update"], 0,
        reason: "a timestamped read outranks an undated legacy flag");
  });

  test('both sides undated falls back to the #106 sticky OR', () {
    // Neither side carries a flag timestamp: preserve the original #106
    // guarantee that an unread mark from either side is never lost.
    final local = _folderDb(withFlagTime: false);
    _insert(local, "c1", hasNewUpdate: 1, lastCheckTime: 200);
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    final imported = _folderDb(withFlagTime: false);
    _insert(imported, "c1", hasNewUpdate: 0, lastCheckTime: 100);

    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    expect(_row(imported, "c1")["has_new_update"], 1,
        reason: "legacy data keeps the sticky-OR protection");
  });

  test('merge adds missing follow-update columns to an old-format backup', () {
    final local = _folderDb();
    _insert(local, "c1", updateTime: "2026-07-05", hasNewUpdate: 1, lastCheckTime: 200);
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    final imported = _folderDb(withUpdateColumns: false);
    _insert(imported, "c1", bare: true);

    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    final row = _row(imported, "c1");
    expect(row["has_new_update"], 1);
    expect(row["last_update_time"], "2026-07-05");
    expect(row["last_check_time"], 200);
  });

  test('rows and folders absent from the backup are ignored', () {
    final local = _folderDb();
    _insert(local, "kept", hasNewUpdate: 1, lastCheckTime: 10);
    _insert(local, "removed-remotely", hasNewUpdate: 1, lastCheckTime: 10);
    local.execute('create table "other" (id text, name text, author text, '
        'tags text, cover_path text, time text, has_new_update int);');
    local.execute(
        'insert into "other" (id, has_new_update) values ("x", 1);');
    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(local);

    final imported = _folderDb();
    _insert(imported, "kept", hasNewUpdate: 0);

    // Must not throw on the missing row/folder.
    LocalFavoritesManager.mergeUpdateInfoInto(imported, snapshot);

    expect(_row(imported, "kept")["has_new_update"], 1);
    expect(
      imported.select('select count(*) as c from "$_folder";').first["c"],
      1,
      reason: "merge must not resurrect rows the backup deleted",
    );
  });

  test('snapshot skips non-favorite tables', () {
    final db = _folderDb();
    _insert(db, "c1", hasNewUpdate: 1);
    db.execute("create table folder_order (folder_name text primary key, order_value int);");
    db.execute("create table folder_sync (folder_name text primary key, key text, sync_data text);");

    final snapshot = LocalFavoritesManager.snapshotUpdateInfoOf(db);
    expect(snapshot.keys, [_folder]);
  });
}

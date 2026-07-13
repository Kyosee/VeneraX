import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

// Validates the invariant behind the "clearing history must not wipe read
// marks" fix: clearing/cleaning/removing from the history *list* only hides
// rows (sets `hidden = 1`); the row — with its reading position (ep/page) and
// per-chapter read marks (readEpisode) — stays in the table. The list queries
// filter hidden rows out, while the per-comic lookup (`find`) still sees them,
// so a comic's details page keeps its read chapters and resume point.
//
// These mirror the exact SQL HistoryManager runs, on an in-memory DB, because
// HistoryManager itself needs App.dataPath + DatabaseGateway which can't be
// stood up in a plain unit test.

const _schema = """
  create table history (
    id text,
    title text,
    subtitle text,
    cover text,
    time int,
    type int,
    ep int,
    page int,
    readEpisode text,
    max_page int,
    chapter_group int,
    hidden int,
    primary key (id, type)
  );
""";

const _insert = """
  insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group)
  values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
""";

// List view: excludes hidden rows.
int _listCount(Database db) => db
    .select("select count(*) from history where ifnull(hidden, 0) = 0;")
    .first[0] as int;

// Per-comic lookup: sees hidden rows too (drives the details/chapters page).
Row? _find(Database db, String id, int type) {
  var res = db.select(
    "select * from history where id == ? and type == ?;",
    [id, type],
  );
  return res.isEmpty ? null : res.first;
}

void _seed(Database db, String id, {int time = 1000, String reads = "1,2,3"}) {
  db.execute(_insert, [id, "t-$id", "", "", time, 1, 3, 42, reads, 100, null]);
}

void main() {
  late Database db;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(_schema);
  });

  tearDown(() => db.dispose());

  test('clearHistory hides all rows but keeps reading state findable', () {
    _seed(db, "a");
    _seed(db, "b");
    expect(_listCount(db), 2);

    // clearHistory
    db.execute("update history set hidden = 1 where ifnull(hidden, 0) = 0;");

    expect(_listCount(db), 0, reason: "list is empty after clear");
    final row = _find(db, "a", 1);
    expect(row, isNotNull, reason: "row survives for the details page");
    expect(row!["readEpisode"], "1,2,3", reason: "read marks preserved");
    expect(row["ep"], 3);
    expect(row["page"], 42, reason: "resume position preserved");
  });

  test('single hide removes from list, keeps read state; other rows intact', () {
    _seed(db, "a", reads: "1,2");
    _seed(db, "b", reads: "5");

    // hide("a")
    db.execute(
      "update history set hidden = 1 where id == ? and type == ?;",
      ["a", 1],
    );

    expect(_listCount(db), 1, reason: "only b remains in list");
    expect(_find(db, "a", 1)!["readEpisode"], "1,2");
    expect(_find(db, "b", 1)!["readEpisode"], "5");
  });

  test('re-reading a hidden comic un-hides it (insert or replace clears flag)',
      () {
    _seed(db, "a", reads: "1,2,3");
    db.execute("update history set hidden = 1 where ifnull(hidden, 0) = 0;");
    expect(_listCount(db), 0);

    // Reading again writes via insert-or-replace, which omits `hidden` -> NULL.
    _seed(db, "a", time: 2000, reads: "1,2,3,4");

    expect(_listCount(db), 1, reason: "comic reappears in the list");
    expect(_find(db, "a", 1)!["readEpisode"], "1,2,3,4",
        reason: "new marks merged in");
  });

  test('cleanHistoryOlderThan hides only old rows, keeps their read state', () {
    _seed(db, "old", time: 100, reads: "1");
    _seed(db, "new", time: 9999, reads: "7,8");

    // cleanHistoryOlderThan(cutoff = 5000)
    db.execute(
      "update history set hidden = 1 where ifnull(hidden, 0) = 0 and time < ?;",
      [5000],
    );

    expect(_listCount(db), 1, reason: "only the recent row stays in list");
    expect(_find(db, "old", 1), isNotNull, reason: "old row still findable");
    expect(_find(db, "old", 1)!["readEpisode"], "1",
        reason: "old comic keeps its read marks");
    expect(_find(db, "new", 1)!["readEpisode"], "7,8");
  });

  test('remove (genuine deletion) drops the row entirely', () {
    _seed(db, "a");

    // remove() — used when a local comic is deleted from disk.
    db.execute("delete from history where id == ? and type == ?;", ["a", 1]);

    expect(_listCount(db), 0);
    expect(_find(db, "a", 1), isNull, reason: "row is truly gone");
  });
}

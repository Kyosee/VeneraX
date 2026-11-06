import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:sqlite3/common.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/foundation/sqlite_connection.dart';

/// Persistent store of finished per-page translation text: the recognized
/// regions and their translated strings for one page, under one language pair.
///
/// This is the durable source of truth for translations — NOT a cache. The
/// rendered page image stays in [CacheManager] (re-derivable from these regions
/// at any time, free to LRU-evict); the text here is what lets a page
/// re-render — or render on another device — without paying for OCR or an LLM
/// request again. Nothing here expires; the user clears it explicitly.
///
/// Rows are keyed by the page's translation [cacheKey], the same composed
/// string the reader/pre-translation paths already use — it embeds
/// `sourceLang>targetLang`, the comic, the chapter and the image, and is built
/// to form deletable scope prefixes (see [ImageTranslationService.cacheKeyFor]).
/// Keying on it avoids parsing components back out (image keys are URLs that may
/// contain the field separator) and reuses the existing prefix scopes verbatim
/// for per-comic / per-chapter deletion.
///
/// It lives in its own database file so it rides the WebDAV/backup pipeline like
/// every other store: exporting the file and merging it on another device
/// carries a comic's translations across. Import merges page by page (see
/// [TranslationStore.mergeFrom]): two devices that translated different
/// chapters keep both halves, a re-translated page replaces the older text, and
/// a deletion recorded in `translated_tombstone` keeps the deleted pages from
/// coming back from a device that still holds them.
class TranslationChapterIdentity {
  const TranslationChapterIdentity({
    required this.scopePrefix,
    required this.sourceKey,
    required this.comicId,
    required this.chapterId,
    required this.sourceLang,
    required this.targetLang,
    this.comicTitle = '',
    this.comicCover = '',
    this.chapterTitle = '',
  });

  final String scopePrefix;
  final String sourceKey;
  final String comicId;
  final String chapterId;
  final String sourceLang;
  final String targetLang;
  final String comicTitle;
  final String comicCover;
  final String chapterTitle;
}

class StoredTranslationChapter {
  const StoredTranslationChapter({
    required this.identity,
    required this.pageCount,
    required this.updatedAt,
  });

  final TranslationChapterIdentity identity;
  final int pageCount;
  final DateTime updatedAt;
}

class StoredTranslationComic {
  const StoredTranslationComic({
    required this.sourceKey,
    required this.comicId,
    required this.sourceLang,
    required this.targetLang,
    required this.title,
    required this.cover,
    required this.chapterCount,
    required this.pageCount,
    required this.updatedAt,
  });

  final String sourceKey;
  final String comicId;
  final String sourceLang;
  final String targetLang;
  final String title;
  final String cover;
  final int chapterCount;
  final int pageCount;
  final DateTime updatedAt;
}

class TranslationMergeResult {
  const TranslationMergeResult({
    this.applied = 0,
    this.changedKeys = const {},
  });

  /// Incoming pages that are now stored here (new or newer than ours).
  final int applied;

  /// Pages whose stored text was replaced or removed by the merge. Their
  /// rendered images were drawn from the old text and must be dropped.
  final Set<String> changedKeys;
}

class TranslationStore with ChangeNotifier {
  static TranslationStore? _cache;

  TranslationStore.create();

  factory TranslationStore() => _cache ??= TranslationStore.create();

  late CommonDatabase _db;

  late String _dbPath;

  Timer? _notifyTimer;

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) return;
    _dbPath = "${App.dataPath}/image_translation.db";
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _db.execute(_createTableSql);
    _db.execute(_createIndexTableSql);
    _db.execute(_createTombstoneTableSql);
    _migrateSchema();
    migrateLegacyKeys(_db);
    _backfillChapterIndex();
    isInitialized = true;
  }

  /// Merges another translation database at [sourcePath] into this one — the
  /// WebDAV/backup import path. A device that translated chapters 1-5 and one
  /// that did 6-10 end up with all ten. Where both hold the same page, the row
  /// written later wins, so a re-translation reaches the other device instead of
  /// being ignored there. Deletions recorded on either side are then applied to
  /// the merged rows, so pages cleared on one device are not restored by
  /// another that still had them. The source is opened read-only and disposed
  /// before returning. Tolerates a foreign/absent file: an incompatible table
  /// simply merges nothing.
  ///
  /// With [restore] the user explicitly asked for this file's contents, so they
  /// must stick: its pages outrank deletions recorded here (they are re-stamped
  /// past them, so later merges keep them too), and its own deletions are not
  /// applied, so an import can only add.
  ///
  /// [languageFor] files incoming pages under the language this device reads
  /// the comic with. A page key embeds the language the comic was set to when
  /// translated, so a file from a device set to Japanese would otherwise be
  /// invisible to one left on auto-detect, which would pay to translate it all
  /// again. The target language is kept: text in another language isn't a match.
  Future<TranslationMergeResult> mergeFrom(
    String sourcePath, {
    bool restore = false,
    String Function(String sourceKey, String comicId)? languageFor,
  }) async {
    if (!isInitialized) {
      throw StateError("TranslationStore is not initialized; cannot merge");
    }
    var src = openRawDatabase(sourcePath, mode: OpenMode.readOnly);
    var applied = <String>{};
    var changed = <String>{};
    var languages = <String, String>{};
    String localKey(String key) {
      if (languageFor == null) return key;
      var match = _currentKeyPattern.firstMatch(key);
      if (match == null) return key;
      var language = languages.putIfAbsent(
        '${match.group(3)}@${match.group(4)}',
        () => languageFor(match.group(3)!, match.group(4)!),
      );
      var from = match.group(1)!;
      var to = match.group(2)!;
      if (language == from) return key;
      var pair = _currentPrefix.length + from.length + 1 + to.length + 1;
      return '$_currentPrefix$language>$to@${key.substring(pair)}';
    }

    try {
      if (!_requiredColumns.every(_columnsOf(src, 'translated_page').contains)) {
        return const TranslationMergeResult();
      }
      var rows = src.select(
        "select cache_key, regions, time from translated_page;",
      );
      var indexRows =
          _indexColumns.every(_columnsOf(src, 'translated_chapter_index').contains)
          ? src.select("select * from translated_chapter_index;")
          : const <Row>[];
      var tombstoneRows =
          !restore &&
              _columnsOf(
                src,
                'translated_tombstone',
              ).containsAll(_tombstoneColumns)
          ? src.select(
              "select scope_prefix, deleted_at from translated_tombstone;",
            )
          : const <Row>[];
      var localDeletions = restore
          ? _db.select(
              "select scope_prefix, deleted_at from translated_tombstone;",
            )
          : const <Row>[];
      _db.execute("BEGIN TRANSACTION;");
      try {
        var lookup = _db.prepare(
          "select time from translated_page where cache_key = ?;",
        );
        var write = _db.prepare(_insertReplaceSql);
        try {
          for (var r in rows) {
            var incoming = r["cache_key"];
            if (incoming is! String) continue;
            var key = localKey(incoming);
            var time = r["time"] is int ? r["time"] as int : 0;
            for (var d in localDeletions) {
              if (key.startsWith(d['scope_prefix'] as String)) {
                time = max(time, (d['deleted_at'] as int) + 1);
              }
            }
            var local = lookup.select([key]);
            if (local.isNotEmpty) {
              var localTime = local.first["time"];
              if (localTime is int && localTime >= time) continue;
              changed.add(key);
            }
            write.execute([key, r["regions"], time]);
            applied.add(key);
          }
        } finally {
          lookup.dispose();
          write.dispose();
        }
        for (var r in indexRows) {
          var scope = localKey(r['scope_prefix'] as String);
          _upsertChapterRow(
            TranslationChapterIdentity(
              scopePrefix: scope,
              sourceKey: r['source_key'] as String,
              comicId: r['comic_id'] as String,
              chapterId: r['chapter_id'] as String,
              sourceLang:
                  _currentKeyPattern.firstMatch(scope)?.group(1) ??
                  r['source_lang'] as String,
              targetLang: r['target_lang'] as String,
              comicTitle: r['comic_title'] as String? ?? '',
              comicCover: r['comic_cover'] as String? ?? '',
              chapterTitle: r['chapter_title'] as String? ?? '',
            ),
            pageCount: r['page_count'] as int? ?? 0,
            updatedAt: r['updated_at'] as int? ?? 0,
          );
        }
        for (var r in tombstoneRows) {
          var prefix = r['scope_prefix'];
          var deletedAt = r['deleted_at'];
          // Only scopes this code writes: a malformed entry in a foreign file
          // must not widen into deleting unrelated pages.
          if (prefix is String &&
              prefix.startsWith(_keyPrefix) &&
              prefix.endsWith('@') &&
              deletedAt is int) {
            _recordTombstone(prefix, deletedAt);
          }
        }
        migrateLegacyKeys(_db);
        var removed = _applyTombstones();
        applied.removeAll(removed);
        changed.addAll(removed);
        _backfillChapterIndex();
        _recountIndex();
        _db.execute("COMMIT;");
      } catch (e) {
        _db.execute("ROLLBACK;");
        rethrow;
      }
    } catch (e, s) {
      Log.error("TranslationStore", "merge failed: $e", s);
      return const TranslationMergeResult();
    } finally {
      src.dispose();
    }
    if (applied.isNotEmpty || changed.isNotEmpty) _notifyChanged();
    return TranslationMergeResult(applied: applied.length, changedKeys: changed);
  }

  static Set<String> _columnsOf(CommonDatabase db, String table) => db
      .select("PRAGMA table_info($table);")
      .map((c) => c["name"] as String)
      .toSet();

  /// Records that every page under [scopePrefix] written at or before
  /// [deletedAt] is deleted. Keeps the later time when one is already recorded,
  /// and drops narrower records the new one already covers.
  void _recordTombstone(String scopePrefix, int deletedAt) {
    _db.execute(
      """
      insert into translated_tombstone (scope_prefix, deleted_at) values (?, ?)
      on conflict(scope_prefix) do update set deleted_at =
        max(translated_tombstone.deleted_at, excluded.deleted_at);
      """,
      [scopePrefix, deletedAt],
    );
    var effective =
        _db.select(
              "select deleted_at from translated_tombstone where scope_prefix = ?;",
              [scopePrefix],
            ).first['deleted_at']
            as int;
    _db.execute(
      "delete from translated_tombstone "
      "where scope_prefix > ? and scope_prefix < ? and deleted_at <= ?;",
      [scopePrefix, _prefixEnd(scopePrefix), effective],
    );
  }

  /// Deletes every page a recorded deletion covers and returns their keys.
  Set<String> _applyTombstones() {
    var removed = <String>{};
    var tombstones = _db.select(
      "select scope_prefix, deleted_at from translated_tombstone;",
    );
    for (var t in tombstones) {
      var prefix = t['scope_prefix'] as String;
      var args = [prefix, _prefixEnd(prefix), t['deleted_at'] as int];
      const where =
          "cache_key >= ? and cache_key < ? and ifnull(time, 0) <= ?";
      for (var row in _db.select(
        "select cache_key from translated_page where $where;",
        args,
      )) {
        removed.add(row['cache_key'] as String);
      }
      _db.execute("delete from translated_page where $where;", args);
    }
    return removed;
  }

  /// Exclusive upper bound of the keys that start with [prefix], so a prefix
  /// match runs as an indexed range scan (`>= prefix and < end`) instead of a
  /// LIKE that scans the whole table. Every scope prefix ends with `@`, so
  /// bumping the last code unit never lands inside a surrogate pair.
  static String _prefixEnd(String prefix) =>
      prefix.substring(0, prefix.length - 1) +
      String.fromCharCode(prefix.codeUnitAt(prefix.length - 1) + 1);

  static const String _createTableSql = """
      create table if not exists translated_page (
        cache_key text primary key,
        regions text,
        time int
      );
    """;

  static const String _createIndexTableSql = """
      create table if not exists translated_chapter_index (
        scope_prefix text primary key,
        source_key text not null,
        comic_id text not null,
        chapter_id text not null,
        source_lang text not null,
        target_lang text not null,
        comic_title text not null default '',
        comic_cover text not null default '',
        chapter_title text not null default '',
        page_count int not null default 0,
        updated_at int not null default 0
      );
    """;

  static const _indexColumns = {
    'scope_prefix',
    'source_key',
    'comic_id',
    'chapter_id',
    'source_lang',
    'target_lang',
    'comic_title',
    'comic_cover',
    'chapter_title',
    'page_count',
    'updated_at',
  };

  /// Scopes deleted by a re-translate or a clear. A merge removes pages under a
  /// recorded scope that are not newer than its deletion; without this a page
  /// deleted here came back from any device that still held it.
  static const String _createTombstoneTableSql = """
      create table if not exists translated_tombstone (
        scope_prefix text primary key,
        deleted_at int not null
      );
    """;

  static const _tombstoneColumns = {'scope_prefix', 'deleted_at'};

  /// Columns a foreign database must have for [mergeFrom] to read it.
  static const _requiredColumns = ["cache_key", "regions", "time"];

  /// Generation 1 keys carry no generation segment (`pageTranslation@ja>zh@…`),
  /// so generation-2 lookups (`pageTranslation@2@ja>zh@…`) miss them and the
  /// pages read as never translated. Rewrite those keys into the generation-2
  /// namespace instead of dropping the rows: the stored text is the expensive,
  /// non-reproducible part (OCR + a paid translation request) and is unaffected
  /// by the generation bump. What generation 1 lacks is per-line erase
  /// rectangles (`es`), and their absence is already handled downstream — the
  /// renderer falls back to the union [TranslatedRegion.eraseRect] and computes
  /// the actual stroke mask from the page pixels at render time, so a migrated
  /// row erases no more broadly than a fresh one.
  ///
  /// A generation-2 row for the same page already being present means the page
  /// was re-translated after the upgrade; that row is newer, so INSERT OR IGNORE
  /// keeps it and the legacy duplicate is dropped.
  @visibleForTesting
  static void migrateLegacyKeys(CommonDatabase db) {
    db.execute(
      "insert or ignore into translated_page (cache_key, regions, time) "
      "select '$_currentPrefix' || $_tail, regions, time "
      "from translated_page where $_isLegacyKey;",
    );
    db.execute("delete from translated_page where $_isLegacyKey;");
  }

  static const _keyPrefix = 'pageTranslation@';

  /// Current generation prefix. Must stay in step with
  /// `TranslationConfig.cachePrefix`.
  static const _currentPrefix = '${_keyPrefix}2@';

  /// Everything after `pageTranslation@` — for a legacy key this is the whole
  /// `sourceLang>targetLang@source@comic@chapter@image` remainder.
  static const _tail = "substr(cache_key, length('$_keyPrefix') + 1)";

  /// The generation segment: the part of [_tail] before its first `@` — `ja>zh`
  /// for a legacy key, `2` for a current one. Matched as a whole segment so a
  /// future two-digit generation is not mistaken for a legacy key.
  static const _generation = "substr($_tail, 1, instr($_tail, '@') - 1)";

  /// A key belongs to generation 1 when its generation segment is not a number,
  /// i.e. the language pair sits where the generation number now goes. A key
  /// with no `@` at all is malformed rather than legacy and is left untouched.
  static const _isLegacyKey =
      "cache_key like '$_keyPrefix%' and $_generation glob '*[^0-9]*'";

  static final _currentKeyPattern = RegExp(
    r'^pageTranslation@2@([^@>]+)>([^@]+)@([^@]+)@([^@]+)@([^@]+)@',
  );

  static const Map<String, String> _expectedColumns = {
    "cache_key": "text",
    "regions": "text",
    "time": "int",
  };

  void _migrateSchema() => migrateSchema(_db);

  /// Normalize the on-disk `translated_page` table to our canonical schema — a
  /// restore/merge can meet a file a foreign app happens to name the same.
  /// Mirrors [ReadLaterManager.migrateSchema]: rebuild on structural
  /// divergence, additively backfill a column missing from an older own schema.
  @visibleForTesting
  static void migrateSchema(CommonDatabase db) {
    final columns = db.select("PRAGMA table_info(translated_page);");
    final existing = columns.map((c) => c["name"] as String).toSet();
    final hasExtraColumn = existing.any(
      (c) => !_expectedColumns.containsKey(c),
    );
    final missingColumn = _expectedColumns.keys.any(
      (c) => !existing.contains(c),
    );
    if (hasExtraColumn) {
      _rebuildTable(db, existing);
      return;
    }
    if (missingColumn) {
      for (final entry in _expectedColumns.entries) {
        if (!existing.contains(entry.key)) {
          db.execute(
            "alter table translated_page add column ${entry.key} ${entry.value};",
          );
        }
      }
    }
  }

  static void _rebuildTable(CommonDatabase db, Set<String> existing) {
    final carried = _expectedColumns.keys.where(existing.contains).toList();
    final columnList = carried.join(", ");
    db.execute("BEGIN TRANSACTION;");
    try {
      db.execute(
        "alter table translated_page rename to translated_page_legacy;",
      );
      db.execute(_createTableSql);
      if (carried.isNotEmpty) {
        db.execute(
          "insert or ignore into translated_page ($columnList) "
          "select $columnList from translated_page_legacy;",
        );
      }
      db.execute("drop table translated_page_legacy;");
      db.execute("COMMIT;");
    } catch (e, s) {
      db.execute("ROLLBACK;");
      Log.error("TranslationStore", "rebuild failed: $e", s);
    }
  }

  static const _insertReplaceSql = """
    insert or replace into translated_page (cache_key, regions, time)
    values (?, ?, ?);
  """;

  static const _insertIgnoreSql = """
    insert or ignore into translated_page (cache_key, regions, time)
    values (?, ?, ?);
  """;

  /// Stores the finished [regions] of one page. An empty list is valid and
  /// meaningful: it records "this page has no translatable text", so the page is
  /// never re-analyzed. A local write overwrites (INSERT OR REPLACE) — a
  /// re-translate must win over whatever was there.
  void put(
    String cacheKey,
    List<TranslatedRegion> regions, {
    TranslationChapterIdentity? chapter,
  }) {
    if (!isInitialized) return;
    // Written after any deletion covering it, even one stamped by a device
    // whose clock runs ahead; otherwise the next merge would delete it.
    var timestamp = max(
      DateTime.now().millisecondsSinceEpoch,
      _coveringDeletion(cacheKey) + 1,
    );
    _db.execute(_insertReplaceSql, [
      cacheKey,
      jsonEncode([for (var r in regions) r.toJson()]),
      timestamp,
    ]);
    _localRevision++;
    if (chapter != null) {
      _upsertChapterRow(
        chapter,
        pageCount: countByPrefix(chapter.scopePrefix),
        updatedAt: timestamp,
      );
      _notifyChanged();
    }
  }

  /// Bumped by every page written or deleted on this device (merges excluded),
  /// so a caller can tell whether its work left anything to upload.
  int get localRevision => _localRevision;
  int _localRevision = 0;

  /// Newest deletion time covering [cacheKey], or -1.
  int _coveringDeletion(String cacheKey) {
    var row = _db.select(
      "select max(deleted_at) as t from translated_tombstone "
      "where substr(?, 1, length(scope_prefix)) = scope_prefix;",
      [cacheKey],
    ).first;
    return row['t'] as int? ?? -1;
  }

  int recordExistingChapter(TranslationChapterIdentity chapter) {
    if (!isInitialized) return 0;
    var prefix = chapter.scopePrefix;
    var stats = _db.select(
      "select count(*) as page_count, max(time) as updated_at "
      "from translated_page where cache_key >= ? and cache_key < ?;",
      [prefix, _prefixEnd(prefix)],
    ).first;
    var pages = stats['page_count'] as int? ?? 0;
    if (pages <= 0) return 0;
    var changed = _upsertChapterRow(
      chapter,
      pageCount: pages,
      updatedAt: stats['updated_at'] as int? ?? 0,
    );
    if (changed) _notifyChanged();
    return pages;
  }

  bool _upsertChapterRow(
    TranslationChapterIdentity chapter, {
    required int pageCount,
    required int updatedAt,
  }) {
    _db.execute(
      """
      insert into translated_chapter_index (
        scope_prefix, source_key, comic_id, chapter_id,
        source_lang, target_lang, comic_title, comic_cover,
        chapter_title, page_count, updated_at
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict(scope_prefix) do update set
        page_count = excluded.page_count,
        updated_at = max(translated_chapter_index.updated_at, excluded.updated_at),
        comic_title = case when excluded.comic_title != ''
          then excluded.comic_title else translated_chapter_index.comic_title end,
        comic_cover = case when excluded.comic_cover != ''
          then excluded.comic_cover else translated_chapter_index.comic_cover end,
        chapter_title = case when excluded.chapter_title != ''
          then excluded.chapter_title else translated_chapter_index.chapter_title end
      where translated_chapter_index.page_count != excluded.page_count
        or translated_chapter_index.updated_at < excluded.updated_at
        or (excluded.comic_title != '' and
          translated_chapter_index.comic_title != excluded.comic_title)
        or (excluded.comic_cover != '' and
          translated_chapter_index.comic_cover != excluded.comic_cover)
        or (excluded.chapter_title != '' and
          translated_chapter_index.chapter_title != excluded.chapter_title);
      """,
      [
        chapter.scopePrefix,
        chapter.sourceKey,
        chapter.comicId,
        chapter.chapterId,
        chapter.sourceLang,
        chapter.targetLang,
        chapter.comicTitle,
        chapter.comicCover,
        chapter.chapterTitle,
        pageCount,
        updatedAt,
      ],
    );
    return (_db.select('select changes();').first[0] as int) > 0;
  }

  /// Builds the query index for translations written before the index existed.
  /// Only the fixed chapter prefix is parsed; the remaining image key may
  /// contain any number of `@` separators and is deliberately left untouched.
  void _backfillChapterIndex() {
    var grouped =
        <
          String,
          ({TranslationChapterIdentity identity, int pageCount, int updatedAt})
        >{};
    for (var row in _db.select(
      'select cache_key, time from translated_page;',
    )) {
      var cacheKey = row['cache_key'] as String? ?? '';
      var match = _currentKeyPattern.firstMatch(cacheKey);
      if (match == null) continue;
      var scopePrefix = match.group(0)!;
      var sourceKey = match.group(3)!;
      var identity = TranslationChapterIdentity(
        scopePrefix: scopePrefix,
        sourceKey: sourceKey == 'null'
            ? SourcePlatformResolver.localCanonicalKey
            : sourceKey,
        comicId: match.group(4)!,
        chapterId: match.group(5)!,
        sourceLang: match.group(1)!,
        targetLang: match.group(2)!,
      );
      var updatedAt = row['time'] as int? ?? 0;
      var previous = grouped[scopePrefix];
      grouped[scopePrefix] = (
        identity: identity,
        pageCount: (previous?.pageCount ?? 0) + 1,
        updatedAt: previous == null
            ? updatedAt
            : previous.updatedAt > updatedAt
            ? previous.updatedAt
            : updatedAt,
      );
    }
    for (var entry in grouped.values) {
      _upsertChapterRow(
        entry.identity,
        pageCount: entry.pageCount,
        updatedAt: entry.updatedAt,
      );
    }
  }

  void _recountIndex() {
    var rows = _db.select('select scope_prefix from translated_chapter_index;');
    for (var row in rows) {
      var prefix = row['scope_prefix'] as String;
      var pages = countByPrefix(prefix);
      if (pages == 0) {
        _db.execute(
          'delete from translated_chapter_index where scope_prefix = ?;',
          [prefix],
        );
      } else {
        _db.execute(
          'update translated_chapter_index set page_count = ? '
          'where scope_prefix = ?;',
          [pages, prefix],
        );
      }
    }
  }

  List<StoredTranslationChapter> get chapters {
    if (!isInitialized) return const [];
    try {
      return _db
          .select(
            'select * from translated_chapter_index '
            'where page_count > 0 order by updated_at desc;',
          )
          .map(_chapterFromRow)
          .toList();
    } catch (e, s) {
      Log.error('TranslationStore', 'list chapters failed: $e', s);
      return const [];
    }
  }

  List<StoredTranslationChapter> chaptersFor(
    String sourceKey,
    String comicId, {
    String? sourceLang,
    String? targetLang,
  }) {
    return chapters.where((chapter) {
      var identity = chapter.identity;
      return identity.sourceKey == sourceKey &&
          identity.comicId == comicId &&
          (sourceLang == null || identity.sourceLang == sourceLang) &&
          (targetLang == null || identity.targetLang == targetLang);
    }).toList();
  }

  List<StoredTranslationComic> get comics {
    var grouped = <String, List<StoredTranslationChapter>>{};
    for (var chapter in chapters) {
      var identity = chapter.identity;
      var key =
          '${identity.sourceLang}\u0000${identity.targetLang}\u0000'
          '${identity.sourceKey}\u0000${identity.comicId}';
      grouped.putIfAbsent(key, () => []).add(chapter);
    }
    var result = <StoredTranslationComic>[];
    for (var values in grouped.values) {
      var newest = values.first;
      var identity = newest.identity;
      result.add(
        StoredTranslationComic(
          sourceKey: identity.sourceKey,
          comicId: identity.comicId,
          sourceLang: identity.sourceLang,
          targetLang: identity.targetLang,
          title: values
              .map((e) => e.identity.comicTitle)
              .firstWhere((value) => value.isNotEmpty, orElse: () => ''),
          cover: values
              .map((e) => e.identity.comicCover)
              .firstWhere((value) => value.isNotEmpty, orElse: () => ''),
          chapterCount: values.length,
          pageCount: values.fold(0, (sum, item) => sum + item.pageCount),
          updatedAt: newest.updatedAt,
        ),
      );
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  /// Fills display metadata for rows imported from an older database. The
  /// durable page keys intentionally do not carry titles or covers, so the
  /// detail page can supply them after resolving the comic from its source.
  void updateComicMetadata(
    String sourceKey,
    String comicId, {
    String comicTitle = '',
    String comicCover = '',
    Map<String, String> chapterTitles = const {},
  }) {
    if (!isInitialized) return;
    var changed = false;
    if (comicTitle.isNotEmpty || comicCover.isNotEmpty) {
      _db.execute(
        """
        update translated_chapter_index set
          comic_title = case when ? != '' then ? else comic_title end,
          comic_cover = case when ? != '' then ? else comic_cover end
        where source_key = ? and comic_id = ?;
        """,
        [comicTitle, comicTitle, comicCover, comicCover, sourceKey, comicId],
      );
      changed = (_db.select('select changes();').first[0] as int) > 0;
    }
    for (var entry in chapterTitles.entries) {
      if (entry.value.isEmpty) continue;
      _db.execute(
        'update translated_chapter_index set chapter_title = ? '
        'where source_key = ? and comic_id = ? and chapter_id = ?;',
        [entry.value, sourceKey, comicId, entry.key],
      );
      changed =
          changed || (_db.select('select changes();').first[0] as int) > 0;
    }
    if (changed) _notifyChanged();
  }

  StoredTranslationChapter _chapterFromRow(Row row) {
    return StoredTranslationChapter(
      identity: TranslationChapterIdentity(
        scopePrefix: row['scope_prefix'] as String,
        sourceKey: row['source_key'] as String,
        comicId: row['comic_id'] as String,
        chapterId: row['chapter_id'] as String,
        sourceLang: row['source_lang'] as String,
        targetLang: row['target_lang'] as String,
        comicTitle: row['comic_title'] as String? ?? '',
        comicCover: row['comic_cover'] as String? ?? '',
        chapterTitle: row['chapter_title'] as String? ?? '',
      ),
      pageCount: row['page_count'] as int? ?? 0,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        row['updated_at'] as int? ?? 0,
      ),
    );
  }

  /// The stored regions for a page, or null when the page was never translated.
  /// An empty list means "translated, nothing to render" (the page has no text).
  List<TranslatedRegion>? get(String cacheKey) {
    if (!isInitialized) return null;
    try {
      var rows = _db.select(
        "select regions from translated_page where cache_key = ?;",
        [cacheKey],
      );
      if (rows.isEmpty) return null;
      var data = jsonDecode(rows.first["regions"] as String);
      if (data is! List) return const [];
      return [
        for (var item in data)
          TranslatedRegion.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (e, s) {
      Log.error("TranslationStore", "get failed: $e", s);
      return null;
    }
  }

  /// Moves a page stored under the pre-#287 transport-derived key to the stable
  /// page-ordinal [cacheKey] and returns its regions, or null when no such row
  /// exists. The rewrite happens once per page, on the first read that can still
  /// address the old key, so the work already paid for survives the key change
  /// without a blanket migration (an image key cannot be mapped back to a page
  /// number without re-listing the chapter).
  ///
  /// INSERT OR IGNORE keeps an existing stable row if one appeared meanwhile;
  /// the legacy row is dropped either way, so the adoption never repeats.
  List<TranslatedRegion>? adoptLegacyKey(String legacyKey, String cacheKey) {
    if (!isInitialized) return null;
    try {
      var rows = _db.select(
        "select regions, time from translated_page where cache_key = ?;",
        [legacyKey],
      );
      if (rows.isEmpty) return null;
      _db.execute(_insertIgnoreSql, [
        cacheKey,
        rows.first['regions'],
        rows.first['time'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      ]);
      _db.execute("delete from translated_page where cache_key = ?;", [
        legacyKey,
      ]);
      return get(cacheKey);
    } catch (e, s) {
      Log.error("TranslationStore", "adoptLegacyKey failed: $e", s);
      return null;
    }
  }

  /// Deletes every stored page whose key starts with [scopePrefix] — the same
  /// comic/chapter scope prefixes the rendered-image cache is cleared by, so a
  /// re-translate or "clear" drops both levels in lockstep. The deletion is
  /// recorded so a merge drops the same pages on other devices instead of
  /// bringing them back. Returns rows removed.
  int deleteByPrefix(String scopePrefix) {
    if (!isInitialized) return 0;
    var args = [scopePrefix, _prefixEnd(scopePrefix)];
    var newest =
        _db.select(
              "select max(time) as t from translated_page "
              "where cache_key >= ? and cache_key < ?;",
              args,
            ).first['t']
            as int? ??
        0;
    // Recorded first: a crash right after still removes these pages on the next
    // merge, while the reverse order would lose the deletion for good.
    _recordTombstone(
      scopePrefix,
      max(DateTime.now().millisecondsSinceEpoch, newest),
    );
    _db.execute(
      "delete from translated_page where cache_key >= ? and cache_key < ?;",
      args,
    );
    var removed = _db.select("select changes();").first[0] as int;
    _db.execute(
      "delete from translated_chapter_index "
      "where scope_prefix >= ? and scope_prefix < ?;",
      args,
    );
    _localRevision++;
    if (removed > 0) _notifyChanged();
    return removed;
  }

  /// Wipes every stored translation across all comics, and records the wipe
  /// so other devices drop their copies on the next merge too.
  int clearAll() {
    if (!isInitialized) return 0;
    var newest =
        _db.select("select max(time) as t from translated_page;").first['t']
            as int? ??
        0;
    _recordTombstone(
      _keyPrefix,
      max(DateTime.now().millisecondsSinceEpoch, newest),
    );
    _db.execute("delete from translated_page;");
    var removed = _db.select("select changes();").first[0] as int;
    _db.execute("delete from translated_chapter_index;");
    _localRevision++;
    if (removed > 0) _notifyChanged();
    return removed;
  }

  /// Writes a self-contained copy of the store to [path] (which must not
  /// exist), for the translation-only export. Runs on a background isolate: a
  /// large store takes long enough to drop frames on the main one.
  Future<void> exportSnapshot(String path) {
    if (!isInitialized) {
      throw StateError("TranslationStore is not initialized; cannot export");
    }
    return _writeSnapshot(_dbPath, path);
  }

  // Static so the isolate closure can't capture this store and its timer.
  static Future<void> _writeSnapshot(String dbPath, String path) {
    return DatabaseGateway.instance.isolateOp(dbPath, (db) async {
      db.execute("vacuum into ?;", [path]);
    });
  }

  int get count {
    if (!isInitialized) return 0;
    try {
      return _db.select("select count(*) from translated_page;").first[0]
          as int;
    } catch (e, s) {
      Log.error("TranslationStore", "count failed: $e", s);
      return 0;
    }
  }

  /// How many stored pages have a key starting with [scopePrefix] — the same
  /// comic/chapter scope prefixes [deleteByPrefix] uses. Lets the chapter picker
  /// mark a chapter as translated straight from the durable store (which rides
  /// the WebDAV/backup merge), independent of any device-local task record —
  /// so a chapter translated on another device shows as done here too.
  int countByPrefix(String scopePrefix) {
    if (!isInitialized) return 0;
    try {
      var rows = _db.select(
        "select count(*) from translated_page "
        "where cache_key >= ? and cache_key < ?;",
        [scopePrefix, _prefixEnd(scopePrefix)],
      );
      return rows.first[0] as int;
    } catch (e, s) {
      Log.error("TranslationStore", "countByPrefix failed: $e", s);
      return 0;
    }
  }

  void close() {
    if (!isInitialized) return;
    _notifyTimer?.cancel();
    _notifyTimer = null;
    DatabaseGateway.instance.closeManaged(_dbPath);
    isInitialized = false;
  }

  void _notifyChanged() {
    _notifyTimer ??= Timer(const Duration(milliseconds: 250), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }
}

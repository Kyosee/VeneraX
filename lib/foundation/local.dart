import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/download_keepalive.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';

/// UI-facing guard for the four download entry points. Ensures the download
/// directory is writable, prompting for storage permission on Android when it
/// isn't (#89). Shows a message and returns false when downloads must not
/// proceed, so callers can simply `if (!await ensureDownloadStorageWritable())
/// return;`. Always true off Android.
Future<bool> ensureDownloadStorageWritable() async {
  if (await LocalManager().ensureDownloadWritable()) {
    return true;
  }
  App.rootContext.showMessage(
    message: "Storage permission is required to download comics".tl,
  );
  return false;
}

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  @override
  final String description;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
    this.description = "",
  });

  LocalComic.fromRow(Row row)
    : id = row['id'] as String,
      title = row['title'] as String,
      subtitle = row['subtitle'] as String,
      tags = List.from(jsonDecode(row['tags'] as String)),
      directory = row['directory'] as String,
      chapters =
          ComicChapters.fromJsonOrNull(jsonDecode(row['chapters'] as String)),
      cover = row['cover'] as String,
      comicType = ComicType(row['comic_type'] as int),
      downloadedChapters =
          List.from(jsonDecode(row['downloadedChapters'] as String)),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      description = (row['description'] as String?) ?? "";

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  LocalComicStatus get status {
    if (LocalManager().isDownloading(id, comicType)) {
      return LocalComicStatus.downloading;
    }
    final dir = Directory(baseDir);
    if (!dir.existsSync()) return LocalComicStatus.notDownloaded;
    try {
      final contents = dir.listSync();
      if (contents.isEmpty) return LocalComicStatus.notDownloaded;
      final hasContent = contents.any((e) =>
          e is File || (e is Directory && e.listSync().isNotEmpty));
      return hasContent
          ? LocalComicStatus.downloaded
          : LocalComicStatus.notDownloaded;
    } catch (_) {
      return LocalComicStatus.notDownloaded;
    }
  }

  @override
  String get sourceKey => comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              break;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  /// Sentinel returned by [setNewPath] when the chosen directory is not empty
  /// and the caller has not opted in to merging. Callers should compare the
  /// return value against this constant (not show it as an error) to decide
  /// whether to ask the user for confirmation.
  static const dirNotEmptySignal = "__venera_dir_not_empty__";

  // return error message if failed, [dirNotEmptySignal] if the target is not
  // empty and [allowNonEmpty] is false.
  Future<String?> setNewPath(String newPath, {bool allowNonEmpty = false}) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!allowNonEmpty && !await newDir.list().isEmpty) {
      // Don't hard-fail: let the caller confirm merging into a non-empty
      // directory (e.g. an existing folder on an SD card). Returning a sentinel
      // keeps the "must be empty" safety while giving the user a way forward.
      return dirNotEmptySignal;
    }
    final oldDir = directory;
    try {
      await copyDirectoryIsolate(oldDir, newDir);
      // Verify the copy looks complete before destroying the source. SAF
      // targets can fail silently; deleting the source after an incomplete
      // copy would lose data. We only abort when we can positively confirm the
      // destination has fewer files than the source — if the count itself
      // throws (slow/unsupported on some SAF impls), we trust the copy.
      if (!await _verifyCopied(oldDir, newDir)) {
        return "Failed to copy all files to the new location";
      }
      await File(
        FilePath.join(App.dataPath, 'local_path'),
      ).writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    // The data now lives at [newPath]; clearing the old directory is
    // best-effort. A failure here must not roll back the switch, so swallow it.
    try {
      await oldDir.deleteContents(recursive: true);
    } catch (e, s) {
      Log.error("IO", "Failed to clean old storage path: $e", s);
    }
    path = newPath;
    _checkNoMedia();
    return null;
  }

  /// Best-effort completeness check: returns false only when the destination is
  /// confirmed to contain fewer files than the source. Any error while counting
  /// is treated as "cannot disprove" and returns true so a valid copy is not
  /// rejected on platforms where recursive listing is unreliable.
  Future<bool> _verifyCopied(Directory source, Directory dest) async {
    try {
      int countFiles(Directory d) {
        if (!d.existsSync()) return 0;
        return d.listSync(recursive: true).whereType<File>().length;
      }

      final srcCount = countFiles(source);
      final dstCount = countFiles(dest);
      if (srcCount == 0) return true;
      return dstCount >= srcCount;
    } catch (e, s) {
      Log.error("IO", "Copy verification skipped: $e", s);
      return true;
    }
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
    }
  }

  bool isInitialized = false;

  String get _dbPath => '${App.dataPath}/local.db';

  void close() {
    if (!isInitialized) return;
    isInitialized = false;
    DatabaseGateway.instance.closeManaged(_dbPath);
  }

  Future<void> init() async {
    _db = DatabaseGateway.instance.openManaged(_dbPath);
    _ensureSchema();
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    _checkPathValidation();
    _checkNoMedia();
    isInitialized = true;
    await ComicSourceManager().ensureInit();
    restoreDownloadingTasks();
    // Defer auto-resume so a cold start (DB init, home page) isn't competing
    // with download network/IO, and to steer clear of startup races in this
    // historically crash-prone path. Tasks the user manually paused stay paused
    // (wasRunning was persisted as false for them).
    Future.delayed(const Duration(seconds: 3), _autoResumeDownloads);
  }

  /// Creates the comics table when missing and upgrades older layouts.
  /// Idempotent; also run after [restoreFrom], whose page-level copy may bring
  /// in a backup created by an older app version.
  void _ensureSchema() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        description TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (id, comic_type)
      );
    ''');
    final cols = _db
        .select('PRAGMA table_info(comics);')
        .map((r) => r['name'] as String)
        .toList();
    if (!cols.contains('description')) {
      _db.execute(
          "ALTER TABLE comics ADD COLUMN description TEXT NOT NULL DEFAULT '';");
    }
  }

  /// Replaces the local-library database content with the file at
  /// [sourcePath] by closing the connection, swapping the file, and
  /// reopening — see [restoreDatabaseFiles]. Path configuration, download-task
  /// state and comic-source init are process-level and deliberately not
  /// re-run here.
  Future<void> restoreFrom(String sourcePath) async {
    if (!isInitialized) {
      throw StateError("LocalManager is not initialized; cannot restore");
    }
    DatabaseGateway.instance.closeManaged(_dbPath);
    try {
      restoreDatabaseFiles({_dbPath: sourcePath});
    } finally {
      _db = DatabaseGateway.instance.openManaged(_dbPath);
    }
    _ensureSchema();
    notifyListeners();
  }

  /// Resume downloads that were genuinely running when the app was last closed,
  /// up to the configured parallelism. Tasks the user manually paused stay
  /// paused (wasRunning was persisted as false for them).
  void _autoResumeDownloads() {
    final limit = _maxParallelDownloads;
    var started = 0;
    for (final t in downloadingTasks) {
      if (started >= limit) break;
      if (t.wasRunning && !t.isError && !t.userPaused) {
        t.resume();
        started++;
      }
    }
    if (started > 0) {
      DownloadKeepAlive.instance.refresh();
    }
  }

  String findValidId(ComicType type) {
    final res = _db.select(
      '''
      SELECT id FROM comics WHERE comic_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    return (int.parse((res.first[0])) + 1).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    var old = find(id ?? comic.id, comic.comicType);
    var downloaded = comic.downloadedChapters;
    if (old != null) {
      downloaded.addAll(old.downloadedChapters);
    }
    _db.execute(
      'INSERT OR REPLACE INTO comics '
      '(id, title, subtitle, tags, directory, chapters, cover, comic_type, '
      'downloadedChapters, created_at, description) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id ?? comic.id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded),
        comic.createdAt.millisecondsSinceEpoch,
        comic.description,
      ],
    );
    try {
      const ComicStateRepository().mirrorLocalComic(comic);
    } catch (_) {}
    notifyListeners();
  }

  void remove(String id, ComicType comicType) async {
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
    notifyListeners();
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    if (sortType == LocalSortType.lastRead) {
      return _getComicsSortedByLastRead();
    }
    if (sortType == LocalSortType.author) {
      return _getComicsSortedByAuthor();
    }
    String orderColumn;
    String orderDir;
    switch (sortType) {
      case LocalSortType.name:
        orderColumn = 'title';
        orderDir = 'ASC';
      case LocalSortType.nameDesc:
        orderColumn = 'title';
        orderDir = 'DESC';
      case LocalSortType.timeAsc:
        orderColumn = 'created_at';
        orderDir = 'ASC';
      case LocalSortType.timeDesc:
        orderColumn = 'created_at';
        orderDir = 'DESC';
      default:
        orderColumn = 'created_at';
        orderDir = 'DESC';
    }
    var res = _db.select('''
      SELECT * FROM comics ORDER BY $orderColumn $orderDir;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  List<LocalComic> getComicsByStatus(LocalComicStatus status, LocalSortType sortType) {
    return getComics(sortType).where((c) => c.status == status).toList();
  }

  bool hasComicsWithImages() {
    return getComics(LocalSortType.defaultSort).any(
      (c) => c.status == LocalComicStatus.downloaded,
    );
  }

  List<LocalComic> _getComicsSortedByAuthor() {
    var res = _db.select('SELECT * FROM comics;');
    var comics = res.map((row) => LocalComic.fromRow(row)).toList();
    comics.sort((a, b) => a.subtitle.compareTo(b.subtitle));
    return comics;
  }

  List<LocalComic> _getComicsSortedByLastRead() {
    var allComics = _db.select('SELECT * FROM comics;');
    var comics = allComics.map((row) => LocalComic.fromRow(row)).toList();
    comics.sort((a, b) {
      var historyA = HistoryManager().find(a.id, a.comicType);
      var historyB = HistoryManager().find(b.id, b.comicType);
      var timeA = historyA?.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      var timeB = historyB?.time ?? DateTime.fromMillisecondsSinceEpoch(0);
      return timeB.compareTo(timeA);
    });
    return comics;
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  @override
  void dispose() {
    super.dispose();
    DatabaseGateway.instance.closeManaged(_dbPath);
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var comic = find(id, type) ?? (throw "Comic Not Found");
    var directory = Directory(comic.baseDir);
    if (comic.hasChapters) {
      var cid = ep is int
          ? comic.chapters!.ids.elementAt(ep - 1)
          : (ep as String);
      cid = getChapterDirectoryName(cid);
      directory = Directory(FilePath.join(directory.path, cid));
    }
    var files = <File>[];
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude comic.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a comic page.
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        files.add(entity);
      }
    }
    files.sort((a, b) {
      var ai = int.tryParse(a.name.split('.').first);
      var bi = int.tryParse(b.name.split('.').first);
      if (ai != null && bi != null) {
        return ai.compareTo(bi);
      }
      return a.name.compareTo(b.name);
    });
    return files.map((e) => "file://${e.path}").toList();
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
            description: comic.description,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1),
    );
  }

  List<DownloadTask> downloadingTasks = [];

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(FilePath.join(path, comic.directory));
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  void completeTask(DownloadTask task) {
    final finishedTitle = task.title;
    add(task.toLocalComic());
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    // Notify when the whole queue has drained (nothing left, or only paused/
    // errored leftovers) so a background download run ends with a single
    // "done" notification rather than silence (#10).
    final moreToRun = downloadingTasks.any((t) => !t.isError && !t.userPaused);
    if (!moreToRun) {
      DownloadKeepAlive.instance.notifyComplete(finishedTitle);
    }
    _advanceQueue();
  }

  void removeTask(DownloadTask task) {
    downloadingTasks.remove(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    // Advance so cancelling the active task doesn't stall the rest of the queue.
    _advanceQueue();
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.first != task) {
      var shouldResume = !downloadingTasks.first.isPaused;
      downloadingTasks.first.pause();
      downloadingTasks.remove(task);
      downloadingTasks.insert(0, task);
      notifyListeners();
      saveCurrentDownloadingTasks();
      if (shouldResume) {
        downloadingTasks.first.resume();
      }
      DownloadKeepAlive.instance.refresh();
    }
  }

  /// User-initiated pause of a single task. Marks it [DownloadTask.userPaused]
  /// so the queue won't auto-resume it, then lets the queue fill the freed slot
  /// with the next runnable task (#9).
  void pauseTask(DownloadTask task) {
    task.userPaused = true;
    task.pause();
    notifyListeners();
    _advanceQueue();
  }

  /// User-initiated resume/retry of a single task. Clears [userPaused] and the
  /// auto-retry budget so an errored task gets a fresh start (#9 retry).
  void resumeTask(DownloadTask task) {
    task.userPaused = false;
    task.autoRetryCount = 0;
    task.resume();
    notifyListeners();
    DownloadKeepAlive.instance.refresh();
  }

  /// Pause every task and remember that the user did so, so nothing auto-resumes
  /// until the user explicitly resumes (#9).
  void pauseAll() {
    for (final t in downloadingTasks) {
      t.userPaused = true;
      if (!t.isPaused) t.pause();
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    DownloadKeepAlive.instance.refresh();
  }

  /// Clear the user-paused flag on every task and let the queue resume up to the
  /// configured parallelism (#9).
  void resumeAll() {
    for (final t in downloadingTasks) {
      t.userPaused = false;
      t.autoRetryCount = 0;
    }
    notifyListeners();
    _advanceQueue();
  }

  /// Cancel every queued/active download (#9). Iterates over a copy because
  /// [DownloadTask.cancel] mutates [downloadingTasks].
  void cancelAll() {
    for (final t in downloadingTasks.toList()) {
      t.cancel();
    }
    notifyListeners();
    DownloadKeepAlive.instance.refresh();
  }

  /// Reorder a task within the queue (drag-and-drop, #9). Pauses whatever was
  /// running and re-fills slots from the new order so the user's intended
  /// priority takes effect immediately. [newIndex] is a final list index
  /// (already adjusted for the removal, as `onReorderItem` reports).
  void reorderTask(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= downloadingTasks.length) return;
    if (newIndex < 0 || newIndex >= downloadingTasks.length) return;
    if (oldIndex == newIndex) return;
    final task = downloadingTasks.removeAt(oldIndex);
    downloadingTasks.insert(newIndex, task);
    // Pause non-user-paused running tasks so _advanceQueue re-picks from the
    // top of the new order rather than leaving a lower-priority task running.
    for (final t in downloadingTasks) {
      if (!t.userPaused && !t.isPaused && !t.isError) t.pause();
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  static const _maxAutoRetry = 3;

  /// True while the network guard wants downloads held (e.g. "WiFi only" is on
  /// and the device is on cellular). Queued tasks won't auto-resume and active
  /// ones are paused until the block clears (#15).
  bool _networkBlocked = false;

  /// Toggle the metered-network block. When blocking, pauses currently-running
  /// tasks WITHOUT marking them user-paused, so they auto-resume once an
  /// unmetered connection returns. When unblocking, re-fills the queue.
  void setNetworkBlocked(bool blocked) {
    if (_networkBlocked == blocked) return;
    _networkBlocked = blocked;
    if (blocked) {
      for (final t in downloadingTasks) {
        if (!t.isPaused && !t.isError) t.pause();
      }
      notifyListeners();
      saveCurrentDownloadingTasks();
      DownloadKeepAlive.instance.refresh();
    } else {
      _advanceQueue();
    }
  }

  /// Invoked by a task when it enters the error state. Keeps the queue moving:
  /// the failed task is parked at the end so a persistent failure can't block
  /// healthy tasks, then the next runnable task starts. A few bounded, delayed
  /// auto-retries are attempted before leaving it for the user (#7).
  void onTaskError(DownloadTask task) {
    if (!downloadingTasks.contains(task)) return;
    if (downloadingTasks.length > 1 && downloadingTasks.first == task) {
      downloadingTasks.remove(task);
      downloadingTasks.add(task);
    }
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  /// How many comics may download at once. Default 1 keeps the historical
  /// serial behavior; the user can opt into 2–3 (#3).
  int get _maxParallelDownloads {
    final v = (appdata.settings["maxParallelDownloads"] as num?)?.toInt() ?? 1;
    return v.clamp(1, 3);
  }

  /// Ensure up to [_maxParallelDownloads] non-error tasks are downloading,
  /// resuming queued ones in order. If every task has errored, fall back to a
  /// bounded delayed auto-retry of the least-tried task (#7).
  void _advanceQueue() {
    if (downloadingTasks.isEmpty) {
      DownloadKeepAlive.instance.refresh();
      return;
    }
    // Metered-network block ("WiFi only"): pause anything running without
    // marking it user-paused, and resume nothing until the block clears.
    if (_networkBlocked) {
      for (final t in downloadingTasks) {
        if (!t.isPaused && !t.isError) t.pause();
      }
      DownloadKeepAlive.instance.refresh();
      return;
    }
    final limit = _maxParallelDownloads;
    for (final t in downloadingTasks) {
      final running =
          downloadingTasks.where((x) => !x.isPaused && !x.isError).length;
      if (running >= limit) break;
      // A user-paused task waits for the user; only auto-resume tasks that are
      // merely queued (paused but not user-paused) and not in error.
      if (!t.isError && t.isPaused && !t.userPaused) {
        t.resume();
      }
    }
    DownloadKeepAlive.instance.refresh();
    // Only fall back to error auto-retry when nothing is runnable AND the user
    // hasn't deliberately paused everything.
    final anyRunning = downloadingTasks.any((t) => !t.isPaused && !t.isError);
    final anyQueued =
        downloadingTasks.any((t) => t.isPaused && !t.userPaused && !t.isError);
    if (!anyRunning && !anyQueued) {
      _scheduleErrorAutoRetry();
    }
  }

  /// All tasks have errored: give the least-tried one a delayed auto-retry,
  /// up to [_maxAutoRetry] attempts, then leave it for the user.
  void _scheduleErrorAutoRetry() {
    DownloadTask? candidate;
    for (final t in downloadingTasks) {
      if (t.autoRetryCount >= _maxAutoRetry) continue;
      if (candidate == null || t.autoRetryCount < candidate.autoRetryCount) {
        candidate = t;
      }
    }
    if (candidate == null) return; // gave up; the user can retry manually
    final task = candidate;
    task.autoRetryCount++;
    final delay = Duration(seconds: 15 * task.autoRetryCount); // 15s/30s/45s
    Future.delayed(delay, () {
      if (!downloadingTasks.contains(task) || !task.isError) return;
      if (downloadingTasks.any((t) => !t.isPaused && !t.isError)) return;
      task.resume();
      DownloadKeepAlive.instance.refresh();
    });
  }

  Timer? _saveDebounce;
  bool _isSavingTasks = false;
  bool _saveTasksAgain = false;

  /// Debounced, low-priority persistence for the high-frequency per-image
  /// progress updates. Coalesces a burst of calls into at most one write per
  /// ~1.5s instead of re-serializing the entire task list (including every
  /// chapter's image-URL map) on every single image — see #1.
  void scheduleSaveDownloadingTasks() {
    _saveDebounce ??= Timer(const Duration(milliseconds: 1500), () {
      _saveDebounce = null;
      _flushDownloadingTasks();
    });
  }

  /// Durable, immediate persistence for important transitions (add/remove/
  /// complete/pause, chapter list fetched, etc.). Flushes any pending debounce.
  Future<void> saveCurrentDownloadingTasks() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    await _flushDownloadingTasks();
  }

  /// Single-flight, atomic writer. Serializes all writes through one in-flight
  /// operation (re-running once if more changes arrived meanwhile) so two
  /// concurrent `writeAsString` calls can never interleave and corrupt
  /// downloading_tasks.json — see B4. Writes to a temp file then renames.
  Future<void> _flushDownloadingTasks() async {
    if (_isSavingTasks) {
      _saveTasksAgain = true;
      return;
    }
    _isSavingTasks = true;
    try {
      final path = FilePath.join(App.dataPath, 'downloading_tasks.json');
      final tmp = '$path.tmp';
      do {
        _saveTasksAgain = false;
        final data = jsonEncode(downloadingTasks.map((e) => e.toJson()).toList());
        final tmpFile = File(tmp);
        await tmpFile.writeAsString(data, flush: true);
        try {
          // rename() does not overwrite an existing file on Windows, so remove
          // the destination first. If the rename still fails (e.g. cross-device
          // temp dir), fall back to a direct write.
          final dest = File(path);
          if (dest.existsSync()) dest.deleteSync();
          tmpFile.renameSync(path);
        } catch (_) {
          await File(path).writeAsString(data, flush: true);
          tmpFile.deleteIgnoreError();
        }
      } while (_saveTasksAgain);
    } catch (e) {
      Log.error("LocalManager", "Failed to save downloading tasks: $e");
    } finally {
      _isSavingTasks = false;
    }
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, 'downloading_tasks.json'));
    if (file.existsSync()) {
      try {
        var tasks = jsonDecode(file.readAsStringSync());
        for (var e in tasks) {
          var task = DownloadTask.fromJson(e);
          if (task != null) {
            downloadingTasks.add(task);
          }
        }
      } catch (e) {
        file.delete();
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
  }

  /// Ensures the download directory is actually writable before a download is
  /// enqueued. On Android a custom folder in shared storage silently no-ops
  /// writes without all-files-access permission, so a download would "finish"
  /// while nothing lands on disk (#89). This probes the folder, requests the
  /// permission when it's missing, and re-resolves the saved path so the user's
  /// chosen folder is restored without an app restart.
  ///
  /// Returns true when downloads may proceed. Non-Android platforms always
  /// return true.
  Future<bool> ensureDownloadWritable() async {
    if (!App.isAndroid) return true;
    var savedPathFile = File(FilePath.join(App.dataPath, 'local_path'));
    var saved = savedPathFile.existsSync()
        ? savedPathFile.readAsStringSync().trim()
        : '';
    // A custom download folder in shared storage is the #89 scenario. Without
    // all-files access, init()'s validation either silently keeps it (writes
    // no-op rather than throw, so the folder stays selected but downloads land
    // nowhere) or falls back to app-private storage (so `path` is writable but
    // points at the wrong place). Either way, make the user's *chosen* folder
    // writable first so downloads land where they expect — don't let a writable
    // fallback path mask the problem.
    if (saved.isNotEmpty && saved != path) {
      if (await StoragePermission.ensureGranted(saved)) {
        path = saved;
        _checkNoMedia();
        return true;
      }
      // The user's folder still isn't writable even after prompting. Refuse
      // rather than silently downloading into the fallback location, which is
      // exactly the "looks done but folder is empty" symptom being fixed.
      return false;
    }
    // No custom folder (default is app-private external storage, writable
    // without the permission), or it's already the active path: just verify.
    return await StoragePermission.ensureGranted(path);
  }

  void addTask(DownloadTask task) {
    downloadingTasks.add(task);
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  /// Enqueue several tasks at once with a single persistence write and a single
  /// queue advance, instead of paying both costs per comic. Used by batch
  /// "download selected" so adding 50 comics doesn't trigger 50 full-list
  /// serializations (#17).
  void addTasks(Iterable<DownloadTask> tasks) {
    var added = false;
    for (final task in tasks) {
      downloadingTasks.add(task);
      added = true;
    }
    if (!added) return;
    notifyListeners();
    saveCurrentDownloadingTasks();
    _advanceQueue();
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    if (removeFileOnDisk) {
      var dir = Directory(FilePath.join(path, c.directory));
      dir.deleteIgnoreError(recursive: true);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
    notifyListeners();
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(newDownloadedChapters), c.id, c.comicType.value],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
    }
    var shouldRemovedDirs = <Directory>[];
    for (var chapter in chapters) {
      var dir = Directory(
        FilePath.join(c.baseDir, getChapterDirectoryName(chapter)),
      );
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _deleteDirectories(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk) {
          var dir = Directory(FilePath.join(path, c.directory));
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  /// Deletes the directories without blocking the UI thread.
  ///
  /// On Android the file paths may be SAF (android://) URIs that can only be
  /// resolved through [SAFTaskWorker], so deletion runs in a dedicated isolate
  /// that initializes the worker. On other platforms the paths are plain file
  /// system paths, so we delete them directly with async I/O — spawning a SAF
  /// isolate there is unnecessary and, because the worker's receive port is
  /// never closed, leaks an isolate on every delete (and could hang on
  /// platforms without the SAF channel).
  static void _deleteDirectories(List<Directory> directories) {
    if (directories.isEmpty) return;
    if (App.isAndroid) {
      Isolate.run(() async {
        await SAFTaskWorker().init();
        for (var dir in directories) {
          try {
            if (dir.existsSync()) {
              await dir.delete(recursive: true);
            }
          } catch (e) {
            continue;
          }
        }
      });
    } else {
      for (var dir in directories) {
        dir.deleteIgnoreError(recursive: true);
      }
    }
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }
}

enum LocalSortType {
  defaultSort("default"),
  name("name"),
  nameDesc("name_desc"),
  timeDesc("time_desc"),
  timeAsc("time_asc"),
  author("author"),
  lastRead("last_read");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return defaultSort;
  }
}

enum LocalComicStatus {
  downloaded,
  downloading,
  notDownloaded,
}

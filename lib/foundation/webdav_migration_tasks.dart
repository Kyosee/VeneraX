import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/webdav_library.dart';

// --- Layout naming (pure functions, unit-tested) ---------------------------
// The WebDAV comic source browses a folder tree where a comic is a folder named
// by its title, holding either chapter subfolders (named by chapter title) or
// images directly, plus an optional cover. Local storage instead uses opaque
// directory ids, numeric chapter dirs and `1.jpg` image names, which is exactly
// why a raw copy is unreadable by the source (issue #149). These helpers map a
// local comic onto the layout the source reads back.

/// Sanitizes [title] into a folder name and de-duplicates it against [used]
/// (mutated), appending ` (2)`, ` (3)`… on collision so two comics or chapters
/// sharing a title don't overwrite each other. Always returns a non-empty name.
String migrationUniqueFolderName(String title, Set<String> used) {
  var base = _sanitizeSegment(title);
  if (base.isEmpty) base = 'untitled';
  var name = base;
  var n = 2;
  while (used.contains(name)) {
    name = '$base ($n)';
    n++;
  }
  used.add(name);
  return name;
}

/// Chapter folder name. When [numericPrefix] is true a zero-padded ordinal is
/// prepended (`01_Prologue`) so the source — which orders chapters by folder
/// name — preserves the original reading order even when titles don't sort
/// naturally (e.g. `Prologue`/`Chapter 1`/`Chapter 10`). [index] is 0-based,
/// [total] the chapter count (drives the prefix width). De-dupes via [used].
String migrationChapterFolderName(
  String title,
  int index,
  int total, {
  required bool numericPrefix,
  required Set<String> used,
}) {
  var base = _sanitizeSegment(title);
  if (base.isEmpty) base = 'chapter_${index + 1}';
  if (numericPrefix) {
    final width = total.toString().length;
    base = '${(index + 1).toString().padLeft(width, '0')}_$base';
  }
  var name = base;
  var n = 2;
  while (used.contains(name)) {
    name = '$base ($n)';
    n++;
  }
  used.add(name);
  return name;
}

/// Zero-padded page file name (`001.jpg`) so the source's natural sort keeps
/// pages in order. [index] is 0-based, [total] the page count, [ext] the source
/// image extension without a dot (empty falls back to `jpg`).
String migrationImageName(int index, int total, String ext) {
  final width = total.toString().length < 3 ? 3 : total.toString().length;
  final e = ext.trim().isEmpty ? 'jpg' : ext.trim();
  return '${(index + 1).toString().padLeft(width, '0')}.$e';
}

/// File extension (no dot, lower-case) of a `file://…`/plain path, or '' if none.
String migrationExtOf(String path) {
  var p = path;
  final slash = p.replaceAll('\\', '/').lastIndexOf('/');
  final base = slash < 0 ? p : p.substring(slash + 1);
  final dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// Same illegal-char stripping as [LocalManager.getChapterDirectoryName] but
/// also collapses whitespace and trims, since a folder name that is only spaces
/// or has trailing dots/spaces is rejected by some servers.
String _sanitizeSegment(String name) {
  final buf = StringBuffer();
  for (final ch in name.split('')) {
    if ('/\\:*?"<>|'.contains(ch)) {
      buf.write('_');
    } else {
      buf.write(ch);
    }
  }
  var out = buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  while (out.endsWith('.')) {
    out = out.substring(0, out.length - 1).trim();
  }
  return out;
}

// --- Task model ------------------------------------------------------------

enum WebdavMigrationStatus { running, paused, completed, canceled, failed }

/// Minimal persisted reference to a comic to migrate (mirrors ExportComicRef so
/// a task survives an app restart and resumes).
class MigrationComicRef {
  MigrationComicRef({
    required this.id,
    required this.comicTypeValue,
    required this.title,
  });

  final String id;
  final int comicTypeValue;
  final String title;

  String get key => '${id}_$comicTypeValue';

  ComicType get comicType => ComicType(comicTypeValue);

  Map<String, dynamic> toJson() => {
        'id': id,
        'comicTypeValue': comicTypeValue,
        'title': title,
      };

  factory MigrationComicRef.fromJson(Map<String, dynamic> json) =>
      MigrationComicRef(
        id: json['id'] ?? '',
        comicTypeValue: json['comicTypeValue'] ?? 0,
        title: json['title'] ?? '',
      );
}

/// A background upload of local comics into the configured WebDAV library,
/// re-laid-out so the WebDAV comic source can browse them (issue #149).
///
/// Progress is per-comic ([doneKeys]); a comic whose remote folder is already
/// populated is skipped, making the task resumable after pause or app restart.
class WebdavMigrationTask {
  WebdavMigrationTask({
    required this.id,
    required this.comics,
    required this.createdAt,
    required this.numericPrefix,
    Set<String>? doneKeys,
    this.failedCount = 0,
    this.status = WebdavMigrationStatus.running,
    this.currentTitle,
    this.currentComicProgress,
    this.error,
    this.finishedAt,
  }) : doneKeys = doneKeys ?? <String>{};

  final String id;
  final List<MigrationComicRef> comics;
  final DateTime createdAt;

  /// Chapter-folder naming choice, fixed for the whole task so a resume keeps
  /// the same remote layout it started with.
  final bool numericPrefix;

  final Set<String> doneKeys;
  int failedCount;
  WebdavMigrationStatus status;
  String? currentTitle;

  /// Fraction (0..1) of the comic currently uploading, or null when between
  /// comics. Drives a live bar inside a single (potentially large) comic.
  double? currentComicProgress;

  String? error;
  DateTime? finishedAt;

  int get total => comics.length;

  int get done => doneKeys.length;

  bool get isRunning => status == WebdavMigrationStatus.running;

  bool get isPaused => status == WebdavMigrationStatus.paused;

  bool get isActive =>
      status == WebdavMigrationStatus.running ||
      status == WebdavMigrationStatus.paused;

  double get progress => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
        'id': id,
        'comics': comics.map((e) => e.toJson()).toList(),
        'numericPrefix': numericPrefix,
        'doneKeys': doneKeys.toList(),
        'failedCount': failedCount,
        // Persist active tasks as paused so they are not auto-run on restart.
        'status': isActive
            ? WebdavMigrationStatus.paused.name
            : status.name,
        'error': error,
        'createdAt': createdAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
      };

  factory WebdavMigrationTask.fromJson(Map<String, dynamic> json) =>
      WebdavMigrationTask(
        id: json['id'] ?? '',
        comics: (json['comics'] as List? ?? [])
            .whereType<Map>()
            .map((e) => MigrationComicRef.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        numericPrefix: json['numericPrefix'] ?? true,
        doneKeys: (json['doneKeys'] as List? ?? []).map((e) => '$e').toSet(),
        failedCount: json['failedCount'] ?? 0,
        status: WebdavMigrationStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => WebdavMigrationStatus.paused,
        ),
        error: json['error'],
        createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
        finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      );
}

class WebdavMigrationTaskManager with ChangeNotifier {
  WebdavMigrationTaskManager._() {
    _restore();
  }

  static final WebdavMigrationTaskManager instance =
      WebdavMigrationTaskManager._();

  final currentTasks = <WebdavMigrationTask>[];
  final historyTasks = <WebdavMigrationTask>[];
  final _canceledIds = <String>{};
  final _pausedIds = <String>{};

  bool get hasActiveTask => currentTasks.any((t) => t.isActive);

  /// Starts a background migration of [comics] into the WebDAV library. Returns
  /// null if a migration is already active — only one runs at a time since they
  /// all write into the same remote root and would race on folder creation.
  WebdavMigrationTask? start(
    List<LocalComic> comics, {
    required bool numericPrefix,
  }) {
    if (currentTasks.any((t) => t.isActive)) {
      return null;
    }
    var task = WebdavMigrationTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      comics: comics
          .map((c) => MigrationComicRef(
                id: c.id,
                comicTypeValue: c.comicType.value,
                title: c.title,
              ))
          .toList(),
      createdAt: DateTime.now(),
      numericPrefix: numericPrefix,
    );
    currentTasks.insert(0, task);
    _persist();
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  void cancel(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    if (task.status == WebdavMigrationStatus.running) {
      _canceledIds.add(id);
      notifyListeners();
    } else {
      _pausedIds.remove(id);
      task.status = WebdavMigrationStatus.canceled;
      task.finishedAt = DateTime.now();
      currentTasks.remove(task);
      historyTasks.insert(0, task);
      _trimHistory();
      _persist();
      notifyListeners();
    }
  }

  void pause(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status != WebdavMigrationStatus.running) return;
    _pausedIds.add(id);
    notifyListeners();
  }

  void resume(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status == WebdavMigrationStatus.running) return;
    _pausedIds.remove(id);
    task.status = WebdavMigrationStatus.running;
    notifyListeners();
    unawaited(_run(task));
  }

  void removeTask(String id) {
    historyTasks.removeWhere((t) => t.id == id);
    _persist();
    notifyListeners();
  }

  void clearHistory() {
    historyTasks.clear();
    _persist();
    notifyListeners();
  }

  Future<void> _run(WebdavMigrationTask task) async {
    _refreshKeepAlive(task);
    String? lastError;
    // Folder name per comic, computed over the FULL list so the mapping is
    // identical across runs. Deriving it from a running set as comics complete
    // would break resume: an already-done same-titled comic is skipped and no
    // longer occupies its name, so a later comic could be reassigned the done
    // comic's folder and overwrite it (its de-dup suffix would shift).
    final folderNames = _assignFolderNames(task.comics);
    try {
      if (!WebdavLibrary.isConfigured) {
        throw 'WebDAV comic library is not configured';
      }
      final root = WebdavLibrary.migrationRoot;
      await WebdavLibrary.instance.ensureRemoteDir(root);

      for (final ref in task.comics) {
        if (_canceledIds.contains(task.id)) {
          task.status = WebdavMigrationStatus.canceled;
          break;
        }
        if (_pausedIds.contains(task.id)) {
          task.status = WebdavMigrationStatus.paused;
          task.currentTitle = null;
          task.currentComicProgress = null;
          notifyListeners();
          _persist();
          return; // stays in currentTasks; resumable
        }
        if (task.doneKeys.contains(ref.key)) {
          continue;
        }

        task.currentTitle = ref.title;
        task.currentComicProgress = null;
        notifyListeners();
        _refreshKeepAlive(task);

        final comic = LocalManager().find(ref.id, ref.comicType);
        if (comic == null ||
            comic.status != LocalComicStatus.downloaded) {
          // Deleted or not actually downloaded since the task was created.
          task.failedCount++;
          task.doneKeys.add(ref.key);
          notifyListeners();
          _persist();
          continue;
        }

        bool completed;
        try {
          final folderName = folderNames[ref.key] ??
              migrationUniqueFolderName(ref.title, <String>{});
          completed = await _migrateOne(task, comic, root, folderName);
        } catch (e, s) {
          Log.error('WebDAV Migration', e.toString(), s);
          task.failedCount++;
          lastError = e.toString();
          completed = true; // a genuine failure; don't retry this comic
        }
        // A false return means pause/cancel interrupted mid-comic: leave the
        // comic un-done and loop back so the top-of-loop guard sets the state
        // (paused → return & keep, canceled → break). Do NOT mark it done.
        if (!completed) {
          task.currentComicProgress = null;
          notifyListeners();
          _persist();
          continue;
        }
        task.doneKeys.add(ref.key);
        task.currentComicProgress = null;
        notifyListeners();
        _persist();
      }

      if (task.status == WebdavMigrationStatus.running) {
        if (task.failedCount >= task.total && task.total > 0) {
          task.status = WebdavMigrationStatus.failed;
          task.error = lastError ?? 'Migration failed';
        } else {
          task.status = WebdavMigrationStatus.completed;
        }
      }
    } catch (e, s) {
      task.status = WebdavMigrationStatus.failed;
      task.error = e.toString();
      Log.error('WebDAV Migration', e.toString(), s);
    } finally {
      task.currentComicProgress = null;
      if (task.status != WebdavMigrationStatus.paused) {
        task.currentTitle = null;
        task.finishedAt = DateTime.now();
        _canceledIds.remove(task.id);
        _pausedIds.remove(task.id);
        currentTasks.remove(task);
        historyTasks.insert(0, task);
        _trimHistory();
      }
      if (currentTasks.where((t) => t.isRunning).isEmpty) {
        BackgroundKeepAlive.instance
            .remove(BackgroundKeepAlive.tagWebdavMigration);
      }
      _persist();
      notifyListeners();
    }
  }

  /// Uploads one comic's cover + pages into `{root}/{title}/…` in the layout
  /// the WebDAV source reads back. Throws on a fatal per-comic error (the
  /// caller records it and moves on). Returns false if it stopped early because
  /// the task was paused/canceled mid-comic (so the caller must NOT mark the
  /// comic done — a resume re-uploads it cleanly); true on full upload.
  Future<bool> _migrateOne(
    WebdavMigrationTask task,
    LocalComic comic,
    String root,
    String folderName,
  ) async {
    final comicDir = '$root$folderName/';

    // Resume relies on [doneKeys], not on the remote folder state: a comic is
    // marked done only after a full upload, so a comic re-entered on resume is
    // genuinely incomplete and must be (re)uploaded. Names are deterministic
    // for a given task (folder de-dup order + fixed [numericPrefix]), so a
    // re-upload overwrites the same paths — idempotent, and it repairs a folder
    // left partial by an app kill mid-upload rather than skipping it forever.
    await WebdavLibrary.instance.ensureRemoteDir(comicDir);

    // Collect the upload plan first so progress has a real denominator.
    final uploads = <({String local, String remote})>[];

    // Cover.
    final coverFile = comic.coverFile;
    if (await coverFile.exists()) {
      final ext = migrationExtOf(coverFile.path);
      uploads.add((
        local: coverFile.path,
        remote: '${comicDir}cover.${ext.isEmpty ? 'jpg' : ext}',
      ));
    }

    if (!comic.hasChapters) {
      final images = await LocalManager().getImages(comic.id, comic.comicType, 1);
      for (var i = 0; i < images.length; i++) {
        final local = _stripScheme(images[i]);
        uploads.add((
          local: local,
          remote: '$comicDir${migrationImageName(i, images.length, migrationExtOf(local))}',
        ));
      }
    } else {
      final chapters = comic.chapters!;
      final ids = chapters.ids.toList();
      final usedChapterNames = <String>{};
      // Only migrate downloaded chapters, preserving their reading order.
      for (var ci = 0; ci < ids.length; ci++) {
        final cid = ids[ci];
        if (!comic.downloadedChapters.contains(cid)) continue;
        final title = chapters[cid] ?? cid;
        final folder = migrationChapterFolderName(
          title,
          ci,
          ids.length,
          numericPrefix: task.numericPrefix,
          used: usedChapterNames,
        );
        final chapterDir = '$comicDir$folder/';
        await WebdavLibrary.instance.ensureRemoteDir(chapterDir);
        final images =
            await LocalManager().getImages(comic.id, comic.comicType, cid);
        for (var i = 0; i < images.length; i++) {
          final local = _stripScheme(images[i]);
          uploads.add((
            local: local,
            remote: '$chapterDir${migrationImageName(i, images.length, migrationExtOf(local))}',
          ));
        }
      }
    }

    if (uploads.isEmpty) {
      throw 'No images to migrate';
    }

    for (var i = 0; i < uploads.length; i++) {
      // A large comic (many chapters/pages) can take a while, so honour a
      // pause/cancel between individual images rather than only between comics.
      // Signalled to the caller by returning false — the comic stays un-done so
      // a resume re-uploads it from scratch (overwriting the partial folder).
      if (_canceledIds.contains(task.id) || _pausedIds.contains(task.id)) {
        return false;
      }
      final u = uploads[i];
      await WebdavLibrary.instance.uploadFile(u.local, u.remote);
      task.currentComicProgress = (i + 1) / uploads.length;
      notifyListeners();
    }
    return true;
  }

  void _refreshKeepAlive(WebdavMigrationTask task) {
    BackgroundKeepAlive.instance.update(
      BackgroundKeepAlive.tagWebdavMigration,
      formatTaskStatus(
        title: task.currentTitle ?? 'WebDAV Migration',
        detail: task.total == 0 ? null : '${task.done}/${task.total}',
      ),
    );
  }

  void _trimHistory() {
    if (historyTasks.length > 50) {
      historyTasks.removeRange(50, historyTasks.length);
    }
  }

  void _persist() {
    appdata.implicitData['webdav_migration_current'] =
        currentTasks.map((t) => t.toJson()).toList();
    appdata.implicitData['webdav_migration_history'] =
        historyTasks.map((t) => t.toJson()).toList();
    appdata.writeImplicitData();
  }

  void _restore() {
    var current = appdata.implicitData['webdav_migration_current'];
    if (current is List) {
      currentTasks
        ..clear()
        ..addAll(current.whereType<Map>().map(
              (e) =>
                  WebdavMigrationTask.fromJson(Map<String, dynamic>.from(e)),
            ));
    }
    var history = appdata.implicitData['webdav_migration_history'];
    if (history is List) {
      historyTasks
        ..clear()
        ..addAll(history.whereType<Map>().map(
              (e) =>
                  WebdavMigrationTask.fromJson(Map<String, dynamic>.from(e)),
            ));
    }
  }

  static String _stripScheme(String path) =>
      path.startsWith('file://') ? path.substring('file://'.length) : path;

  /// Deterministically maps each comic (by [MigrationComicRef.key]) to its
  /// remote folder name, de-duplicating same-titled comics in list order. Runs
  /// over the full list regardless of done state so the assignment is identical
  /// on every run — the guarantee a resume relies on (see [_run]).
  static Map<String, String> _assignFolderNames(
    List<MigrationComicRef> comics,
  ) {
    final used = <String>{};
    final result = <String, String>{};
    for (final ref in comics) {
      result[ref.key] = migrationUniqueFolderName(ref.title, used);
    }
    return result;
  }
}

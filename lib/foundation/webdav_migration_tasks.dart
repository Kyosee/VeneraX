import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/utils/io.dart';

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

enum WebdavMigrationFailureReason {
  comicUnavailable,
  directoryMissing,
  noImages,
  readFailed,
  uploadFailed,
  unknown,
}

class WebdavMigrationFailure {
  const WebdavMigrationFailure({
    required this.comicKey,
    required this.comicTitle,
    required this.reason,
    this.chapterTitle,
  });

  final String comicKey;
  final String comicTitle;
  final String? chapterTitle;
  final WebdavMigrationFailureReason reason;

  Map<String, dynamic> toJson() => {
    'comicKey': comicKey,
    'comicTitle': comicTitle,
    'chapterTitle': chapterTitle,
    'reason': reason.name,
  };

  factory WebdavMigrationFailure.fromJson(Map<String, dynamic> json) =>
      WebdavMigrationFailure(
        comicKey: json['comicKey']?.toString() ?? '',
        comicTitle: json['comicTitle']?.toString() ?? '',
        chapterTitle: json['chapterTitle']?.toString(),
        reason: WebdavMigrationFailureReason.values.firstWhere(
          (e) => e.name == json['reason'],
          orElse: () => WebdavMigrationFailureReason.unknown,
        ),
      );
}

class WebdavMigrationUploadPlan {
  const WebdavMigrationUploadPlan({
    required this.remoteDirectories,
    required this.uploads,
    required this.failures,
  });

  final List<String> remoteDirectories;
  final List<({String local, String remote, String? chapterTitle})> uploads;
  final List<WebdavMigrationFailure> failures;
}

/// Builds and validates the complete local upload plan before remote writes.
Future<WebdavMigrationUploadPlan> prepareWebdavMigrationUpload({
  required LocalComic comic,
  required String comicDir,
  required bool numericPrefix,
}) async {
  final comicKey = '${comic.id}_${comic.comicType.value}';
  final remoteDirectories = <String>{comicDir};
  final uploads = <({String local, String remote, String? chapterTitle})>[];
  final failures = <WebdavMigrationFailure>[];
  var pageCount = 0;

  void addFailure(WebdavMigrationFailureReason reason, {String? chapterTitle}) {
    failures.add(
      WebdavMigrationFailure(
        comicKey: comicKey,
        comicTitle: comic.title,
        chapterTitle: chapterTitle,
        reason: reason,
      ),
    );
  }

  Future<void> addPages(
    Object chapter,
    String remoteDir, {
    String? chapterTitle,
  }) async {
    final localDirectory = comic.hasChapters
        ? Directory(
            FilePath.join(
              comic.baseDir,
              LocalManager.getChapterDirectoryName(chapter.toString()),
            ),
          )
        : Directory(comic.baseDir);
    if (!await localDirectory.exists()) {
      addFailure(
        WebdavMigrationFailureReason.directoryMissing,
        chapterTitle: chapterTitle,
      );
      return;
    }

    List<String> images;
    try {
      images = await LocalManager().getImagesForComic(comic, chapter);
    } catch (e, s) {
      Log.error('WebDAV Migration', 'Failed to inspect local files: $e', s);
      addFailure(
        WebdavMigrationFailureReason.readFailed,
        chapterTitle: chapterTitle,
      );
      return;
    }
    if (images.isEmpty) {
      addFailure(
        WebdavMigrationFailureReason.noImages,
        chapterTitle: chapterTitle,
      );
      return;
    }

    remoteDirectories.add(remoteDir);
    pageCount += images.length;
    for (var i = 0; i < images.length; i++) {
      final local = _stripFileScheme(images[i]);
      uploads.add((
        local: local,
        remote:
            '$remoteDir${migrationImageName(i, images.length, migrationExtOf(local))}',
        chapterTitle: chapterTitle,
      ));
    }
  }

  final coverFile = comic.coverFile;
  if (await coverFile.exists()) {
    final ext = migrationExtOf(coverFile.path);
    uploads.add((
      local: coverFile.path,
      remote: '${comicDir}cover.${ext.isEmpty ? 'jpg' : ext}',
      chapterTitle: null,
    ));
  }

  if (!comic.hasChapters) {
    await addPages(1, comicDir);
  } else if (comic.chapters!.isGrouped) {
    final chapters = comic.chapters!;
    final groupNames = chapters.groups.toList();
    final usedGroupNames = <String>{};
    for (var gi = 0; gi < groupNames.length; gi++) {
      final groupName = groupNames[gi];
      final group = chapters.getGroup(groupName);
      final groupIds = group.keys.toList();
      if (!groupIds.any(comic.downloadedChapters.contains)) continue;
      final groupFolder = migrationChapterFolderName(
        groupName,
        gi,
        groupNames.length,
        numericPrefix: numericPrefix,
        used: usedGroupNames,
      );
      final groupDir = '$comicDir$groupFolder/';
      remoteDirectories.add(groupDir);
      final usedChapterNames = <String>{};
      for (var ci = 0; ci < groupIds.length; ci++) {
        final chapterId = groupIds[ci];
        if (!comic.downloadedChapters.contains(chapterId)) continue;
        final title = group[chapterId] ?? chapterId;
        final folder = migrationChapterFolderName(
          title,
          ci,
          groupIds.length,
          numericPrefix: numericPrefix,
          used: usedChapterNames,
        );
        final chapterTitle = '$groupName / $title';
        await addPages(
          chapterId,
          '$groupDir$folder/',
          chapterTitle: chapterTitle,
        );
      }
    }
  } else {
    final chapters = comic.chapters!;
    final ids = chapters.ids.toList();
    final usedChapterNames = <String>{};
    for (var ci = 0; ci < ids.length; ci++) {
      final chapterId = ids[ci];
      if (!comic.downloadedChapters.contains(chapterId)) continue;
      final title = chapters[chapterId] ?? chapterId;
      final folder = migrationChapterFolderName(
        title,
        ci,
        ids.length,
        numericPrefix: numericPrefix,
        used: usedChapterNames,
      );
      await addPages(chapterId, '$comicDir$folder/', chapterTitle: title);
    }
  }

  if (pageCount == 0 && failures.isEmpty) {
    addFailure(WebdavMigrationFailureReason.noImages);
  }
  return WebdavMigrationUploadPlan(
    remoteDirectories: remoteDirectories.toList(),
    uploads: uploads,
    failures: failures,
  );
}

class _WebdavMigrationException implements Exception {
  const _WebdavMigrationException(this.failures, [this.cause]);

  final List<WebdavMigrationFailure> failures;
  final Object? cause;

  @override
  String toString() => cause?.toString() ?? 'Migration failed';
}

String _stripFileScheme(String path) =>
    path.startsWith('file://') ? path.substring('file://'.length) : path;

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
/// Progress is per-comic ([doneKeys]), so the task is resumable after a pause or
/// an app restart. With [skipExisting] on, comics whose folder is already on the
/// server are excluded up front rather than uploaded again.
class WebdavMigrationTask {
  WebdavMigrationTask({
    required this.id,
    required this.comics,
    required this.createdAt,
    required this.numericPrefix,
    required this.skipExisting,
    required this.librarySourceKey,
    Set<String>? doneKeys,
    this.skippedKeys,
    List<WebdavMigrationFailure>? failures,
    this.failedCount = 0,
    this.status = WebdavMigrationStatus.running,
    this.currentTitle,
    this.currentComicProgress,
    this.error,
    this.finishedAt,
  }) : doneKeys = doneKeys ?? <String>{},
       failures = failures ?? <WebdavMigrationFailure>[];

  final String id;
  final List<MigrationComicRef> comics;
  final DateTime createdAt;

  /// Chapter-folder naming choice, fixed for the whole task so a resume keeps
  /// the same remote layout it started with.
  final bool numericPrefix;

  /// When true, a comic whose target folder already exists on the server is
  /// left untouched instead of being re-uploaded (issue #160). Fixed for the
  /// whole task so a resume keeps the choice the user made.
  final bool skipExisting;

  /// Source key of the library being uploaded into. Persisted so a resume after
  /// a restart writes to the same server even when several are configured, and
  /// so the folder-already-populated skip is judged against the right one.
  final String librarySourceKey;

  final Set<String> doneKeys;

  /// Comics left untouched because their folder already existed on the server.
  /// Resolved once, on the task's first run, and then frozen: a later run would
  /// also see the folders this task itself created, and re-deciding against that
  /// listing would skip a comic left half-uploaded by a pause. Null until
  /// resolved; always a subset of [doneKeys] once set.
  Set<String>? skippedKeys;

  int get skippedCount => skippedKeys?.length ?? 0;

  final List<WebdavMigrationFailure> failures;
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
    'skipExisting': skipExisting,
    'librarySourceKey': librarySourceKey,
    'doneKeys': doneKeys.toList(),
    'skippedKeys': skippedKeys?.toList(),
    'failures': failures.map((e) => e.toJson()).toList(),
    'failedCount': failedCount,
    // Persist active tasks as paused so they are not auto-run on restart.
    'status': isActive ? WebdavMigrationStatus.paused.name : status.name,
    'error': error,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
  };

  factory WebdavMigrationTask.fromJson(
    Map<String, dynamic> json,
  ) => WebdavMigrationTask(
    id: json['id'] ?? '',
    comics: (json['comics'] as List? ?? [])
        .whereType<Map>()
        .map((e) => MigrationComicRef.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    numericPrefix: json['numericPrefix'] ?? true,
    // A task created before this option existed always uploaded.
    skipExisting: json['skipExisting'] ?? false,
    // A task written before multiple libraries existed targeted the only
    // one there was.
    librarySourceKey: json['librarySourceKey']?.toString().isNotEmpty == true
        ? json['librarySourceKey'].toString()
        : WebdavLibraryStore.legacySourceKey,
    doneKeys: (json['doneKeys'] as List? ?? []).map((e) => '$e').toSet(),
    skippedKeys: json['skippedKeys'] is List
        ? (json['skippedKeys'] as List).map((e) => '$e').toSet()
        : null,
    failures: (json['failures'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (e) => WebdavMigrationFailure.fromJson(Map<String, dynamic>.from(e)),
        )
        .toList(),
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

  /// Starts a background migration of [comics] into the library registered under
  /// [librarySourceKey]. Returns null if a migration is already active — only one
  /// runs at a time since concurrent runs would race on folder creation.
  WebdavMigrationTask? start(
    List<LocalComic> comics, {
    required bool numericPrefix,
    required bool skipExisting,
    required String librarySourceKey,
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
      skipExisting: skipExisting,
      librarySourceKey: librarySourceKey,
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
      // Resolved per run rather than held on the task: the library may have been
      // edited (or deleted) between creating the task and resuming it.
      final library = WebdavLibraryClient.forSourceKey(task.librarySourceKey);
      if (library == null) {
        throw 'WebDAV comic library is not configured';
      }
      final root = library.migrationRoot;
      await library.ensureRemoteDir(root);

      await _resolveSkipped(task, library, root, folderNames);

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
        if (comic == null) {
          // Deleted since the task was created.
          _recordFailures(task, ref.key, [
            WebdavMigrationFailure(
              comicKey: ref.key,
              comicTitle: ref.title,
              reason: WebdavMigrationFailureReason.comicUnavailable,
            ),
          ]);
          task.doneKeys.add(ref.key);
          notifyListeners();
          _persist();
          continue;
        }

        bool completed;
        try {
          final folderName = folderNames[ref.key] ??
              migrationUniqueFolderName(ref.title, <String>{});
          completed = await _migrateOne(
            task,
            library,
            comic,
            root,
            folderName,
          );
        } on _WebdavMigrationException catch (e, s) {
          Log.error('WebDAV Migration', e.toString(), s);
          _recordFailures(task, ref.key, e.failures);
          lastError = e.toString();
          completed = true; // a genuine failure; don't retry this comic
        } catch (e, s) {
          Log.error('WebDAV Migration', e.toString(), s);
          _recordFailures(task, ref.key, [
            WebdavMigrationFailure(
              comicKey: ref.key,
              comicTitle: ref.title,
              reason: WebdavMigrationFailureReason.unknown,
            ),
          ]);
          lastError = e.toString();
          completed = true;
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
          task.error = task.failures.isNotEmpty
              ? 'Migration failed'
              : lastError ?? 'Migration failed';
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

  /// Freezes which comics are left untouched because the target library already
  /// holds a folder of that name (issue #160). Runs only on the task's first
  /// run: see [WebdavMigrationTask.skippedKeys] for why the decision must not be
  /// re-made against a later listing. Skipped comics are marked done so progress
  /// still reaches the end of the list.
  ///
  /// A failed listing propagates: the option is an explicit user instruction, so
  /// uploading the whole batch in spite of it is worse than a retryable failure.
  Future<void> _resolveSkipped(
    WebdavMigrationTask task,
    WebdavLibraryClient library,
    String root,
    Map<String, String> folderNames,
  ) async {
    if (!task.skipExisting || task.skippedKeys != null) return;
    final existing = (await library.remoteFolderNames(root))
        .map((e) => e.toLowerCase())
        .toSet();
    final skipped = <String>{};
    for (final ref in task.comics) {
      final name = folderNames[ref.key];
      if (name != null && existing.contains(name.toLowerCase())) {
        skipped.add(ref.key);
      }
    }
    task.skippedKeys = skipped;
    task.doneKeys.addAll(skipped);
    // Persist before any upload so a kill here cannot leave the decision to a
    // later run, which would judge it against folders this task created.
    _persist();
    notifyListeners();
  }

  /// Uploads one comic's cover + pages into `{root}/{title}/…` in the layout
  /// the WebDAV source reads back. Throws on a fatal per-comic error (the
  /// caller records it and moves on). Returns false if it stopped early because
  /// the task was paused/canceled mid-comic (so the caller must NOT mark the
  /// comic done — a resume re-uploads it cleanly); true on full upload.
  Future<bool> _migrateOne(
    WebdavMigrationTask task,
    WebdavLibraryClient library,
    LocalComic comic,
    String root,
    String folderName,
  ) async {
    final comicDir = '$root$folderName/';
    final plan = await prepareWebdavMigrationUpload(
      comic: comic,
      comicDir: comicDir,
      numericPrefix: task.numericPrefix,
    );
    if (plan.failures.isNotEmpty) {
      throw _WebdavMigrationException(plan.failures);
    }

    // Resume uses deterministic paths and overwrites an interrupted comic.
    try {
      for (final directory in plan.remoteDirectories) {
        await library.ensureRemoteDir(directory);
      }
    } catch (e) {
      throw _WebdavMigrationException([
        WebdavMigrationFailure(
          comicKey: '${comic.id}_${comic.comicType.value}',
          comicTitle: comic.title,
          reason: WebdavMigrationFailureReason.uploadFailed,
        ),
      ], e);
    }

    for (var i = 0; i < plan.uploads.length; i++) {
      // A large comic (many chapters/pages) can take a while, so honour a
      // pause/cancel between individual images rather than only between comics.
      // Signalled to the caller by returning false — the comic stays un-done so
      // a resume re-uploads it from scratch (overwriting the partial folder).
      if (_canceledIds.contains(task.id) || _pausedIds.contains(task.id)) {
        return false;
      }
      final u = plan.uploads[i];
      try {
        await library.uploadFile(u.local, u.remote);
      } catch (e) {
        throw _WebdavMigrationException([
          WebdavMigrationFailure(
            comicKey: '${comic.id}_${comic.comicType.value}',
            comicTitle: comic.title,
            chapterTitle: u.chapterTitle,
            reason: WebdavMigrationFailureReason.uploadFailed,
          ),
        ], e);
      }
      task.currentComicProgress = (i + 1) / plan.uploads.length;
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

  void _recordFailures(
    WebdavMigrationTask task,
    String comicKey,
    List<WebdavMigrationFailure> failures,
  ) {
    task.failedCount++;
    task.failures.removeWhere((failure) => failure.comicKey == comicKey);
    task.failures.addAll(failures);
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

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/hot_update.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/venera_comics.dart';
// ExportPhase is defined in venera_comics.dart (the leaf module) to avoid a
// circular import; re-export it so the pages that already import this file
// for ExportTask see the phase enum too.
export 'package:venera/utils/venera_comics.dart' show ExportPhase;

enum ExportTaskStatus { running, paused, completed, canceled, failed }

/// Output format for a local comic export. Each comic is written as one file
/// of this format directly into the user-chosen folder.
enum ExportFormat {
  cbz('.cbz'),
  pdf('.pdf'),
  epub('.epub'),
  veneraComics('.venera_comics');

  const ExportFormat(this.ext);

  final String ext;

  /// Untranslated label shown on the Tasks page (the UI localizes it).
  String get label => switch (this) {
        ExportFormat.cbz => 'CBZ',
        ExportFormat.pdf => 'PDF',
        ExportFormat.epub => 'EPUB',
        ExportFormat.veneraComics => 'venera_comics',
      };

  static ExportFormat fromName(String name) => ExportFormat.values.firstWhere(
        (e) => e.name == name,
        orElse: () => ExportFormat.cbz,
      );
}

/// Minimal reference to a comic to export, kept small so a task can be
/// persisted and restored (resumed) after the app is closed.
class ExportComicRef {
  ExportComicRef({
    required this.id,
    required this.comicTypeValue,
    required this.title,
  });

  final String id;
  final int comicTypeValue;
  final String title;

  /// Stable per-comic key used to mark a comic as already exported.
  String get key => '${id}_$comicTypeValue';

  ComicType get comicType => ComicType(comicTypeValue);

  Map<String, dynamic> toJson() => {
        'id': id,
        'comicTypeValue': comicTypeValue,
        'title': title,
      };

  factory ExportComicRef.fromJson(Map<String, dynamic> json) => ExportComicRef(
        id: json['id'] ?? '',
        comicTypeValue: json['comicTypeValue'] ?? 0,
        title: json['title'] ?? '',
      );
}

/// A local-comic export, surfaced in the Tasks page so a large export can run
/// in the background with progress (modelled on [ImportTask]).
///
/// Each selected comic is exported as one file into [folderPath]. Progress is
/// per-comic; a comic whose output file already exists in the folder is skipped,
/// which makes the task resumable after pause or app restart (issue #54).
class ExportTask {
  ExportTask({
    required this.id,
    required this.folderPath,
    required this.format,
    required this.comics,
    required this.createdAt,
    Set<String>? doneKeys,
    this.merged = false,
    this.failedCount = 0,
    this.status = ExportTaskStatus.running,
    this.currentTitle,
    this.error,
    this.finishedAt,
    this.phase = ExportPhase.preparing,
    this.writeProgress,
  }) : doneKeys = doneKeys ?? <String>{};

  final String id;
  final String folderPath;
  final ExportFormat format;
  final List<ExportComicRef> comics;
  final DateTime createdAt;

  /// When true (only for the venera_comics format), all comics are written to
  /// a single combined .venera_comics file instead of one file per comic.
  final bool merged;

  /// Keys ([ExportComicRef.key]) of comics already written (or skipped).
  final Set<String> doneKeys;
  int failedCount;
  ExportTaskStatus status;
  String? currentTitle;

  /// Translation key (or raw text) describing the failure when [status] failed.
  String? error;
  DateTime? finishedAt;

  /// Current coarse phase, so the UI can show "packaging"/"writing" instead of
  /// a bar frozen at 100% during those (uninstrumented-by-doneKeys) steps (#92).
  ExportPhase phase;

  /// Byte fraction (0..1) of the current destination-write, or null when not
  /// in the writing phase. Drives a real progress bar for the SAF/folder copy,
  /// which for a large library is the longest step.
  double? writeProgress;

  int get total => comics.length;

  int get done => doneKeys.length;

  bool get isRunning => status == ExportTaskStatus.running;

  bool get isPaused => status == ExportTaskStatus.paused;

  /// Active = not yet in terminal state; such tasks stay in [currentTasks].
  bool get isActive =>
      status == ExportTaskStatus.running || status == ExportTaskStatus.paused;

  double get progress => total == 0 ? 0 : (done / total).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
        'id': id,
        'folderPath': folderPath,
        'format': format.name,
        'comics': comics.map((e) => e.toJson()).toList(),
        'doneKeys': doneKeys.toList(),
        'merged': merged,
        'failedCount': failedCount,
        // Persist active tasks as paused so they are not auto-run on restart.
        'status': isActive ? ExportTaskStatus.paused.name : status.name,
        'error': error,
        'phase': phase.name,
        'createdAt': createdAt.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
      };

  factory ExportTask.fromJson(Map<String, dynamic> json) => ExportTask(
        id: json['id'] ?? '',
        folderPath: json['folderPath'] ?? '',
        format: ExportFormat.fromName(json['format'] ?? 'cbz'),
        comics: (json['comics'] as List? ?? [])
            .whereType<Map>()
            .map((e) => ExportComicRef.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        doneKeys: (json['doneKeys'] as List? ?? []).map((e) => '$e').toSet(),
        merged: json['merged'] ?? false,
        failedCount: json['failedCount'] ?? 0,
        status: ExportTaskStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => ExportTaskStatus.paused,
        ),
        error: json['error'],
        phase: ExportPhase.values.firstWhere(
          (e) => e.name == json['phase'],
          orElse: () => ExportPhase.preparing,
        ),
        createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
        finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      );
}

class ExportTaskManager with ChangeNotifier {
  ExportTaskManager._() {
    _restore();
  }

  static final ExportTaskManager instance = ExportTaskManager._();

  final currentTasks = <ExportTask>[];
  final historyTasks = <ExportTask>[];
  final _canceledIds = <String>{};
  final _pausedIds = <String>{};

  /// Starts a background export of [comics] as [format] into [folderPath].
  ///
  /// Returns null if an export is already active. Only one export runs at a
  /// time: the per-format exporters stage into shared cache directories, so
  /// concurrent exports would corrupt each other (mirrors [ImportTaskManager]).
  ExportTask? startExport({
    required String folderPath,
    required ExportFormat format,
    required List<LocalComic> comics,
    bool merged = false,
  }) {
    if (currentTasks.any((t) => t.isActive)) {
      return null;
    }
    var task = ExportTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      folderPath: folderPath,
      format: format,
      comics: comics
          .map((c) => ExportComicRef(
                id: c.id,
                comicTypeValue: c.comicType.value,
                title: c.title,
              ))
          .toList(),
      createdAt: DateTime.now(),
      merged: merged && format == ExportFormat.veneraComics,
    );
    currentTasks.insert(0, task);
    _persist();
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  /// Returns true if an export task is currently running or paused.
  bool get hasActiveTask => currentTasks.any((t) => t.isActive);

  void cancel(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    if (task.status == ExportTaskStatus.running) {
      // The running loop checks this between comics and finalizes the task.
      _canceledIds.add(id);
      notifyListeners();
    } else {
      // A paused task is not executing [_run]; terminate it directly.
      _pausedIds.remove(id);
      task.status = ExportTaskStatus.canceled;
      task.finishedAt = DateTime.now();
      currentTasks.remove(task);
      historyTasks.insert(0, task);
      if (historyTasks.length > 50) {
        historyTasks.removeRange(50, historyTasks.length);
      }
      _persist();
      notifyListeners();
    }
  }

  void pause(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status != ExportTaskStatus.running) return;
    _pausedIds.add(id);
    notifyListeners();
  }

  /// Resumes a paused task (also used for tasks restored after an app restart).
  void resume(String id) {
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null || task.status == ExportTaskStatus.running) return;
    _pausedIds.remove(id);
    task.status = ExportTaskStatus.running;
    notifyListeners();
    unawaited(_run(task));
  }

  Future<void> _run(ExportTask task) async {
    final cacheDir = Directory(FilePath.join(App.cachePath, 'export_task', task.id));
    _refreshKeepAlive(task);
    // Remember the last per-comic failure so a task where every comic failed can
    // report the real cause instead of masquerading as a success (#130).
    String? lastError;
    // Lazily resolved once per run: a real filesystem directory to fall back to
    // when a SAF write fails (#130). Guarded by a flag so all-files access is
    // requested at most once even if many comics fail to write.
    Directory? fallbackDir;
    var fallbackResolved = false;
    Future<Directory?> resolveFallbackDir() async {
      if (fallbackResolved) return fallbackDir;
      fallbackResolved = true;
      final real = await _mapSafToRealDir(task.folderPath);
      if (real != null && await StoragePermission.ensureGranted(real.path)) {
        fallbackDir = real;
      }
      return fallbackDir;
    }

    try {
      if (!cacheDir.existsSync()) {
        cacheDir.createSync(recursive: true);
      }
      final targetDir = Directory(task.folderPath);
      if (task.merged) {
        await _runMerged(task, targetDir);
      } else {
        // Resolve a unique output file name per comic up front. Two comics with
        // the same title would otherwise map to the same file, and the second
        // would be silently skipped by the resume "already exists" check. The
        // order of [task.comics] is stable and persisted, so this is
        // deterministic across an app restart — resume picks the same names.
        final outNames = <String, String>{};
        final usedNames = <String>{};
        for (final ref in task.comics) {
          final base = sanitizeFileName(ref.title, maxLength: 100);
          var name = '$base${task.format.ext}';
          var n = 2;
          while (usedNames.contains(name)) {
            name = '$base ($n)${task.format.ext}';
            n++;
          }
          usedNames.add(name);
          outNames[ref.key] = name;
        }
        for (final ref in task.comics) {
          if (_canceledIds.contains(task.id)) {
            task.status = ExportTaskStatus.canceled;
            break;
          }
          if (_pausedIds.contains(task.id)) {
            task.status = ExportTaskStatus.paused;
            task.currentTitle = null;
            notifyListeners();
            _persist();
            return; // keep in currentTasks; resumable
          }
          if (task.doneKeys.contains(ref.key)) {
            continue;
          }

          final outName = outNames[ref.key]!;
          final target = targetDir.joinFile(outName);

          // Resume: a comic already written to the folder is skipped.
          if (await target.exists()) {
            task.doneKeys.add(ref.key);
            notifyListeners();
            _persist();
            continue;
          }

          task.currentTitle = ref.title;
          notifyListeners();
          _refreshKeepAlive(task);

          final comic = LocalManager().find(ref.id, ref.comicType);
          if (comic == null) {
            // The comic was deleted since the task was created; skip it.
            task.failedCount++;
            task.doneKeys.add(ref.key);
            notifyListeners();
            _persist();
            continue;
          }

          File? produced;
          try {
            task.phase = ExportPhase.processing;
            task.writeProgress = null;
            notifyListeners();
            produced = await _buildToCache(comic, task.format, cacheDir.path);
            // Stream the built file into the destination instead of loading it
            // whole into memory, so a large comic can't OOM the export (#93).
            // The destination write (SAF on Android) is the slow step, so show
            // real byte progress for it instead of a frozen bar (#92).
            task.phase = ExportPhase.writing;
            task.writeProgress = 0;
            notifyListeners();
            await copyFileStreaming(
              produced,
              target,
              onProgress: _writeProgress(task),
            );
            task.writeProgress = null;
            produced.deleteIgnoreError();
          } catch (e, s) {
            // A SAF write failure (some Android providers reject file creation
            // on shared trees like Download) can often be recovered by writing
            // to the same folder's real filesystem path with all-files access
            // (#130). Retry there once before giving up on this comic.
            var recovered = false;
            if (produced != null && _looksLikeCreateFailure(e.toString())) {
              try {
                final dir = await resolveFallbackDir();
                if (dir != null) {
                  await copyFileStreaming(
                    produced,
                    dir.joinFile(outName),
                    onProgress: _writeProgress(task),
                  );
                  task.writeProgress = null;
                  produced.deleteIgnoreError();
                  recovered = true;
                }
              } catch (e2, s2) {
                Log.error('Export Comics', e2.toString(), s2);
              }
            }
            if (!recovered) {
              Log.error('Export Comics', e.toString(), s);
              task.failedCount++;
              lastError = e.toString();
              produced?.deleteIgnoreError();
            }
          }
          task.doneKeys.add(ref.key);
          notifyListeners();
          _persist();
        }
      }

      if (task.status == ExportTaskStatus.running) {
        // Every comic failing (e.g. the destination folder rejects file
        // creation on some Android SAF providers) previously still finished as
        // "completed", so the UI cheerfully reported success while nothing was
        // written (#130). Surface it as a failure with the real cause instead.
        if (task.failedCount >= task.total && task.total > 0) {
          task.status = ExportTaskStatus.failed;
          // The overwhelmingly common cause of every write failing is the
          // chosen folder refusing file creation (some Android SAF providers,
          // e.g. MIUI's Download tree, return null from createDocument). Give an
          // actionable message instead of a raw FileSystemException string; the
          // real error is still in the log via Log.error above.
          task.error = _looksLikeCreateFailure(lastError)
              ? 'Cannot write to the selected folder, please choose another'
              : (lastError ?? 'Export failed');
        } else {
          task.status = ExportTaskStatus.completed;
        }
      }
    } catch (e, s) {
      task.status = ExportTaskStatus.failed;
      // Same actionable message for the folder-rejects-creation case, which in
      // merged mode surfaces here rather than the per-comic loop above (#130).
      task.error = _looksLikeCreateFailure(e.toString())
          ? 'Cannot write to the selected folder, please choose another'
          : e.toString();
      Log.error('Export Comics', e.toString(), s);
    } finally {
      cacheDir.deleteIgnoreError(recursive: true);
      // Clear the transient write fraction regardless of outcome so a
      // finished/paused card never lingers on a stale writing percentage.
      task.writeProgress = null;
      if (task.status != ExportTaskStatus.paused) {
        task.currentTitle = null;
        task.finishedAt = DateTime.now();
        _canceledIds.remove(task.id);
        _pausedIds.remove(task.id);
        currentTasks.remove(task);
        historyTasks.insert(0, task);
        if (historyTasks.length > 50) {
          historyTasks.removeRange(50, historyTasks.length);
        }
      }
      // Drop the keep-alive notification once no export is actively running
      // (a paused/restored task is not running, so it shouldn't keep it up).
      if (currentTasks.where((t) => t.isRunning).isEmpty) {
        BackgroundKeepAlive.instance.remove(BackgroundKeepAlive.tagExport);
      }
      _persist();
      notifyListeners();
    }
  }

  /// Byte-progress callback for the destination write. Updates the task's
  /// [ExportTask.writeProgress] but only notifies listeners when the integer
  /// percentage changes, so a multi-GB write drives at most ~100 UI rebuilds
  /// instead of one per 8 MiB chunk.
  void Function(int, int) _writeProgress(ExportTask task) {
    var lastPercent = -1;
    return (copied, totalBytes) {
      final frac = totalBytes == 0 ? null : copied / totalBytes;
      task.writeProgress = frac;
      final percent = frac == null ? -1 : (frac * 100).floor();
      if (percent != lastPercent) {
        lastPercent = percent;
        notifyListeners();
      }
    };
  }

  /// True when the failure looks like the destination folder rejecting file
  /// creation (as opposed to a per-comic build error). Some Android SAF
  /// providers return null from createDocument for certain trees, which
  /// flutter_saf surfaces as "Cannot create file specified" (#130).
  bool _looksLikeCreateFailure(String? error) => patched(
    SeamIds.exportCreateFailure,
    [error],
    () => _looksLikeCreateFailureOrig(error),
  );

  bool _looksLikeCreateFailureOrig(String? error) {
    if (error == null) return false;
    return error.contains('Cannot create file');
  }

  /// Maps a SAF folder path (`android://primary:Download`) to the equivalent
  /// real filesystem directory (`/storage/emulated/0/Download`) so a failed SAF
  /// write can be retried with all-files access (#130).
  ///
  /// Only the primary shared volume can be mapped reliably: its root is derived
  /// from [App.externalStoragePath] (`…/Android/data/<pkg>/files`, whose prefix
  /// before `/Android/` is the volume root). Secondary volumes (SD cards, whose
  /// tree id is a UUID) have no dependable real path, so those return null and
  /// the caller keeps the "choose another folder" behaviour.
  Future<Directory?> _mapSafToRealDir(String folderPath) async {
    const prefix = 'android://';
    if (!App.isAndroid || !folderPath.startsWith(prefix)) return null;
    final treeId = folderPath.substring(prefix.length);
    final colon = treeId.indexOf(':');
    if (colon < 0) return null;
    final volume = treeId.substring(0, colon);
    if (volume != 'primary') return null;
    // Relative path within the volume, e.g. "Download" or "Comics/Export".
    final relative = treeId.substring(colon + 1);
    final ext = App.externalStoragePath;
    if (ext == null) return null;
    final marker = ext.indexOf('/Android/');
    final root = marker > 0 ? ext.substring(0, marker) : ext;
    final dir = Directory(
      relative.isEmpty ? root : FilePath.join(root, relative),
    );
    return dir;
  }

  void _refreshKeepAlive(ExportTask task) {
    BackgroundKeepAlive.instance.update(
      BackgroundKeepAlive.tagExport,
      formatTaskStatus(
        title: task.currentTitle ?? task.format.label,
        detail: task.total == 0 ? null : '${task.done}/${task.total}',
      ),
    );
  }

  /// Builds a single combined .venera_comics containing all comics (merge
  /// mode). A combined archive cannot resume mid-build, so this is
  /// all-or-nothing: if the output file already exists it is treated as done,
  /// otherwise the whole bundle is rebuilt.
  Future<void> _runMerged(ExportTask task, Directory targetDir) async {
    final allKeys = task.comics.map((c) => c.key).toList();
    if (_canceledIds.contains(task.id)) {
      task.status = ExportTaskStatus.canceled;
      return;
    }
    final target = targetDir.joinFile(_mergedFileName(task.createdAt));
    if (await target.exists()) {
      task.doneKeys
        ..clear()
        ..addAll(allKeys);
      return;
    }
    task.doneKeys.clear();
    notifyListeners();
    _persist();
    final comics = <LocalComic>[];
    for (final ref in task.comics) {
      final c = LocalManager().find(ref.id, ref.comicType);
      if (c != null) comics.add(c);
    }
    if (comics.isEmpty) {
      task.failedCount = task.comics.length;
      return;
    }
    final produced = await exportVeneraComics(
      comics,
      onProgress: (current, total) {
        // Reuse doneKeys to drive the progress bar during the build.
        task.doneKeys
          ..clear()
          ..addAll(
            comics.take(current).map((c) => '${c.id}_${c.comicType.value}'),
          );
        task.currentTitle =
            (current > 0 && current <= comics.length) ? comics[current - 1].title : null;
        notifyListeners();
        _refreshKeepAlive(task);
      },
      onPhase: (phase, detail) {
        task.phase = phase;
        if (detail != null) task.currentTitle = detail;
        notifyListeners();
        _refreshKeepAlive(task);
      },
    );
    // The merged archive can reach tens of gigabytes; stream it into the
    // destination chunk by chunk instead of reading it fully into memory,
    // which previously crashed with Out of Memory on large libraries (#93).
    // Byte progress for this (slow) destination write (#92).
    task.phase = ExportPhase.writing;
    task.writeProgress = 0;
    notifyListeners();
    _refreshKeepAlive(task);
    // Track the file actually written, which may be the fallback path rather
    // than [target]; a cancellation cleanup below must delete the right one.
    var written = target;
    try {
      await copyFileStreaming(
        produced,
        target,
        onProgress: _writeProgress(task),
      );
    } catch (e, s) {
      // The SAF destination refused the write (#130). Fall back to a real
      // filesystem path under all-files access, if the chosen folder maps to
      // one, before giving up on the whole (rebuilt-from-scratch) bundle.
      if (!_looksLikeCreateFailure(e.toString())) rethrow;
      final fallbackDir = await _mapSafToRealDir(task.folderPath);
      if (fallbackDir == null ||
          !await StoragePermission.ensureGranted(fallbackDir.path)) {
        rethrow;
      }
      Log.error('Export Comics', 'SAF write failed, retrying on '
          '${fallbackDir.path}: $e', s);
      written = fallbackDir.joinFile(_mergedFileName(task.createdAt));
      task.writeProgress = 0;
      notifyListeners();
      await copyFileStreaming(
        produced,
        written,
        onProgress: _writeProgress(task),
      );
    }
    task.writeProgress = null;
    produced.deleteIgnoreError();
    if (_canceledIds.contains(task.id)) {
      // Cancellation requested during the (uninterruptible) build: drop the
      // just-written bundle so a canceled export leaves nothing behind.
      written.deleteIgnoreError();
      task.status = ExportTaskStatus.canceled;
      return;
    }
    task.doneKeys
      ..clear()
      ..addAll(allKeys);
    notifyListeners();
    _persist();
  }

  String _mergedFileName(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'venera_comics_${t.year}${two(t.month)}${two(t.day)}'
        '_${two(t.hour)}${two(t.minute)}${two(t.second)}.venera_comics';
  }

  /// Builds one comic into [cacheDir] using the existing per-format exporters
  /// (which already run their heavy work off the UI thread / in isolates) and
  /// returns the produced file. The caller copies it into the target folder.
  Future<File> _buildToCache(
    LocalComic comic,
    ExportFormat format,
    String cacheDir,
  ) async {
    final outName = sanitizeFileName(comic.title, maxLength: 100) + format.ext;
    final outPath = FilePath.join(cacheDir, outName);
    switch (format) {
      case ExportFormat.cbz:
        return CBZ.export(comic, outPath);
      case ExportFormat.pdf:
        return createPdfFromComicIsolate(comic, outPath);
      case ExportFormat.epub:
        return createEpubWithLocalComic(comic, outPath);
      case ExportFormat.veneraComics:
        // Produces its own cache file; the caller copies it to [outName].
        return exportVeneraComics([comic]);
    }
  }

  void _persist() {
    appdata.implicitData['export_task_current'] =
        currentTasks.map((t) => t.toJson()).toList();
    appdata.implicitData['export_task_history'] =
        historyTasks.map((t) => t.toJson()).toList();
    appdata.writeImplicitData();
  }

  void _restore() {
    var current = appdata.implicitData['export_task_current'];
    if (current is List) {
      currentTasks
        ..clear()
        ..addAll(current.whereType<Map>().map(
              (e) => ExportTask.fromJson(Map<String, dynamic>.from(e)),
            ));
    }
    var history = appdata.implicitData['export_task_history'];
    if (history is List) {
      historyTasks
        ..clear()
        ..addAll(history.whereType<Map>().map(
              (e) => ExportTask.fromJson(Map<String, dynamic>.from(e)),
            ));
    }
  }

  /// Clear all history tasks
  void clearHistory() {
    historyTasks.clear();
    _persist();
    notifyListeners();
  }

  /// Remove a single history task
  void removeTask(String id) {
    historyTasks.removeWhere((t) => t.id == id);
    _persist();
    notifyListeners();
  }
}

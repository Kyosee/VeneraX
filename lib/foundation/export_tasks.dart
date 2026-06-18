import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/venera_comics.dart';

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
    this.failedCount = 0,
    this.status = ExportTaskStatus.running,
    this.currentTitle,
    this.error,
    this.finishedAt,
  }) : doneKeys = doneKeys ?? <String>{};

  final String id;
  final String folderPath;
  final ExportFormat format;
  final List<ExportComicRef> comics;
  final DateTime createdAt;

  /// Keys ([ExportComicRef.key]) of comics already written (or skipped).
  final Set<String> doneKeys;
  int failedCount;
  ExportTaskStatus status;
  String? currentTitle;

  /// Translation key (or raw text) describing the failure when [status] failed.
  String? error;
  DateTime? finishedAt;

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
        'failedCount': failedCount,
        // Persist active tasks as paused so they are not auto-run on restart.
        'status': isActive ? ExportTaskStatus.paused.name : status.name,
        'error': error,
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
        failedCount: json['failedCount'] ?? 0,
        status: ExportTaskStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => ExportTaskStatus.paused,
        ),
        error: json['error'],
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
    try {
      if (!cacheDir.existsSync()) {
        cacheDir.createSync(recursive: true);
      }
      final targetDir = Directory(task.folderPath);
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

        final comic = LocalManager().find(ref.id, ref.comicType);
        if (comic == null) {
          // The comic was deleted since the task was created; skip it.
          task.failedCount++;
          task.doneKeys.add(ref.key);
          notifyListeners();
          _persist();
          continue;
        }

        try {
          final produced = await _buildToCache(comic, task.format, cacheDir.path);
          await target.writeAsBytes(await produced.readAsBytes());
          produced.deleteIgnoreError();
        } catch (e, s) {
          Log.error('Export Comics', e.toString(), s);
          task.failedCount++;
        }
        task.doneKeys.add(ref.key);
        notifyListeners();
        _persist();
      }

      if (task.status == ExportTaskStatus.running) {
        task.status = ExportTaskStatus.completed;
      }
    } catch (e, s) {
      task.status = ExportTaskStatus.failed;
      task.error = e.toString();
      Log.error('Export Comics', e.toString(), s);
    } finally {
      cacheDir.deleteIgnoreError(recursive: true);
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
      _persist();
      notifyListeners();
    }
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
}

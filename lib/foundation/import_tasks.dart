import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

export 'package:venera/utils/data.dart' show ImportPhase;

enum ImportTaskStatus { running, completed, canceled, failed }

/// Untranslated English label key for a phase (the UI localizes it with `.tl`).
String importPhaseLabelKey(ImportPhase phase) => switch (phase) {
  ImportPhase.preparing => 'Preparing',
  ImportPhase.extracting => 'Extracting',
  ImportPhase.applying => 'Applying',
  ImportPhase.reloading => 'Reloading sources',
};

/// A single local-backup import, surfaced in the Tasks page so a large import
/// can run in the background with progress (modelled on [FollowUpdateTask]).
class ImportTask {
  ImportTask({
    required this.id,
    required this.fileName,
    required this.filePath,
    required this.isPica,
    required this.createdAt,
    this.fileSize = 0,
    this.status = ImportTaskStatus.running,
    this.phase = ImportPhase.preparing,
    this.message,
    this.extractedBytes = 0,
    this.error,
    this.finishedAt,
  });

  final String id;
  final String fileName;
  final String filePath;
  final bool isPica;
  final DateTime createdAt;
  int fileSize;
  ImportTaskStatus status;
  ImportPhase phase;

  /// Untranslated English key for the current applying step (UI localizes it).
  String? message;
  int extractedBytes;

  /// Translation key (or raw text) describing the failure, when [status] is failed.
  String? error;
  DateTime? finishedAt;

  /// The file was a translation export, so only translations were merged.
  bool translationsOnly = false;
  int translatedPages = 0;

  bool get isRunning => status == ImportTaskStatus.running;

  /// Value for a loading-dialog progress bar; null => indeterminate. The
  /// extracting phase is indeterminate because zip_flutter cannot report a
  /// precise extraction percentage.
  double? get indicatorValue {
    if (!isRunning) return 1.0;
    switch (phase) {
      case ImportPhase.preparing:
        return 0.02;
      case ImportPhase.extracting:
        return null;
      case ImportPhase.applying:
        return 0.7;
      case ImportPhase.reloading:
        return 0.95;
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'isPica': isPica,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'fileSize': fileSize,
    'status': status.name,
    'phase': phase.name,
    'error': error,
  };

  factory ImportTask.fromJson(Map<String, dynamic> json) {
    return ImportTask(
      id: json['id'] ?? '',
      fileName: json['fileName'] ?? '',
      filePath: '',
      isPica: json['isPica'] ?? false,
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      fileSize: json['fileSize'] ?? 0,
      status: ImportTaskStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => ImportTaskStatus.completed,
      ),
      phase: ImportPhase.values.firstWhere(
        (e) => e.name == json['phase'],
        orElse: () => ImportPhase.reloading,
      ),
      error: json['error'],
    );
  }
}

class ImportTaskManager with ChangeNotifier {
  ImportTaskManager._() {
    _loadHistory();
  }

  static final ImportTaskManager instance = ImportTaskManager._();

  final currentTasks = <ImportTask>[];
  final historyTasks = <ImportTask>[];
  final _canceledIds = <String>{};
  void Function(ImportTask task)? onTaskFinished;

  /// Starts a background import. Returns null if an import is already running
  /// (only one at a time, since it replaces live databases).
  ImportTask? startImport({
    required String filePath,
    required String fileName,
    bool isPica = false,
  }) {
    if (currentTasks.any((t) => t.isRunning)) {
      return null;
    }
    var task = ImportTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fileName: fileName,
      filePath: filePath,
      isPica: isPica,
      createdAt: DateTime.now(),
      fileSize: _safeFileSize(filePath),
    );
    currentTasks.insert(0, task);
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  void cancel(String id) {
    _canceledIds.add(id);
    notifyListeners();
  }

  /// Cancellation only makes sense before the (uninterruptible) apply phase;
  /// once databases are being replaced, killing the work would corrupt data.
  bool isCancelable(ImportTask task) =>
      task.isRunning &&
      (task.phase == ImportPhase.preparing ||
          task.phase == ImportPhase.extracting);

  Future<void> _run(ImportTask task) async {
    void onProgress(ImportPhase phase, String? message, int? bytes) {
      task.phase = phase;
      if (message != null) task.message = message;
      if (bytes != null) task.extractedBytes = bytes;
      notifyListeners();
      BackgroundKeepAlive.instance.update(
        BackgroundKeepAlive.tagImport,
        formatTaskStatus(
          title: task.fileName.isEmpty ? 'Import'.tl : task.fileName,
          detail: importPhaseLabelKey(phase).tl,
        ),
      );
    }

    bool shouldCancel() => _canceledIds.contains(task.id);

    BackgroundKeepAlive.instance.update(
      BackgroundKeepAlive.tagImport,
      formatTaskStatus(
        title: task.fileName.isEmpty ? 'Import'.tl : task.fileName,
        detail: importPhaseLabelKey(task.phase).tl,
      ),
    );

    try {
      if (task.isPica) {
        await importPicaData(
          File(task.filePath),
          onProgress: onProgress,
          shouldCancel: shouldCancel,
        );
      } else {
        // applyBackup: the manager re-inits inside importAppData fire the
        // very listeners that schedule auto uploads; without suppression the
        // imported data would be echoed to WebDAV once by them AND once by
        // the explicit force upload below. Suppression keeps the publish
        // single and intentional.
        var outcome = await DataSync().applyBackup(
          () => importAppData(
            File(task.filePath),
            onProgress: onProgress,
            shouldCancel: shouldCancel,
            userRestore: true,
          ),
        );
        task.translationsOnly = outcome.translationsOnly;
        task.translatedPages = outcome.translatedPages;
      }
      // Cancellation during extraction throws ImportCanceledException (handled
      // below). Returning normally means the data was applied, so even a late
      // cancel during the uninterruptible apply phase still counts as completed.
      task.status = ImportTaskStatus.completed;
    } on ImportCanceledException {
      task.status = ImportTaskStatus.canceled;
    } catch (e, s) {
      task.status = ImportTaskStatus.failed;
      task.error = e is ImportException
          ? e.messageKey
          : (importErrorMessageKey(e) ?? e.toString());
      Log.error('Import Data', e.toString(), s);
    } finally {
      task.finishedAt = DateTime.now();
      _canceledIds.remove(task.id);
      currentTasks.remove(task);
      historyTasks.insert(0, task);
      if (historyTasks.length > 50) {
        historyTasks.removeRange(50, historyTasks.length);
      }
      _saveHistory();
      BackgroundKeepAlive.instance.remove(BackgroundKeepAlive.tagImport);
      // Notify first so a bound loading dialog closes before we rebuild the app.
      notifyListeners();
      if (task.status != ImportTaskStatus.canceled) {
        // Auto-apply: rebuild the UI to reflect imported data. Mirrors the old
        // settings flow and runs even when the task was sent to the background.
        App.forceRebuild();
      }
      if (task.status == ImportTaskStatus.completed && task.translationsOnly) {
        // Only translations were merged; the rest of this device's data is
        // not a restore and must not be forced over newer remote data.
        DataSync().onTranslationsChanged();
      } else if (task.status == ImportTaskStatus.completed && !task.isPica) {
        // A manual import is an explicit "make this the source of truth", so
        // push it back up to WebDAV, winning even if this device trails the
        // server — force past the #86 fall-behind guard (no-op when sync is
        // disabled).
        unawaited(DataSync().uploadData(force: true));
      }
      onTaskFinished?.call(task);
    }
  }

  int _safeFileSize(String path) {
    try {
      return File(path).lengthSync();
    } catch (_) {
      return 0;
    }
  }

  void _loadHistory() {
    var data = appdata.implicitData['import_task_history'];
    if (data is! List) return;
    historyTasks
      ..clear()
      ..addAll(
        data.whereType<Map>().map(
          (e) => ImportTask.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
  }

  void _saveHistory() {
    appdata.implicitData['import_task_history'] = historyTasks
        .map((task) => task.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  /// Clear all history tasks
  void clearHistory() {
    historyTasks.clear();
    _saveHistory();
    notifyListeners();
  }

  /// Remove a single history task
  void removeTask(String id) {
    historyTasks.removeWhere((t) => t.id == id);
    _saveHistory();
    notifyListeners();
  }
}

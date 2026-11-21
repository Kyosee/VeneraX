import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';

enum HistoryRefreshTaskStatus { running, completed, canceled, failed }

class HistoryRefreshSourceProgress {
  HistoryRefreshSourceProgress({
    required this.sourceKey,
    required this.sourceName,
    this.total = 0,
    this.checked = 0,
    this.success = 0,
    this.failed = 0,
    this.skipped = 0,
    List<String>? errors,
  }) : errors = errors ?? <String>[];

  final String sourceKey;
  final String sourceName;
  int total;
  int checked;
  int success;
  int failed;
  int skipped;
  final List<String> errors;

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'sourceName': sourceName,
    'total': total,
    'checked': checked,
    'success': success,
    'failed': failed,
    'skipped': skipped,
    'errors': errors,
  };

  factory HistoryRefreshSourceProgress.fromJson(Map<String, dynamic> json) {
    return HistoryRefreshSourceProgress(
      sourceKey: json['sourceKey'] ?? '',
      sourceName: json['sourceName'] ?? '',
      total: json['total'] ?? 0,
      checked: json['checked'] ?? 0,
      success: json['success'] ?? 0,
      failed: json['failed'] ?? 0,
      skipped: json['skipped'] ?? 0,
      errors: (json['errors'] as List?)?.whereType<String>().toList(),
    );
  }
}

class HistoryRefreshTask {
  HistoryRefreshTask({
    required this.id,
    required this.createdAt,
    required this.sources,
    this.favoriteFolder,
    this.status = HistoryRefreshTaskStatus.running,
    this.total = 0,
    this.checked = 0,
    this.success = 0,
    this.failed = 0,
    this.skipped = 0,
    List<String>? errors,
    this.finishedAt,
  }) : errors = errors ?? <String>[];

  final String id;
  final DateTime createdAt;
  final Map<String, HistoryRefreshSourceProgress> sources;
  final String? favoriteFolder;
  HistoryRefreshTaskStatus status;
  int total;
  int checked;
  int success;
  int failed;
  int skipped;
  final List<String> errors;
  DateTime? finishedAt;

  bool get isRunning => status == HistoryRefreshTaskStatus.running;

  double get progress {
    if (total > 0) return checked / total;
    return status == HistoryRefreshTaskStatus.completed ? 1 : 0;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'total': total,
    'checked': checked,
    'success': success,
    'failed': failed,
    'skipped': skipped,
    'errors': errors,
    'sources': sources.map((key, value) => MapEntry(key, value.toJson())),
    if (favoriteFolder != null) 'favoriteFolder': favoriteFolder,
  };

  factory HistoryRefreshTask.fromJson(Map<String, dynamic> json) {
    var sourceData = Map<String, dynamic>.from(json['sources'] ?? {});
    return HistoryRefreshTask(
      id: json['id'] ?? '',
      favoriteFolder: json['favoriteFolder'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      status: HistoryRefreshTaskStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => HistoryRefreshTaskStatus.completed,
      ),
      total: json['total'] ?? 0,
      checked: json['checked'] ?? 0,
      success: json['success'] ?? 0,
      failed: json['failed'] ?? 0,
      skipped: json['skipped'] ?? 0,
      errors: (json['errors'] as List?)?.whereType<String>().toList(),
      sources: sourceData.map(
        (key, value) => MapEntry(
          key,
          HistoryRefreshSourceProgress.fromJson(
            Map<String, dynamic>.from(value),
          ),
        ),
      ),
    );
  }
}

class HistoryRefreshTaskManager with ChangeNotifier {
  HistoryRefreshTaskManager._() {
    _loadHistory();
  }

  static final HistoryRefreshTaskManager instance =
      HistoryRefreshTaskManager._();

  final currentTasks = <HistoryRefreshTask>[];
  final historyTasks = <HistoryRefreshTask>[];
  final _canceledIds = <String>{};

  HistoryRefreshTask? startRefreshAll() {
    var existing = currentTasks
        .where((task) => task.isRunning && task.favoriteFolder == null)
        .firstOrNull;
    if (existing != null) {
      return existing;
    }

    var task = HistoryRefreshTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      sources: _buildInitialSources(),
    );
    task.total = task.sources.values.fold(
      0,
      (sum, source) => sum + source.total,
    );
    currentTasks.insert(0, task);
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  HistoryRefreshTask startFavoriteFolder(String folder) {
    final existing = currentTasks
        .where((task) => task.favoriteFolder == folder)
        .firstOrNull;
    if (existing != null) return existing;

    final now = DateTime.now();
    final task = HistoryRefreshTask(
      id: 'favorites:${now.microsecondsSinceEpoch}:$folder',
      createdAt: now,
      favoriteFolder: folder,
      sources: {},
    );
    currentTasks.insert(0, task);
    notifyListeners();
    unawaited(_runFavorites(task, folder));
    return task;
  }

  void cancel(String id) {
    final task = currentTasks.where((task) => task.id == id).firstOrNull;
    if (task == null) return;
    if (task.favoriteFolder == null) {
      _canceledIds.add(id);
      notifyListeners();
    } else {
      task.status = HistoryRefreshTaskStatus.canceled;
      _finish(task);
    }
  }

  Future<void> _runFavorites(HistoryRefreshTask task, String folder) async {
    final favorites = LocalFavoritesManager();
    try {
      final comics = await favorites.getFolderComicsAsync(folder);
      if (!task.isRunning) return;
      task.total = comics.length;
      final sourcesByType = <int, HistoryRefreshSourceProgress>{};
      for (final comic in comics) {
        final source = sourcesByType.putIfAbsent(comic.type.value, () {
          final key = comic.sourceKey;
          return task.sources[key] ??= HistoryRefreshSourceProgress(
            sourceKey: key,
            sourceName:
                comic.type.comicSource?.name ?? (key == 'local' ? 'Local' : key),
          );
        });
        source.total++;
      }
      notifyListeners();

      const batchSize = 4;
      for (var i = 0; i < comics.length && task.isRunning; i += batchSize) {
        await Future.wait(
          comics.skip(i).take(batchSize).map(
            (comic) => _refreshFavorite(
              task,
              folder,
              comic,
              sourcesByType[comic.type.value]!,
            ),
          ),
        );
      }
      if (!task.isRunning) return;
      task.status = task.success == 0 && task.failed > 0
          ? HistoryRefreshTaskStatus.failed
          : HistoryRefreshTaskStatus.completed;
    } catch (error) {
      if (!task.isRunning) return;
      task.errors.add(error.toString());
      task.status = HistoryRefreshTaskStatus.failed;
    } finally {
      if (task.finishedAt == null) _finish(task);
    }
  }

  Future<void> _refreshFavorite(
    HistoryRefreshTask task,
    String folder,
    FavoriteItem comic,
    HistoryRefreshSourceProgress source,
  ) async {
    if (!task.isRunning) return;
    try {
      final updated = await LocalFavoritesManager().refreshComicInfo(
        folder,
        comic,
        isCanceled: () => !task.isRunning,
      );
      if (!task.isRunning) return;
      if (updated) {
        task.success++;
        source.success++;
      } else {
        task.skipped++;
        source.skipped++;
      }
    } catch (error) {
      if (!task.isRunning) return;
      task.failed++;
      source.failed++;
      final message = '${comic.name}: $error';
      source.errors.add(message);
      task.errors.add('${source.sourceName} / $message');
    }
    task.checked++;
    source.checked++;
    notifyListeners();
  }

  Future<void> _run(HistoryRefreshTask task) async {
    var lastSuccess = 0;
    var lastFailed = 0;
    try {
      await for (var progress in HistoryManager().refreshAllHistoriesStream(
        shouldCancel: () => _canceledIds.contains(task.id),
      )) {
        if (_canceledIds.contains(task.id)) {
          task.status = HistoryRefreshTaskStatus.canceled;
          break;
        }
        task.total = progress.total;
        task.checked = progress.current;
        task.success = progress.success;
        task.failed = progress.failed;
        task.skipped = progress.skipped;
        var history = progress.history;
        if (history != null) {
          var source = task.sources.putIfAbsent(
            history.sourceKey,
            () => HistoryRefreshSourceProgress(
              sourceKey: history.sourceKey,
              sourceName: _sourceName(history),
            ),
          );
          source.checked++;
          if (progress.success > lastSuccess) {
            source.success++;
          }
          if (progress.failed > lastFailed) {
            source.failed++;
            var errorMessage = progress.errorMessage;
            if (errorMessage != null && errorMessage.isNotEmpty) {
              var title = history.title.isEmpty ? history.id : history.title;
              var detail = '$title: $errorMessage';
              source.errors.add(detail);
              task.errors.add('${source.sourceName} / $detail');
            }
          }
        }
        lastSuccess = progress.success;
        lastFailed = progress.failed;
        notifyListeners();
      }
      if (task.status == HistoryRefreshTaskStatus.running) {
        task.status = HistoryRefreshTaskStatus.completed;
      }
    } catch (_) {
      task.status = HistoryRefreshTaskStatus.failed;
    } finally {
      _finish(task);
    }
  }

  void _finish(HistoryRefreshTask task) {
    task.finishedAt = DateTime.now();
    _canceledIds.remove(task.id);
    currentTasks.remove(task);
    historyTasks.insert(0, task);
    if (historyTasks.length > 50) {
      historyTasks.removeRange(50, historyTasks.length);
    }
    _saveHistory();
    notifyListeners();
  }

  Map<String, HistoryRefreshSourceProgress> _buildInitialSources() {
    var result = <String, HistoryRefreshSourceProgress>{};
    for (var history in HistoryManager().getAll()) {
      var source = result.putIfAbsent(
        history.sourceKey,
        () => HistoryRefreshSourceProgress(
          sourceKey: history.sourceKey,
          sourceName: _sourceName(history),
        ),
      );
      if (history.sourceKey == 'local') {
        source.skipped++;
      } else {
        source.total++;
      }
    }
    return result;
  }

  static String _sourceName(History history) {
    if (history.sourceKey == 'local') {
      return 'Local';
    }
    if (history.sourceKey.startsWith('Unknown:')) {
      return history.sourceKey;
    }
    return history.type.comicSource?.name ?? history.sourceKey;
  }

  void _loadHistory() {
    var data = appdata.implicitData['history_refresh_task_history'];
    if (data is! List) {
      return;
    }
    historyTasks
      ..clear()
      ..addAll(
        data.whereType<Map>().map(
          (e) => HistoryRefreshTask.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
  }

  void _saveHistory() {
    appdata.implicitData['history_refresh_task_history'] = historyTasks
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

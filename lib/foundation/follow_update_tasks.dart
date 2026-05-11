import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';

enum FollowUpdateTaskStatus { running, completed, canceled, failed }

class FollowUpdateSourceProgress {
  FollowUpdateSourceProgress({
    required this.sourceKey,
    required this.sourceName,
    required this.total,
    this.checked = 0,
    this.updated = 0,
    this.failed = 0,
  });

  final String sourceKey;
  final String sourceName;
  int total;
  int checked;
  int updated;
  int failed;

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'sourceName': sourceName,
    'total': total,
    'checked': checked,
    'updated': updated,
    'failed': failed,
  };

  factory FollowUpdateSourceProgress.fromJson(Map<String, dynamic> json) {
    return FollowUpdateSourceProgress(
      sourceKey: json['sourceKey'] ?? '',
      sourceName: json['sourceName'] ?? '',
      total: json['total'] ?? 0,
      checked: json['checked'] ?? 0,
      updated: json['updated'] ?? 0,
      failed: json['failed'] ?? 0,
    );
  }
}

class FollowUpdateTask {
  FollowUpdateTask({
    required this.id,
    required this.folder,
    required this.manual,
    required this.createdAt,
    required this.sources,
    this.status = FollowUpdateTaskStatus.running,
    this.total = 0,
    this.checked = 0,
    this.updated = 0,
    this.failed = 0,
    this.finishedAt,
  });

  final String id;
  final String folder;
  final bool manual;
  final DateTime createdAt;
  final Map<String, FollowUpdateSourceProgress> sources;
  FollowUpdateTaskStatus status;
  int total;
  int checked;
  int updated;
  int failed;
  DateTime? finishedAt;

  bool get isRunning => status == FollowUpdateTaskStatus.running;

  double get progress => total == 0 ? 0 : checked / total;

  Map<String, dynamic> toJson() => {
    'id': id,
    'folder': folder,
    'manual': manual,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'total': total,
    'checked': checked,
    'updated': updated,
    'failed': failed,
    'sources': sources.map((key, value) => MapEntry(key, value.toJson())),
  };

  factory FollowUpdateTask.fromJson(Map<String, dynamic> json) {
    var sourceData = Map<String, dynamic>.from(json['sources'] ?? {});
    return FollowUpdateTask(
      id: json['id'] ?? '',
      folder: json['folder'] ?? '',
      manual: json['manual'] ?? false,
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      status: FollowUpdateTaskStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => FollowUpdateTaskStatus.completed,
      ),
      total: json['total'] ?? 0,
      checked: json['checked'] ?? 0,
      updated: json['updated'] ?? 0,
      failed: json['failed'] ?? 0,
      sources: sourceData.map(
        (key, value) => MapEntry(
          key,
          FollowUpdateSourceProgress.fromJson(Map<String, dynamic>.from(value)),
        ),
      ),
    );
  }
}

class FollowUpdateTaskManager with ChangeNotifier {
  FollowUpdateTaskManager._() {
    _loadHistory();
  }

  static final FollowUpdateTaskManager instance = FollowUpdateTaskManager._();

  final currentTasks = <FollowUpdateTask>[];
  final historyTasks = <FollowUpdateTask>[];
  final _canceledIds = <String>{};
  void Function(FollowUpdateTask task)? onTaskFinished;

  FollowUpdateTask? startCheck(String folder, {required bool manual}) {
    var existing = currentTasks
        .where((task) => task.folder == folder && task.isRunning)
        .firstOrNull;
    if (existing != null) {
      return existing;
    }

    var task = FollowUpdateTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      folder: folder,
      manual: manual,
      createdAt: DateTime.now(),
      sources: _buildInitialSources(folder, ignoreCheckTime: manual),
    );
    task.total = task.sources.values.fold(
      0,
      (sum, source) => sum + source.total,
    );
    currentTasks.insert(0, task);
    notifyListeners();
    unawaited(_run(task, ignoreCheckTime: manual));
    return task;
  }

  void cancel(String id) {
    _canceledIds.add(id);
    notifyListeners();
  }

  Future<void> _run(
    FollowUpdateTask task, {
    required bool ignoreCheckTime,
  }) async {
    var lastUpdated = 0;
    try {
      await for (var progress in updateFolder(
        task.folder,
        ignoreCheckTime,
        shouldCancel: () => _canceledIds.contains(task.id),
      )) {
        if (_canceledIds.contains(task.id)) {
          task.status = FollowUpdateTaskStatus.canceled;
          break;
        }
        task.total = progress.total;
        task.checked = progress.current;
        task.updated = progress.updated;
        task.failed = progress.errors;
        var comic = progress.comic;
        if (comic != null) {
          var source = task.sources.putIfAbsent(
            comic.sourceKey,
            () => FollowUpdateSourceProgress(
              sourceKey: comic.sourceKey,
              sourceName: _sourceName(comic),
              total: 0,
            ),
          );
          source.checked++;
          if (progress.updated > lastUpdated) {
            source.updated++;
          }
          if (progress.errorMessage != null) {
            source.failed++;
          }
        }
        lastUpdated = progress.updated;
        notifyListeners();
      }
      if (task.status == FollowUpdateTaskStatus.running) {
        task.status = FollowUpdateTaskStatus.completed;
      }
    } catch (_) {
      task.status = FollowUpdateTaskStatus.failed;
    } finally {
      task.finishedAt = DateTime.now();
      _canceledIds.remove(task.id);
      currentTasks.remove(task);
      historyTasks.insert(0, task);
      if (historyTasks.length > 50) {
        historyTasks.removeRange(50, historyTasks.length);
      }
      _saveHistory();
      onTaskFinished?.call(task);
      notifyListeners();
    }
  }

  Map<String, FollowUpdateSourceProgress> _buildInitialSources(
    String folder, {
    required bool ignoreCheckTime,
  }) {
    var result = <String, FollowUpdateSourceProgress>{};
    for (var comic in LocalFavoritesManager().getComicsWithUpdatesInfo(
      folder,
    )) {
      if (!ignoreCheckTime) {
        var lastCheckTime = comic.lastCheckTime;
        if (lastCheckTime != null &&
            DateTime.now().difference(lastCheckTime).inDays < 1) {
          continue;
        }
      }
      result
          .putIfAbsent(
            comic.sourceKey,
            () => FollowUpdateSourceProgress(
              sourceKey: comic.sourceKey,
              sourceName: _sourceName(comic),
              total: 0,
            ),
          )
          .total++;
    }
    return result;
  }

  static String _sourceName(FavoriteItem comic) {
    if (comic.sourceKey == 'local') {
      return 'Local';
    }
    if (comic.sourceKey.startsWith('Unknown:')) {
      return comic.sourceKey;
    }
    return comic.type.comicSource?.name ?? comic.sourceKey;
  }

  void _loadHistory() {
    var data = appdata.implicitData['follow_update_task_history'];
    if (data is! List) {
      return;
    }
    historyTasks
      ..clear()
      ..addAll(
        data.whereType<Map>().map(
          (e) => FollowUpdateTask.fromJson(Map<String, dynamic>.from(e)),
        ),
      );
  }

  void _saveHistory() {
    appdata.implicitData['follow_update_task_history'] = historyTasks
        .map((task) => task.toJson())
        .toList();
    appdata.writeImplicitData();
  }
}

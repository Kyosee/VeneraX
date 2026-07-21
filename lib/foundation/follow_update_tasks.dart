import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/utils/data_sync.dart';

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
    _loadActiveTasks();
    _loadHistory();
  }

  static final FollowUpdateTaskManager instance = FollowUpdateTaskManager._();

  final currentTasks = <FollowUpdateTask>[];
  final historyTasks = <FollowUpdateTask>[];
  final _canceledIds = <String>{};

  /// Ids whose [_run] loop is currently executing, so resume/cancel can tell a
  /// restored-but-not-yet-running task apart from an actively running one.
  final _runningIds = <String>{};
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
    _saveActiveTasks();
    notifyListeners();
    unawaited(_run(task, ignoreCheckTime: manual));
    return task;
  }

  void cancel(String id) {
    _canceledIds.add(id);
    var task = currentTasks.where((t) => t.id == id).firstOrNull;
    if (task == null) {
      notifyListeners();
      return;
    }
    task.status = FollowUpdateTaskStatus.canceled;
    // Remove from the active list immediately so the UI reflects the cancel at
    // once, instead of lingering for seconds while in-flight network fetches
    // drain. A running [_run] loop keeps observing _canceledIds and winds its
    // background workers down; its finally then clears the tracking sets once
    // the stream has truly closed. Keep the id in _canceledIds until then so
    // the still-running workers don't see the flag flip back to false.
    _moveToHistory(task);
    if (!_runningIds.contains(id)) {
      // No _run loop is active to clear tracking for a pending (not-yet-running)
      // or already-finished task, so drop the flag now.
      _canceledIds.remove(id);
    }
    notifyListeners();
  }

  /// Cancels any pending/running task for [folder] (used when the user changes
  /// or disables the follow-updates folder — that is treated as an explicit
  /// cancellation, so the old folder's task must not be resumed later).
  void cancelForFolder(String folder) {
    for (var task in currentTasks.where((t) => t.folder == folder).toList()) {
      cancel(task.id);
    }
  }

  Future<void> _run(
    FollowUpdateTask task, {
    required bool ignoreCheckTime,
    bool resume = false,
  }) async {
    if (_runningIds.contains(task.id)) {
      return;
    }
    // The task may have been cancelled/finalized between being scheduled and
    // this loop starting (e.g. user cancelled a just-restored pending task).
    if (_canceledIds.contains(task.id) || !currentTasks.contains(task)) {
      return;
    }
    _runningIds.add(task.id);
    try {
      await for (var progress in updateFolder(
        task.folder,
        ignoreCheckTime,
        shouldCancel: () => _canceledIds.contains(task.id),
        // Only on resume: skip comics whose last check is at or after this
        // task's creation time (i.e. already processed before the app was
        // killed), so it continues from the breakpoint. On a fresh run nothing
        // has been checked yet, so leaving this null keeps `total` (computed by
        // _buildInitialSources) in step with the comics actually processed.
        checkedSince: resume ? task.createdAt : null,
      )) {
        if (_canceledIds.contains(task.id)) {
          // Keep draining (don't break) so the background producer/consumers
          // observe the cancel flag and wind down; abandoning the stream here
          // would leave detached workers running the whole folder to completion.
          // The task is already in history (cancel() moved it there for an
          // instant UI), so just skip counter/progress updates.
          task.status = FollowUpdateTaskStatus.canceled;
          continue;
        }
        var comic = progress.comic;
        if (comic != null) {
          // Count incrementally so a resumed task keeps accumulating onto the
          // persisted counters instead of being reset by the stream's totals.
          task.checked++;
          var source = task.sources.putIfAbsent(
            comic.sourceKey,
            () => FollowUpdateSourceProgress(
              sourceKey: comic.sourceKey,
              sourceName: _sourceName(comic),
              total: 0,
            ),
          );
          source.checked++;
          if (progress.comicUpdated) {
            task.updated++;
            source.updated++;
          }
          if (progress.errorMessage != null) {
            task.failed++;
            source.failed++;
          }
          _saveActiveTasksThrottled();
          _refreshKeepAlive(task);
        }
        _notifyProgress();
      }
      if (task.status == FollowUpdateTaskStatus.running) {
        task.status = FollowUpdateTaskStatus.completed;
      }
    } catch (_) {
      task.status = FollowUpdateTaskStatus.failed;
    } finally {
      _progressNotifyTimer?.cancel();
      _progressNotifyTimer = null;
      _finalize(task);
      onTaskFinished?.call(task);
      notifyListeners();
    }
  }

  Timer? _progressNotifyTimer;

  /// Coalesces per-comic progress notifications. Several concurrent workers
  /// can finish comics near-simultaneously; notifying on every event rebuilt
  /// listeners multiple times within one frame during a check. Progress UI
  /// doesn't need more than a few updates per second; terminal transitions
  /// still notify immediately (cancel() and _run's finally).
  void _notifyProgress() {
    if (_progressNotifyTimer != null) {
      return;
    }
    _progressNotifyTimer = Timer(const Duration(milliseconds: 250), () {
      _progressNotifyTimer = null;
      notifyListeners();
    });
  }

  /// Clears a task's run/cancel tracking and ensures it's in history. Called
  /// from [_run]'s finally once the background stream has truly closed.
  /// Idempotent.
  void _finalize(FollowUpdateTask task) {
    _canceledIds.remove(task.id);
    _runningIds.remove(task.id);
    _moveToHistory(task);
  }

  /// Moves a terminal task out of [currentTasks] into history and clears its
  /// persisted active entry + keep-alive notification. Idempotent: a task that
  /// was already moved (e.g. cancelled while still draining) is ignored.
  void _moveToHistory(FollowUpdateTask task) {
    if (!currentTasks.remove(task)) {
      return;
    }
    task.finishedAt ??= DateTime.now();
    historyTasks.insert(0, task);
    if (historyTasks.length > 50) {
      historyTasks.removeRange(50, historyTasks.length);
    }
    _saveActiveTasks();
    _saveHistory();
    if (currentTasks.where((t) => t.isRunning).isEmpty) {
      BackgroundKeepAlive.instance.remove(BackgroundKeepAlive.tagFollowUpdate);
    }
  }

  /// Resumes follow-update tasks that were running when the app was last killed.
  /// Called once at startup, before the periodic checker, so an interrupted
  /// check continues from its breakpoint instead of starting over.
  Future<void> resumePendingTasks() async {
    // Startup resume used to race the startup WebDAV download: the resumed
    // check wrote marks into the very database the download was applying a
    // backup into. FollowUpdatesService._check waits this out; give the
    // resume path the same courtesy. Cancels issued meanwhile are honored by
    // _run's entry checks after the wait.
    while (DataSync().isDownloading || DataSync().isApplyingBackup) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    for (var task in currentTasks.toList()) {
      if (task.isRunning && !_runningIds.contains(task.id)) {
        // Resume with the task's original manual/auto semantics. Combined with
        // `checkedSince` (its creation time), comics already processed before
        // the interruption are skipped, so it continues from the breakpoint
        // rather than starting over.
        unawaited(_run(task, ignoreCheckTime: task.manual, resume: true));
      }
    }
  }

  void _refreshKeepAlive(FollowUpdateTask task) {
    var detail = task.total == 0
        ? '${task.checked}'
        : '${task.checked}/${task.total}';
    BackgroundKeepAlive.instance.update(
      BackgroundKeepAlive.tagFollowUpdate,
      formatTaskStatus(title: task.folder, detail: detail),
    );
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
        var lastCheckTime = comic.lastCheckDateTime;
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

  /// Restore tasks that were still running at last shutdown. They are marked
  /// running on disk; [resumePendingTasks] picks them up after init.
  void _loadActiveTasks() {
    var data = appdata.implicitData['follow_update_active_tasks'];
    if (data is! List) {
      return;
    }
    currentTasks
      ..clear()
      ..addAll(
        data.whereType<Map>().map((e) {
          var task = FollowUpdateTask.fromJson(Map<String, dynamic>.from(e));
          // Anything persisted as active but not in a clean running state is
          // coerced back to running so it can be resumed.
          if (!task.isRunning) {
            task.status = FollowUpdateTaskStatus.running;
            task.finishedAt = null;
          }
          return task;
        }),
      );
  }

  void _saveActiveTasks() {
    appdata.implicitData['follow_update_active_tasks'] = currentTasks
        .where((task) => task.isRunning)
        .map((task) => task.toJson())
        .toList();
    appdata.writeImplicitData();
  }

  DateTime _lastActiveTasksSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Per-comic persistence rewrites the whole implicit-data file; on a large
  /// folder that's hundreds of writes per check, so cap it at one per second.
  /// Counters may lag disk by at most that second after a hard kill — resume
  /// correctness is unaffected, it derives from each comic's last_check_time
  /// in the favorites database, not from these counters. Terminal states
  /// still persist immediately via [_saveActiveTasks].
  void _saveActiveTasksThrottled() {
    var now = DateTime.now();
    if (now.difference(_lastActiveTasksSave) < const Duration(seconds: 1)) {
      return;
    }
    _lastActiveTasksSave = now;
    _saveActiveTasks();
  }
}

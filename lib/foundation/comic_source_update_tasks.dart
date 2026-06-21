import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/ext.dart';

enum ComicSourceUpdateTaskStatus { running, completed, canceled, failed }

class ComicSourceUpdateTaskDetail {
  ComicSourceUpdateTaskDetail({
    required this.sourceKey,
    required this.sourceName,
    required this.oldVersion,
    this.targetVersion,
    this.newVersion,
    this.status = 'pending',
    this.error,
  });

  final String sourceKey;
  final String sourceName;
  final String oldVersion;
  final String? targetVersion;
  String? newVersion;
  String status;
  String? error;

  Map<String, dynamic> toJson() => {
    'sourceKey': sourceKey,
    'sourceName': sourceName,
    'oldVersion': oldVersion,
    'targetVersion': targetVersion,
    'newVersion': newVersion,
    'status': status,
    'error': error,
  };

  factory ComicSourceUpdateTaskDetail.fromJson(Map<String, dynamic> json) {
    return ComicSourceUpdateTaskDetail(
      sourceKey: json['sourceKey'] ?? '',
      sourceName: json['sourceName'] ?? '',
      oldVersion: json['oldVersion'] ?? '',
      targetVersion: json['targetVersion'],
      newVersion: json['newVersion'],
      status: json['status'] ?? 'pending',
      error: json['error'],
    );
  }
}

class ComicSourceUpdateTask {
  ComicSourceUpdateTask({
    required this.id,
    required this.createdAt,
    required this.details,
    this.status = ComicSourceUpdateTaskStatus.running,
    this.total = 0,
    this.checked = 0,
    this.updated = 0,
    this.failed = 0,
    this.finishedAt,
  });

  final String id;
  final DateTime createdAt;
  final List<ComicSourceUpdateTaskDetail> details;
  ComicSourceUpdateTaskStatus status;
  int total;
  int checked;
  int updated;
  int failed;
  DateTime? finishedAt;

  bool get isRunning => status == ComicSourceUpdateTaskStatus.running;

  double get progress => total == 0 ? 0 : checked / total;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'total': total,
    'checked': checked,
    'updated': updated,
    'failed': failed,
    'details': details.map((detail) => detail.toJson()).toList(),
  };

  factory ComicSourceUpdateTask.fromJson(Map<String, dynamic> json) {
    return ComicSourceUpdateTask(
      id: json['id'] ?? '',
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] ?? ''),
      status: ComicSourceUpdateTaskStatus.values.firstWhere(
        (status) => status.name == json['status'],
        orElse: () => ComicSourceUpdateTaskStatus.completed,
      ),
      total: json['total'] ?? 0,
      checked: json['checked'] ?? 0,
      updated: json['updated'] ?? 0,
      failed: json['failed'] ?? 0,
      details:
          (json['details'] as List?)?.whereType<Map>().map((item) {
            return ComicSourceUpdateTaskDetail.fromJson(
              Map<String, dynamic>.from(item),
            );
          }).toList() ??
          const <ComicSourceUpdateTaskDetail>[],
    );
  }
}

class ComicSourceUpdateTaskManager with ChangeNotifier {
  ComicSourceUpdateTaskManager._() {
    _loadHistory();
  }

  static final ComicSourceUpdateTaskManager instance =
      ComicSourceUpdateTaskManager._();

  final currentTasks = <ComicSourceUpdateTask>[];
  final historyTasks = <ComicSourceUpdateTask>[];
  final _canceledIds = <String>{};

  ComicSourceUpdateTask start(
    List<ComicSource> sources, {
    Map<String, String> targetVersions = const {},
  }) {
    if (sources.isEmpty) {
      throw 'No comic sources selected';
    }
    final task = ComicSourceUpdateTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      total: sources.length,
      details: sources.map((source) {
        return ComicSourceUpdateTaskDetail(
          sourceKey: source.key,
          sourceName: source.name,
          oldVersion: source.version,
          targetVersion: targetVersions[source.key],
        );
      }).toList(),
    );
    currentTasks.insert(0, task);
    notifyListeners();
    unawaited(_run(task, sources));
    return task;
  }

  void cancel(String id) {
    _canceledIds.add(id);
    notifyListeners();
  }

  Future<void> _run(
    ComicSourceUpdateTask task,
    List<ComicSource> sources,
  ) async {
    final sourceMap = {for (final source in sources) source.key: source};
    try {
      for (final detail in task.details) {
        if (_canceledIds.contains(task.id)) {
          detail.status = 'skipped';
          task.status = ComicSourceUpdateTaskStatus.canceled;
          continue;
        }
        final source = sourceMap[detail.sourceKey];
        if (source == null) {
          detail.status = 'failed';
          detail.error = 'Source unavailable';
          task.failed++;
          task.checked++;
          notifyListeners();
          continue;
        }
        detail.status = 'updating';
        notifyListeners();
        try {
          detail.newVersion = await updateSourceFile(source);
          detail.status = 'updated';
          task.updated++;
        } catch (e) {
          detail.status = 'failed';
          detail.error = e.toString();
          task.failed++;
        }
        task.checked++;
        notifyListeners();
      }
      if (_canceledIds.contains(task.id)) {
        task.status = ComicSourceUpdateTaskStatus.canceled;
      } else if (task.status == ComicSourceUpdateTaskStatus.running) {
        task.status = task.updated == 0 && task.failed > 0
            ? ComicSourceUpdateTaskStatus.failed
            : ComicSourceUpdateTaskStatus.completed;
      }
    } finally {
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
  }

  /// Keys whose local data (login/cookies/localStorage) must be purged on the
  /// next successful file replacement. Set by the library-switch flow so the
  /// destructive purge is deferred until the new script has actually been
  /// downloaded — a failed switch then leaves the existing session intact.
  /// The injected purge runs after a non-empty download, before the in-place
  /// rewrite. Kept as a hook to avoid a foundation→UI layering inversion.
  static final pendingDataPurge = <String>{};
  static void Function(ComicSource source)? onPurgeLocalData;

  static Future<String> updateSourceFile(ComicSource source) async {
    // Prefer the download URL resolved from the source list during the last
    // update check; fall back to the URL baked into the installed script.
    // This keeps single-source updates pointed at the current address after a
    // source list migration, instead of the dead old one in the old script.
    final downloadUrl =
        ComicSourceManager().updateUrlFor(source.key) ?? source.url;
    if (!downloadUrl.isURL) {
      throw Exception('Invalid url config');
    }
    var removed = false;
    try {
      final res = await AppDio().get<String>(
        downloadUrl,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'cache-time': 'no'},
        ),
      );
      final data = res.data;
      if (data == null || data.isEmpty) {
        throw Exception('Empty response');
      }
      // Download confirmed: now safe to purge local data for a library switch.
      if (pendingDataPurge.remove(source.key)) {
        onPurgeLocalData?.call(source);
      }
      ComicSourceManager().remove(source.key);
      removed = true;
      final parsed = await ComicSourceParser().parse(data, source.filePath);
      await File(source.filePath).writeAsString(data);
      ComicSourceManager().clearAvailableUpdate(source.key);
      return parsed.version;
    } finally {
      if (removed) {
        await ComicSourceManager().reload();
      }
    }
  }

  void _loadHistory() {
    final data = appdata.implicitData['comic_source_update_task_history'];
    if (data is! List) {
      return;
    }
    historyTasks
      ..clear()
      ..addAll(
        data.whereType<Map>().map((item) {
          return ComicSourceUpdateTask.fromJson(
            Map<String, dynamic>.from(item),
          );
        }),
      );
  }

  void _saveHistory() {
    appdata.implicitData['comic_source_update_task_history'] = historyTasks
        .map((task) => task.toJson())
        .toList();
    appdata.writeImplicitData();
  }
}

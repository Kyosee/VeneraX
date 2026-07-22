import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source_update_tasks.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/data_sync_tasks.dart';
import 'package:venera/foundation/export_tasks.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/foundation/import_tasks.dart';
import 'package:venera/foundation/history_tasks.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/related_source_tasks.dart';
import 'package:venera/foundation/source_migration_tasks.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> with SingleTickerProviderStateMixin {
  final followUpdateManager = FollowUpdateTaskManager.instance;
  final historyRefreshManager = HistoryRefreshTaskManager.instance;
  final relatedSourceManager = RelatedSourceTaskManager.instance;
  final sourceMigrationManager = SourceMigrationTaskManager.instance;
  final comicSourceUpdateManager = ComicSourceUpdateTaskManager.instance;
  final importManager = ImportTaskManager.instance;
  final exportManager = ExportTaskManager.instance;
  final dataSyncManager = DataSyncTaskManager.instance;
  final modelStore = TranslationModelStore.instance;
  final preTranslateManager = PreTranslationTaskManager.instance;
  final preTranslationManager = PreTranslationTaskManager.instance;

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
    followUpdateManager.addListener(update);
    historyRefreshManager.addListener(update);
    relatedSourceManager.addListener(update);
    sourceMigrationManager.addListener(update);
    comicSourceUpdateManager.addListener(update);
    importManager.addListener(update);
    exportManager.addListener(update);
    dataSyncManager.addListener(update);
    modelStore.addListener(update);
    preTranslateManager.addListener(update);
  }

  @override
  void dispose() {
    _tabController.dispose();
    followUpdateManager.removeListener(update);
    historyRefreshManager.removeListener(update);
    relatedSourceManager.removeListener(update);
    sourceMigrationManager.removeListener(update);
    comicSourceUpdateManager.removeListener(update);
    importManager.removeListener(update);
    exportManager.removeListener(update);
    dataSyncManager.removeListener(update);
    modelStore.removeListener(update);
    preTranslateManager.removeListener(update);
    super.dispose();
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  bool _hasHistoryTasks() {
    return dataSyncManager.historyTasks.isNotEmpty ||
        followUpdateManager.historyTasks.isNotEmpty ||
        historyRefreshManager.historyTasks.isNotEmpty ||
        relatedSourceManager.historyTasks.isNotEmpty ||
        sourceMigrationManager.historyTasks.isNotEmpty ||
        comicSourceUpdateManager.historyTasks.isNotEmpty ||
        importManager.historyTasks.isNotEmpty ||
        exportManager.historyTasks.isNotEmpty ||
        preTranslateManager.historyTasks.isNotEmpty;
  }

  void _clearAllHistory() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Clear History".tl),
        content: Text("Delete all task history?".tl),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("Cancel".tl),
          ),
          TextButton(
            onPressed: () {
              dataSyncManager.clearHistory();
              followUpdateManager.clearHistory();
              historyRefreshManager.clearHistory();
              relatedSourceManager.clearHistory();
              sourceMigrationManager.clearHistory();
              comicSourceUpdateManager.clearHistory();
              importManager.clearHistory();
              exportManager.clearHistory();
              preTranslateManager.clearHistory();
              Navigator.pop(context);
            },
            child: Text("Delete".tl),
          ),
        ],
      ),
    );
  }

  /// Remove task by type and id
  void _removeTask(String taskType, String id) {
    switch (taskType) {
      case 'data_sync_upload':
      case 'data_sync_download':
        dataSyncManager.removeTask(id);
      case 'follow_update':
        followUpdateManager.removeTask(id);
      case 'history_refresh':
        historyRefreshManager.removeTask(id);
      case 'related_source':
        relatedSourceManager.removeTask(id);
      case 'source_migration':
        sourceMigrationManager.removeTask(id);
      case 'comic_source_update':
        comicSourceUpdateManager.removeTask(id);
      case 'import':
        importManager.removeTask(id);
      case 'export':
        exportManager.removeTask(id);
      case 'pre_translate':
        preTranslateManager.removeTask(id);
    }
  }

  /// Wrap history task card with Dismissible for swipe-to-delete
  Widget _wrapHistoryCard(Widget card, String taskType, String taskId, bool isRunning) {
    if (isRunning) return card;

    return Dismissible(
      key: Key('${taskType}_$taskId'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => _removeTask(taskType, taskId),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: context.colorScheme.errorContainer,
        child: Icon(Icons.delete_outline, color: context.colorScheme.onErrorContainer),
      ),
      child: card,
    );
  }

  /// Wrap icon with rotation animation for running tasks
  Widget _wrapIconWithRotation(IconData icon, bool isRunning, String? status) {
    if (isRunning && status != 'paused') {
      return _RotatingIcon(icon: icon);
    }
    return Icon(icon);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Tasks".tl)),
      body: Column(
        children: [
          Material(
            child: Stack(
              alignment: Alignment.centerRight,
              children: [
                AppTabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(text: "Current".tl),
                    Tab(text: "History".tl),
                  ],
                ),
                // 只在历史标签显示清空按钮
                if (_tabController.index == 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: IconButton(
                      icon: const Icon(Icons.delete_sweep),
                      tooltip: "Clear History".tl,
                      onPressed: _hasHistoryTasks() ? _clearAllHistory : null,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [buildCurrentTasks(), buildHistoryTasks()],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildCurrentTasks() {
    var widgets = <Widget>[
      ...dataSyncManager.currentTasks.map(
        (task) => buildDataSyncTaskCard(task, expanded: false),
      ),
      ...followUpdateManager.currentTasks.map(
        (task) => buildFollowUpdateTaskCard(task, expanded: false),
      ),
      ...historyRefreshManager.currentTasks.map(
        (task) => buildHistoryRefreshTaskCard(task, expanded: false),
      ),
      ...relatedSourceManager.currentTasks.map(
        (task) => buildRelatedSourceTaskCard(task, expanded: false),
      ),
      ...sourceMigrationManager.currentTasks.map(
        (task) => buildSourceMigrationTaskCard(task, expanded: false),
      ),
      ...comicSourceUpdateManager.currentTasks.map(
        (task) => buildComicSourceUpdateTaskCard(task, expanded: false),
      ),
      ...importManager.currentTasks.map(
        (task) => buildImportTaskCard(task, expanded: false),
      ),
      ...exportManager.currentTasks.map(
        (task) => buildExportTaskCard(task, expanded: false),
      ),
      for (var component in TranslationModels.all)
        if (modelStore.stateOf(component).downloading)
          buildModelDownloadCard(component),
    ];
    return buildTaskWidgets(widgets, "No current tasks".tl);
  }

  /// Progress card for an ongoing translation-model download. Transient (no
  /// history entry): once finished the model simply shows as installed in the
  /// model management page.
  Widget buildModelDownloadCard(ModelComponent component) {
    var state = modelStore.stateOf(component);
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const _RotatingIcon(icon: Icons.download),
        title: Text(
          "${"Translation model".tl}: ${translationModelName(component.id)}",
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "${bytesToReadableString(state.receivedBytes)} / "
              "${bytesToReadableString(state.totalBytes ?? component.approxSizeBytes)}",
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: state.progress <= 0 ? null : state.progress,
            ),
          ],
        ),
        trailing: TextButton(
          onPressed: () => modelStore.cancelDownload(component),
          child: Text("Cancel".tl),
        ),
      ),
    );
  }

  String translationModelName(String id) {
    return switch (id) {
      'text_detector' => "Text detector".tl,
      'ocr_ja' => "Japanese OCR (manga)".tl,
      'ocr_zh' => "Chinese / Latin OCR".tl,
      'ocr_en' => "English OCR".tl,
      'ocr_ko' => "Korean OCR".tl,
      _ => id,
    };
  }

  Widget buildHistoryTasks() {
    var entries = <MapEntry<DateTime, Widget>>[
      ...dataSyncManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildDataSyncTaskCard(task, expanded: false),
        ),
      ),
      ...followUpdateManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildFollowUpdateTaskCard(task, expanded: false),
        ),
      ),
      ...historyRefreshManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildHistoryRefreshTaskCard(task, expanded: false),
        ),
      ),
      ...relatedSourceManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildRelatedSourceTaskCard(task, expanded: false),
        ),
      ),
      ...sourceMigrationManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildSourceMigrationTaskCard(task, expanded: false),
        ),
      ),
      ...comicSourceUpdateManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildComicSourceUpdateTaskCard(task, expanded: false),
        ),
      ),
      ...importManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildImportTaskCard(task, expanded: false),
        ),
      ),
      ...exportManager.historyTasks.map(
        (task) => MapEntry(
          task.finishedAt ?? task.createdAt,
          buildExportTaskCard(task, expanded: false),
        ),
      ),
    ];
    entries.sort((a, b) => b.key.compareTo(a.key));
    var widgets = entries.map((entry) => entry.value).toList();
    return buildTaskWidgets(widgets, "No task history".tl);
  }

  Widget buildTaskWidgets(List<Widget> widgets, String emptyText) {
    if (widgets.isEmpty) {
      return Center(child: Text(emptyText, style: ts.s16));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      children: widgets,
    );
  }

  Widget buildTaskSubtitle(
    List<String> parts,
    DateTime createdAt,
    DateTime? finishedAt,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 任务状态和进度信息使用自适应布局
        LayoutBuilder(
          builder: (context, constraints) {
            // 在窄屏幕上每行显示更少信息，避免省略号
            final displayParts = constraints.maxWidth < 300
                ? parts.take(2).toList()
                : parts;
            return Text(
              displayParts.join(" · "),
              maxLines: constraints.maxWidth < 250 ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        const SizedBox(height: 2),
        // 时间信息使用更紧凑的格式
        LayoutBuilder(
          builder: (context, constraints) {
            final timeText = constraints.maxWidth < 400
                ? taskTimeTextCompact(createdAt, finishedAt)
                : taskTimeText(createdAt, finishedAt);
            return Text(
              timeText,
              maxLines: constraints.maxWidth < 300 ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
            );
          },
        ),
      ],
    );
  }

  String taskTimeText(DateTime createdAt, DateTime? finishedAt) {
    return [
      "Start Time: @time".tlParams({'time': formatTaskTime(createdAt)}),
      "End Time: @time".tlParams({
        'time': finishedAt == null ? '-' : formatTaskTime(finishedAt),
      }),
    ].join(" · ");
  }

  String taskTimeTextCompact(DateTime createdAt, DateTime? finishedAt) {
    return [
      "Start: @time".tlParams({'time': formatTaskTimeCompact(createdAt)}),
      if (finishedAt != null)
        "End: @time".tlParams({'time': formatTaskTimeCompact(finishedAt)}),
    ].join("\n");
  }

  String formatTaskTime(DateTime time) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(time);
  }

  String formatTaskTimeCompact(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inDays == 0) {
      return DateFormat('HH:mm:ss').format(time);
    } else if (diff.inDays < 7) {
      return DateFormat('MM-dd HH:mm').format(time);
    }
    return DateFormat('yyyy-MM-dd').format(time);
  }

  /// 统一的任务图标获取方法
  IconData getTaskIcon(String taskType, bool isRunning, {String? status}) {
    // 优先检查状态（包括运行中可能的 paused 状态）
    if (status == 'paused') return Icons.pause_circle_outline;
    if (status == 'completed') return Icons.check_circle_outline;
    if (status == 'failed') return Icons.error_outline;
    if (status == 'canceled') return Icons.cancel_outlined;

    // 运行中的任务根据类型显示图标
    if (isRunning) {
      return switch (taskType) {
        'follow_update' => Icons.sync,
        'history_refresh' => Icons.manage_history,
        'related_source' => Icons.hub_outlined,
        'source_migration' => Icons.move_up_outlined,
        'comic_source_update' => Icons.update,
        'import' => Icons.cloud_download,
        'export' => Icons.save_alt,
        'data_sync_upload' => Icons.cloud_upload,
        'data_sync_download' => Icons.cloud_download,
        'pre_translate' => Icons.translate,
        _ => Icons.task,
      };
    }

    // 其他历史任务
    return Icons.history;
  }

  /// 统一的任务标题格式：[功能类型] 描述
  String getTaskTitle(String taskType, Map<String, Object> params) {
    return switch (taskType) {
      'follow_update' => "Follow Update: @folder".tlParams(params),
      'history_refresh' => "History Refresh".tl,
      'related_source' => "Auto Link Sources: @folder".tlParams(params),
      'source_migration' => "Source Migration: @folder".tlParams(params),
      'comic_source_update' => "Update Sources".tl,
      'import' => params['file']?.toString().isEmpty ?? true
          ? "Import Data".tl
          : "Import: @file".tlParams(params),
      'export' => "Export Comics".tl,
      'data_sync_upload' => "WebDAV Upload".tl,
      'data_sync_download' => "WebDAV Download".tl,
      'pre_translate' => "Pre-translate: @title".tlParams(params),
      _ => taskType,
    };
  }

  Widget buildFollowUpdateTaskCard(
    FollowUpdateTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('follow_update', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
          getTaskTitle('follow_update', {'folder': task.folder}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [
            task.manual ? "Manual".tl : "Automatic".tl,
            followUpdateStatusText(task),
            progressText,
          ],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isRunning
            ? TextButton(
                onPressed: () => followUpdateManager.cancel(task.id),
                child: Text("Cancel".tl),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          buildFollowUpdateSummary(task),
          buildFollowUpdateSourceDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'follow_update', task.id, task.isRunning);
  }

  String preTranslateStatusText(PreTranslationTask task) {
    return switch (task.status) {
      PreTranslationTaskStatus.running => "Running".tl,
      PreTranslationTaskStatus.completed => "Completed".tl,
      PreTranslationTaskStatus.canceled => "Canceled".tl,
      PreTranslationTaskStatus.failed => "Failed".tl,
    };
  }

  Widget buildPreTranslateTaskCard(
    PreTranslationTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('pre_translate', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
          getTaskTitle('pre_translate', {'title': task.title}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [
            preTranslateStatusText(task),
            "@count chapters".tlParams({'count': task.chapters.length}),
            progressText,
          ],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isRunning
            ? TextButton(
                onPressed: () => preTranslateManager.cancel(task.id),
                child: Text("Cancel".tl),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          buildSourceBox(
            title: "Details".tl,
            children: [
              Text(
                "Pages: @done/@total".tlParams({
                  'done': task.done,
                  'total': task.total,
                }),
                style: ts.s14,
              ),
              if (task.failed > 0) ...[
                const SizedBox(height: 2),
                Text(
                  "Failed: @count".tlParams({'count': task.failed}),
                  style: ts.s14.withColor(context.colorScheme.error),
                ),
              ],
            ],
          ),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'pre_translate', task.id, task.isRunning);
  }

  Widget buildHistoryRefreshTaskCard(
    HistoryRefreshTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('history_refresh', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(getTaskTitle('history_refresh', {})),
        subtitle: buildTaskSubtitle(
          [historyRefreshStatusText(task), progressText],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isRunning
            ? TextButton(
                onPressed: () => historyRefreshManager.cancel(task.id),
                child: Text("Cancel".tl),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          buildHistoryRefreshSummary(task),
          buildHistoryRefreshSourceDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'history_refresh', task.id, task.isRunning);
  }

  Widget buildRelatedSourceTaskCard(
    RelatedSourceTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('related_source', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
          getTaskTitle('related_source', {'folder': task.folder}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [relatedSourceStatusText(task), progressText],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isActive
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: task.isRunning
                        ? () => relatedSourceManager.pause(task.id)
                        : () => relatedSourceManager.resume(task.id),
                    child: Text(task.isRunning ? "Pause".tl : "Resume".tl),
                  ),
                  TextButton(
                    onPressed: () => relatedSourceManager.cancel(task.id),
                    child: Text("Cancel".tl),
                  ),
                ],
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          buildRelatedSourceSummary(task),
          buildRelatedSourceDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'related_source', task.id, task.isRunning);
  }

  Widget buildSourceMigrationTaskCard(
    SourceMigrationTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('source_migration', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
          getTaskTitle('source_migration', {'folder': task.folder}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [sourceMigrationStatusText(task), progressText],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isActive
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (task.isWaitingConfirmation)
                    TextButton(
                      onPressed: () {
                        sourceMigrationManager.confirmAll(task.id);
                      },
                      child: Text("Confirm All".tl),
                    ),
                  TextButton(
                    onPressed: () => sourceMigrationManager.cancel(task.id),
                    child: Text("Cancel".tl),
                  ),
                ],
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          buildSourceMigrationSummary(task),
          buildSourceMigrationDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'source_migration', task.id, task.isRunning);
  }

  Widget buildComicSourceUpdateTaskCard(
    ComicSourceUpdateTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('comic_source_update', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
          getTaskTitle('comic_source_update', {}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [comicSourceUpdateStatusText(task), progressText],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isRunning
            ? TextButton(
                onPressed: () => comicSourceUpdateManager.cancel(task.id),
                child: Text("Cancel".tl),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          buildComicSourceUpdateSummary(task),
          buildComicSourceUpdateDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'comic_source_update', task.id, task.isRunning);
  }

  Widget buildFollowUpdateSummary(FollowUpdateTask task) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          "Total: @total  Checked: @checked  Updated: @updated  Failed: @failed"
              .tlParams({
                'total': task.total,
                'checked': task.checked,
                'updated': task.updated,
                'failed': task.failed,
              }),
          style: ts.s14,
        ),
      ),
    );
  }

  Widget buildHistoryRefreshSummary(HistoryRefreshTask task) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          "Total: @total  Checked: @checked  Success: @success  Failed: @failed  Skipped: @skipped"
              .tlParams({
                'total': task.total,
                'checked': task.checked,
                'success': task.success,
                'failed': task.failed,
                'skipped': task.skipped,
              }),
          style: ts.s14,
        ),
      ),
    );
  }

  Widget buildRelatedSourceSummary(RelatedSourceTask task) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          "Total: @total  Checked: @checked  Candidates: @candidates  Failed: @failed"
              .tlParams({
                'total': task.total,
                'checked': task.checked,
                'candidates': task.candidates,
                'failed': task.failed,
              }),
          style: ts.s14,
        ),
      ),
    );
  }

  Widget buildSourceMigrationSummary(SourceMigrationTask task) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          "Total: @total  Checked: @checked  Migrated: @migrated  Failed: @failed"
              .tlParams({
                'total': task.total,
                'checked': task.checked,
                'migrated': task.migrated,
                'failed': task.failed,
              }),
          style: ts.s14,
        ),
      ),
    );
  }

  Widget buildComicSourceUpdateSummary(ComicSourceUpdateTask task) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          "Total: @total  Checked: @checked  Updated: @updated  Failed: @failed"
              .tlParams({
                'total': task.total,
                'checked': task.checked,
                'updated': task.updated,
                'failed': task.failed,
              }),
          style: ts.s14,
        ),
      ),
    );
  }

  Widget buildFollowUpdateSourceDetails(FollowUpdateTask task) {
    var sources = task.sources.values.toList()
      ..sort((a, b) => a.sourceName.compareTo(b.sourceName));
    return buildSourceBox(
      children: [
        for (var source in sources) ...[
          Text(
            source.sourceName == 'Local'
                ? source.sourceName.tl
                : source.sourceName,
          ),
          const SizedBox(height: 2),
          Text(
            "Total: @total  Checked: @checked  Updated: @updated  Failed: @failed"
                .tlParams({
                  'total': source.total,
                  'checked': source.checked,
                  'updated': source.updated,
                  'failed': source.failed,
                }),
            style: ts.s14,
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget buildHistoryRefreshSourceDetails(HistoryRefreshTask task) {
    var sources = task.sources.values.toList()
      ..sort((a, b) => a.sourceName.compareTo(b.sourceName));
    return buildSourceBox(
      children: [
        for (var source in sources) ...[
          Text(
            source.sourceName == 'Local'
                ? source.sourceName.tl
                : source.sourceName,
          ),
          const SizedBox(height: 2),
          Text(
            "Total: @total  Checked: @checked  Success: @success  Failed: @failed  Skipped: @skipped"
                .tlParams({
                  'total': source.total,
                  'checked': source.checked,
                  'success': source.success,
                  'failed': source.failed,
                  'skipped': source.skipped,
                }),
            style: ts.s14,
          ),
          if (source.errors.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text("Recent failures".tl, style: ts.s12),
            const SizedBox(height: 2),
            for (var error in source.errors.take(3))
              Text(
                error,
                style: ts.s12.withColor(context.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
          ],
          const SizedBox(height: 8),
        ],
        if (task.errors.length > 3)
          Text(
            "More failures: @count".tlParams({'count': task.errors.length - 3}),
            style: ts.s12,
          ),
      ],
    );
  }

  Widget buildRelatedSourceDetails(RelatedSourceTask task) {
    var sources = task.sources.values.toList()
      ..sort((a, b) => a.sourceName.compareTo(b.sourceName));
    return buildSourceBox(
      children: [
        for (var source in sources) ...[
          Text(source.sourceName),
          const SizedBox(height: 2),
          Text(
            "Total: @total  Checked: @checked  Candidates: @candidates  Failed: @failed"
                .tlParams({
                  'total': source.total,
                  'checked': source.checked,
                  'candidates': source.candidates,
                  'failed': source.failed,
                }),
            style: ts.s14,
          ),
          if (source.errors.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text("Recent failures".tl, style: ts.s12),
            const SizedBox(height: 2),
            for (var error in source.errors.take(3))
              Text(
                error,
                style: ts.s12.withColor(context.colorScheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
          ],
          const SizedBox(height: 8),
        ],
        if (task.errors.length > 3)
          Text(
            "More failures: @count".tlParams({'count': task.errors.length - 3}),
            style: ts.s12,
          ),
      ],
    );
  }

  Widget buildSourceMigrationDetails(SourceMigrationTask task) {
    return buildSourceBox(
      title: "Migration Details".tl,
      children: [
        Text("${"Target Source".tl}: ${task.targetSourceName}", style: ts.s14),
        const SizedBox(height: 8),
        for (var i = 0; i < task.details.length; i++) ...[
          Builder(
            builder: (context) {
              final detail = task.details[i];
              final target = detail.target;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          detail.source.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          target == null
                              ? (detail.error ??
                                    migrationDetailStatusText(detail.status))
                              : "${target.title} · ${migrationDetailStatusText(detail.status)}",
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s12.withColor(
                            detail.status == 'failed'
                                ? context.colorScheme.error
                                : context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (task.isWaitingConfirmation && detail.status == 'matched')
                    TextButton(
                      onPressed: () {
                        sourceMigrationManager.confirm(task.id, i);
                      },
                      child: Text("Migrate".tl),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget buildComicSourceUpdateDetails(ComicSourceUpdateTask task) {
    return buildSourceBox(
      title: "Comic source update details".tl,
      children: [
        for (final detail in task.details) ...[
          Text(detail.sourceName, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(
            [
              "Version: @old -> @new".tlParams({
                'old': detail.oldVersion,
                'new': detail.newVersion ?? detail.targetVersion ?? '-',
              }),
              comicSourceUpdateDetailStatusText(detail.status),
            ].join(" · "),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: ts.s12.withColor(
              detail.status == 'failed'
                  ? context.colorScheme.error
                  : context.colorScheme.onSurfaceVariant,
            ),
          ),
          if (detail.error != null) ...[
            const SizedBox(height: 2),
            Text(
              detail.error!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: ts.s12.withColor(context.colorScheme.error),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget buildImportTaskCard(ImportTask task, {required bool expanded}) {
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('import', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
          getTaskTitle('import', {'file': task.fileName}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [importStatusText(task), importPhaseText(task)],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: importManager.isCancelable(task)
            ? TextButton(
                onPressed: () => importManager.cancel(task.id),
                child: Text("Cancel".tl),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning ? task.indicatorValue : 1.0,
            ),
          ),
          const SizedBox(height: 8),
          buildImportDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'import', task.id, task.isRunning);
  }

  String importStatusText(ImportTask task) {
    return switch (task.status) {
      ImportTaskStatus.running => "Running".tl,
      ImportTaskStatus.completed => "Completed".tl,
      ImportTaskStatus.canceled => "Canceled".tl,
      ImportTaskStatus.failed => "Failed".tl,
    };
  }

  String importPhaseText(ImportTask task) {
    if (task.phase == ImportPhase.extracting) {
      if (task.extractedBytes <= 0) return "Extracting".tl;
      return "Extracted @size".tlParams({
        'size': bytesToReadableString(task.extractedBytes),
      });
    }
    var key = task.phase == ImportPhase.applying && task.message != null
        ? task.message!
        : importPhaseLabelKey(task.phase);
    return key.tl;
  }

  Widget buildImportDetails(ImportTask task) {
    return buildSourceBox(
      title: "Details".tl,
      children: [
        Text(
          "File: @file".tlParams({
            'file': task.fileName.isEmpty ? '-' : task.fileName,
          }),
          style: ts.s14,
        ),
        if (task.fileSize > 0) ...[
          const SizedBox(height: 2),
          Text(
            "Size: @size".tlParams({
              'size': bytesToReadableString(task.fileSize),
            }),
            style: ts.s14,
          ),
        ],
        const SizedBox(height: 2),
        Text(
          "Status: @status".tlParams({'status': importPhaseText(task)}),
          style: ts.s14,
        ),
        if (task.status == ImportTaskStatus.failed && task.error != null) ...[
          const SizedBox(height: 2),
          Text(
            (task.error ?? '').tl,
            style: ts.s14.withColor(context.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget buildExportTaskCard(ExportTask task, {required bool expanded}) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('export', task.isActive, status: task.status.name),
          task.isActive,
          task.status.name,
        ),
        title: Text(
          getTaskTitle('export', {}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [
            task.format.label,
            exportStatusText(task),
            "${task.done}/${task.total}",
            progressText,
          ],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isActive
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (task.isPaused)
                    TextButton(
                      onPressed: () => exportManager.resume(task.id),
                      child: Text("Resume".tl),
                    )
                  else
                    TextButton(
                      onPressed: () => exportManager.pause(task.id),
                      child: Text("Pause".tl),
                    ),
                  TextButton(
                    onPressed: () => exportManager.cancel(task.id),
                    child: Text("Cancel".tl),
                  ),
                ],
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: _exportBarValue(task),
            ),
          ),
          const SizedBox(height: 8),
          buildExportDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'export', task.id, task.isRunning);
  }

  String exportStatusText(ExportTask task) {
    return switch (task.status) {
      ExportTaskStatus.running => "Running".tl,
      ExportTaskStatus.paused => "Paused".tl,
      ExportTaskStatus.completed => "Completed".tl,
      ExportTaskStatus.canceled => "Canceled".tl,
      ExportTaskStatus.failed => "Failed".tl,
    };
  }

  /// Phase text for a running export, so the card reflects packaging/writing
  /// instead of a frozen "done/total" (#92). Empty for non-running tasks.
  String exportPhaseText(ExportTask task) {
    if (!task.isRunning) return '';
    return switch (task.phase) {
      ExportPhase.preparing => "Preparing".tl,
      ExportPhase.processing => task.currentTitle ?? "Exporting".tl,
      ExportPhase.packaging => "Packaging".tl,
      ExportPhase.writing => task.writeProgress != null
          ? "Writing to folder @p%".tlParams({
              'p': (task.writeProgress! * 100).clamp(0, 100).toStringAsFixed(0),
            })
          : "Writing to folder".tl,
    };
  }

  /// Bar value for an export card: byte progress while writing, indeterminate
  /// while packaging, per-comic ratio otherwise (#92).
  double? _exportBarValue(ExportTask task) {
    if (task.isRunning && task.phase == ExportPhase.writing) {
      return task.writeProgress;
    }
    if (task.isRunning && task.phase == ExportPhase.packaging) {
      return null;
    }
    return task.isRunning && task.total == 0 ? null : task.progress;
  }

  Widget buildExportDetails(ExportTask task) {
    return buildSourceBox(
      title: "Details".tl,
      children: [
        Text(
          "Format: @format".tlParams({'format': task.format.label}),
          style: ts.s14,
        ),
        const SizedBox(height: 2),
        Text(
          "Folder: @folder".tlParams({'folder': task.folderPath}),
          style: ts.s14,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          "Total: @total  Exported: @done  Failed: @failed".tlParams({
            'total': task.total,
            'done': task.done,
            'failed': task.failedCount,
          }),
          style: ts.s14,
        ),
        if (task.isRunning && exportPhaseText(task).isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            "Status: @status".tlParams({'status': exportPhaseText(task)}),
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (task.status == ExportTaskStatus.failed && task.error != null) ...[
          const SizedBox(height: 2),
          Text(
            (task.error ?? '').tl,
            style: ts.s14.withColor(context.colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget buildSourceBox({required List<Widget> children, String? title}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title ?? "By comic source".tl, style: ts.s16),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }

  String followUpdateStatusText(FollowUpdateTask task) {
    return switch (task.status) {
      FollowUpdateTaskStatus.running => "Running".tl,
      FollowUpdateTaskStatus.completed => "Completed".tl,
      FollowUpdateTaskStatus.canceled => "Canceled".tl,
      FollowUpdateTaskStatus.failed => "Failed".tl,
    };
  }

  String historyRefreshStatusText(HistoryRefreshTask task) {
    return switch (task.status) {
      HistoryRefreshTaskStatus.running => "Running".tl,
      HistoryRefreshTaskStatus.completed => "Completed".tl,
      HistoryRefreshTaskStatus.canceled => "Canceled".tl,
      HistoryRefreshTaskStatus.failed => "Failed".tl,
    };
  }

  String relatedSourceStatusText(RelatedSourceTask task) {
    return switch (task.status) {
      RelatedSourceTaskStatus.running => "Running".tl,
      RelatedSourceTaskStatus.paused => "Paused".tl,
      RelatedSourceTaskStatus.completed => "Completed".tl,
      RelatedSourceTaskStatus.canceled => "Canceled".tl,
      RelatedSourceTaskStatus.failed => "Failed".tl,
    };
  }

  String sourceMigrationStatusText(SourceMigrationTask task) {
    return switch (task.status) {
      SourceMigrationTaskStatus.running => "Running".tl,
      SourceMigrationTaskStatus.waitingConfirmation =>
        "Waiting confirmation".tl,
      SourceMigrationTaskStatus.completed => "Completed".tl,
      SourceMigrationTaskStatus.canceled => "Canceled".tl,
      SourceMigrationTaskStatus.failed => "Failed".tl,
    };
  }

  String comicSourceUpdateStatusText(ComicSourceUpdateTask task) {
    return switch (task.status) {
      ComicSourceUpdateTaskStatus.running => "Running".tl,
      ComicSourceUpdateTaskStatus.completed => "Completed".tl,
      ComicSourceUpdateTaskStatus.canceled => "Canceled".tl,
      ComicSourceUpdateTaskStatus.failed => "Failed".tl,
    };
  }

  String comicSourceUpdateDetailStatusText(String status) {
    return switch (status) {
      'pending' => "Pending".tl,
      'updating' => "Updating".tl,
      'updated' => "Success".tl,
      'skipped' => "Skipped".tl,
      'failed' => "Failed".tl,
      _ => status,
    };
  }

  String migrationDetailStatusText(String status) {
    return switch (status) {
      'pending' => "Pending".tl,
      'matched' => "Matched".tl,
      'migrated' => "Migrated".tl,
      'skipped' => "Skipped".tl,
      'failed' => "Failed".tl,
      _ => status,
    };
  }

  Widget buildDataSyncTaskCard(DataSyncTask task, {required bool expanded}) {
    var progressText = "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final taskType = task.type == DataSyncTaskType.upload
        ? 'data_sync_upload'
        : 'data_sync_download';

    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon(taskType, task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
          getTaskTitle(taskType, {}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [
            dataSyncStatusText(task),
            if (task.currentPhase != null) task.currentPhase!.tl,
            progressText,
          ],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: null, // WebDAV sync cannot be canceled mid-operation
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning ? task.progress : 1.0,
            ),
          ),
          const SizedBox(height: 8),
          buildDataSyncDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, taskType, task.id, task.isRunning);
  }

  String dataSyncStatusText(DataSyncTask task) {
    return switch (task.status) {
      DataSyncTaskStatus.running => "Running".tl,
      DataSyncTaskStatus.completed => "Completed".tl,
      DataSyncTaskStatus.failed => "Failed".tl,
      DataSyncTaskStatus.canceled => "Canceled".tl,
    };
  }

  Widget buildDataSyncDetails(DataSyncTask task) {
    return buildSourceBox(
      title: "Details".tl,
      children: [
        Text(
          "Type: @type".tlParams({
            'type': (task.type == DataSyncTaskType.upload ? 'Upload' : 'Download').tl,
          }),
          style: ts.s14,
        ),
        if (task.fileName != null) ...[
          const SizedBox(height: 2),
          Text(
            "File: @file".tlParams({'file': task.fileName!}),
            style: ts.s14,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (task.fileSize != null && task.fileSize! > 0) ...[
          const SizedBox(height: 2),
          Text(
            "Size: @size".tlParams({
              'size': bytesToReadableString(task.fileSize!),
            }),
            style: ts.s14,
          ),
        ],
        if (task.currentPhase != null) ...[
          const SizedBox(height: 2),
          Text(
            "Phase: @phase".tlParams({'phase': task.currentPhase!.tl}),
            style: ts.s14,
          ),
        ],
        if (task.status == DataSyncTaskStatus.failed && task.error != null) ...[
          const SizedBox(height: 2),
          Text(
            task.error!,
            style: ts.s14.withColor(context.colorScheme.error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

/// Rotating icon widget with proper animation controller
class _RotatingIcon extends StatefulWidget {
  final IconData icon;
  const _RotatingIcon({required this.icon});

  @override
  State<_RotatingIcon> createState() => _RotatingIconState();
}

class _RotatingIconState extends State<_RotatingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(widget.icon),
    );
  }
}

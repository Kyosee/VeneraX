import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/task_list.dart';
import 'package:venera/foundation/comic_source_update_tasks.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/data_sync_tasks.dart';
import 'package:venera/foundation/export_tasks.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/foundation/import_tasks.dart';
import 'package:venera/foundation/history_tasks.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/related_source_tasks.dart';
import 'package:venera/foundation/source_migration_tasks.dart';
import 'package:venera/foundation/webdav_migration_tasks.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

part 'tasks_page/task_card_common.dart';
part 'tasks_page/model_download_task_card.dart';
part 'tasks_page/follow_update_task_card.dart';
part 'tasks_page/pre_translation_task_card.dart';
part 'tasks_page/history_refresh_task_card.dart';
part 'tasks_page/related_source_task_card.dart';
part 'tasks_page/source_migration_task_card.dart';
part 'tasks_page/comic_source_update_task_card.dart';
part 'tasks_page/import_task_card.dart';
part 'tasks_page/export_task_card.dart';
part 'tasks_page/webdav_migration_task_card.dart';
part 'tasks_page/data_sync_task_card.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({super.key, this.initialExpandedTaskId});

  /// When set, the matching running task card is initially expanded (used when
  /// arriving from the follow-update progress bar).
  final String? initialExpandedTaskId;

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage>
    with
        SingleTickerProviderStateMixin,
        _TaskCardCommon,
        _ModelDownloadTaskCard,
        _FollowUpdateTaskCard,
        _PreTranslationTaskCard,
        _HistoryRefreshTaskCard,
        _RelatedSourceTaskCard,
        _SourceMigrationTaskCard,
        _ComicSourceUpdateTaskCard,
        _ImportTaskCard,
        _ExportTaskCard,
        _WebdavMigrationTaskCard,
        _DataSyncTaskCard {
  @override
  final followUpdateManager = FollowUpdateTaskManager.instance;
  @override
  final historyRefreshManager = HistoryRefreshTaskManager.instance;
  @override
  final relatedSourceManager = RelatedSourceTaskManager.instance;
  @override
  final sourceMigrationManager = SourceMigrationTaskManager.instance;
  @override
  final comicSourceUpdateManager = ComicSourceUpdateTaskManager.instance;
  @override
  final importManager = ImportTaskManager.instance;
  @override
  final exportManager = ExportTaskManager.instance;
  @override
  final webdavMigrationManager = WebdavMigrationTaskManager.instance;
  final dataSyncManager = DataSyncTaskManager.instance;
  @override
  final modelStore = TranslationModelStore.instance;
  @override
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
    webdavMigrationManager.addListener(update);
    dataSyncManager.addListener(update);
    modelStore.addListener(update);
    preTranslationManager.addListener(update);
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
    webdavMigrationManager.removeListener(update);
    dataSyncManager.removeListener(update);
    modelStore.removeListener(update);
    preTranslationManager.removeListener(update);
    super.dispose();
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
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
              webdavMigrationManager.clearHistory();
              preTranslationManager.clearHistory();
              Navigator.pop(context);
            },
            child: Text("Delete".tl),
          ),
        ],
      ),
    );
  }

  /// Remove task by type and id
  @override
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
      case 'webdav_migration':
        webdavMigrationManager.removeTask(id);
      case 'pre_translate':
        preTranslationManager.removeTask(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _buildTaskEntries(history: false);
    final history = _buildTaskEntries(history: true);
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        cardTheme: theme.cardTheme.copyWith(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        expansionTileTheme: theme.expansionTileTheme.copyWith(
          shape: const Border(),
          collapsedShape: const Border(),
        ),
      ),
      child: Scaffold(
        backgroundColor: theme.colorScheme.surfaceContainerLowest,
        appBar: Appbar(title: Text("Tasks".tl)),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1040),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: AppTabBar(
                        controller: _tabController,
                        tabs: [
                          Tab(text: "${'Current'.tl} (${current.length})"),
                          Tab(text: "${'History'.tl} (${history.length})"),
                        ],
                      ),
                    ),
                    if (_tabController.index == 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: IconButton(
                          icon: const Icon(Icons.delete_sweep_outlined),
                          tooltip: "Clear History".tl,
                          onPressed: history.isNotEmpty
                              ? _clearAllHistory
                              : null,
                        ),
                      ),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      TaskListView(
                        key: const PageStorageKey('current-tasks'),
                        entries: current,
                        emptyText: "No current tasks".tl,
                        emptyIcon: Icons.task_alt_rounded,
                      ),
                      TaskListView(
                        key: const PageStorageKey('history-tasks'),
                        entries: history,
                        emptyText: "No task history".tl,
                        emptyIcon: Icons.history_rounded,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<TaskListEntry> _buildTaskEntries({required bool history}) {
    final entries = <TaskListEntry>[
      for (final task
          in history
              ? dataSyncManager.historyTasks
              : dataSyncManager.currentTasks)
        TaskListEntry(
          id: 'data_sync:${task.id}',
          title: task.fileName ?? '',
          category: 'Data & Sync',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildDataSyncTaskCard(task, expanded: false),
        ),
      for (final task
          in history
              ? followUpdateManager.historyTasks
              : followUpdateManager.currentTasks)
        TaskListEntry(
          id: 'follow_update:${task.id}',
          title: task.folderLabel,
          category: 'Follow Updates',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildFollowUpdateTaskCard(
            task,
            expanded: !history && task.id == widget.initialExpandedTaskId,
          ),
        ),
      for (final task
          in history
              ? historyRefreshManager.historyTasks
              : historyRefreshManager.currentTasks)
        TaskListEntry(
          id: 'history_refresh:${task.id}',
          title: '',
          category: 'History Refresh',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildHistoryRefreshTaskCard(task, expanded: false),
        ),
      for (final task
          in history
              ? relatedSourceManager.historyTasks
              : relatedSourceManager.currentTasks)
        TaskListEntry(
          id: 'related_source:${task.id}',
          title: task.folder,
          category: 'Auto Link Sources',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildRelatedSourceTaskCard(task, expanded: false),
        ),
      for (final task
          in history
              ? sourceMigrationManager.historyTasks
              : sourceMigrationManager.currentTasks)
        TaskListEntry(
          id: 'source_migration:${task.id}',
          title: task.folder,
          category: 'Source Migration',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildSourceMigrationTaskCard(task, expanded: false),
        ),
      for (final task
          in history
              ? comicSourceUpdateManager.historyTasks
              : comicSourceUpdateManager.currentTasks)
        TaskListEntry(
          id: 'comic_source_update:${task.id}',
          title: '',
          category: 'Update Sources',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildComicSourceUpdateTaskCard(task, expanded: false),
        ),
      for (final task
          in history ? importManager.historyTasks : importManager.currentTasks)
        TaskListEntry(
          id: 'import:${task.id}',
          title: task.fileName,
          category: 'Import Data',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildImportTaskCard(task, expanded: false),
        ),
      for (final task
          in history ? exportManager.historyTasks : exportManager.currentTasks)
        TaskListEntry(
          id: 'export:${task.id}',
          title: task.currentTitle ?? '',
          category: 'Export Comics',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildExportTaskCard(task, expanded: false),
        ),
      for (final task
          in history
              ? webdavMigrationManager.historyTasks
              : webdavMigrationManager.currentTasks)
        TaskListEntry(
          id: 'webdav_migration:${task.id}',
          title: task.currentTitle ?? '',
          category: 'WebDAV Migration',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildWebdavMigrationTaskCard(task, expanded: false),
        ),
      for (final task
          in history
              ? preTranslationManager.historyTasks
              : preTranslationManager.currentTasks)
        TaskListEntry(
          id: 'pre_translate:${task.id}',
          title: task.title,
          category: 'Pre-translate',
          status: task.status.name,
          time: history ? task.finishedAt ?? task.createdAt : task.createdAt,
          builder: (_) => buildPreTranslateTaskCard(task, expanded: false),
        ),
      if (!history)
        for (final component in TranslationModels.all)
          if (modelStore.stateOf(component).downloading)
            TaskListEntry(
              id: 'model:${component.id}',
              title: translationModelName(component.id),
              category: 'Translation models',
              status: 'running',
              time: DateTime(0),
              builder: (_) => buildModelDownloadCard(component),
            ),
    ];
    if (history) entries.sort((a, b) => b.time.compareTo(a.time));
    return entries;
  }
}

/// Keeps task actions from squeezing the title on phones and large text.
class _TaskExpansionTile extends StatelessWidget {
  const _TaskExpansionTile({
    required this.initiallyExpanded,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.children,
  });

  final bool initiallyExpanded;
  final Widget leading;
  final Widget title;
  final Widget subtitle;
  final Widget? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stackedActions = constraints.maxWidth < 520 ||
          MediaQuery.textScalerOf(context).scale(14) > 20;
      final actions = trailing;
      return ExpansionTile(
        initiallyExpanded: initiallyExpanded,
        leading: leading,
        title: title,
        subtitle: stackedActions && trailing != null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  subtitle,
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: actions is Row
                        ? Wrap(alignment: WrapAlignment.end, children: actions.children)
                        : actions,
                  ),
                ],
              )
            : subtitle,
        trailing: stackedActions ? null : trailing,
        children: children,
      );
    },
  );
}

/// Rotating icon widget with proper animation controller.
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

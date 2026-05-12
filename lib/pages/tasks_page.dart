import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_source_update_tasks.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/foundation/history_tasks.dart';
import 'package:venera/foundation/related_source_tasks.dart';
import 'package:venera/foundation/source_migration_tasks.dart';
import 'package:venera/foundation/widget_utils.dart';
import 'package:venera/utils/translations.dart';

class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  final followUpdateManager = FollowUpdateTaskManager.instance;
  final historyRefreshManager = HistoryRefreshTaskManager.instance;
  final relatedSourceManager = RelatedSourceTaskManager.instance;
  final sourceMigrationManager = SourceMigrationTaskManager.instance;
  final comicSourceUpdateManager = ComicSourceUpdateTaskManager.instance;

  @override
  void initState() {
    super.initState();
    followUpdateManager.addListener(update);
    historyRefreshManager.addListener(update);
    relatedSourceManager.addListener(update);
    sourceMigrationManager.addListener(update);
    comicSourceUpdateManager.addListener(update);
  }

  @override
  void dispose() {
    followUpdateManager.removeListener(update);
    historyRefreshManager.removeListener(update);
    relatedSourceManager.removeListener(update);
    sourceMigrationManager.removeListener(update);
    comicSourceUpdateManager.removeListener(update);
    super.dispose();
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Tasks".tl)),
      body: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Material(
              child: AppTabBar(
                tabs: [
                  Tab(text: "Current".tl),
                  Tab(text: "History".tl),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [buildCurrentTasks(), buildHistoryTasks()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildCurrentTasks() {
    var widgets = <Widget>[
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
    ];
    return buildTaskWidgets(widgets, "No current tasks".tl);
  }

  Widget buildHistoryTasks() {
    var widgets = <Widget>[
      ...followUpdateManager.historyTasks.map(
        (task) => buildFollowUpdateTaskCard(task, expanded: false),
      ),
      ...historyRefreshManager.historyTasks.map(
        (task) => buildHistoryRefreshTaskCard(task, expanded: false),
      ),
      ...relatedSourceManager.historyTasks.map(
        (task) => buildRelatedSourceTaskCard(task, expanded: false),
      ),
      ...sourceMigrationManager.historyTasks.map(
        (task) => buildSourceMigrationTaskCard(task, expanded: false),
      ),
      ...comicSourceUpdateManager.historyTasks.map(
        (task) => buildComicSourceUpdateTaskCard(task, expanded: false),
      ),
    ];
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

  Widget buildFollowUpdateTaskCard(
    FollowUpdateTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: Icon(task.isRunning ? Icons.sync : Icons.history),
        title: Text(
          "Checking updates: @folder".tlParams({'folder': task.folder}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            task.manual ? "Manual".tl : "Automatic".tl,
            followUpdateStatusText(task),
            progressText,
          ].join(" · "),
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
  }

  Widget buildHistoryRefreshTaskCard(
    HistoryRefreshTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: Icon(task.isRunning ? Icons.manage_history : Icons.history),
        title: Text("Refreshing histories".tl),
        subtitle: Text(
          [historyRefreshStatusText(task), progressText].join(" · "),
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
  }

  Widget buildRelatedSourceTaskCard(
    RelatedSourceTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: Icon(task.isRunning ? Icons.hub_outlined : Icons.history),
        title: Text(
          "Auto linking sources: @folder".tlParams({'folder': task.folder}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [relatedSourceStatusText(task), progressText].join(" · "),
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
  }

  Widget buildSourceMigrationTaskCard(
    SourceMigrationTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: Icon(task.isRunning ? Icons.move_up_outlined : Icons.history),
        title: Text(
          "Migrating sources: @folder".tlParams({'folder': task.folder}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [sourceMigrationStatusText(task), progressText].join(" · "),
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
  }

  Widget buildComicSourceUpdateTaskCard(
    ComicSourceUpdateTask task, {
    required bool expanded,
  }) {
    var progressText = task.total == 0
        ? "0%"
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    return Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        initiallyExpanded: expanded,
        leading: Icon(task.isRunning ? Icons.update : Icons.history),
        title: Text(
          "Updating comic sources".tl,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [comicSourceUpdateStatusText(task), progressText].join(" · "),
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
}

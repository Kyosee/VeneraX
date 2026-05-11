import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/foundation/history_tasks.dart';
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

  @override
  void initState() {
    super.initState();
    followUpdateManager.addListener(update);
    historyRefreshManager.addListener(update);
  }

  @override
  void dispose() {
    followUpdateManager.removeListener(update);
    historyRefreshManager.removeListener(update);
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
        (task) => buildFollowUpdateTaskCard(task, expanded: true),
      ),
      ...historyRefreshManager.currentTasks.map(
        (task) => buildHistoryRefreshTaskCard(task, expanded: true),
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

  Widget buildSourceBox({required List<Widget> children}) {
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
          Text("By comic source".tl, style: ts.s16),
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
}

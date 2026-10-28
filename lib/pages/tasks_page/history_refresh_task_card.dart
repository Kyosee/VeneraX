part of '../tasks_page.dart';

mixin _HistoryRefreshTaskCard on _TaskCardCommon {
  HistoryRefreshTaskManager get historyRefreshManager;

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
      child: _TaskExpansionTile(
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

  String historyRefreshStatusText(HistoryRefreshTask task) {
    return switch (task.status) {
      HistoryRefreshTaskStatus.running => "Running".tl,
      HistoryRefreshTaskStatus.completed => "Completed".tl,
      HistoryRefreshTaskStatus.canceled => "Canceled".tl,
      HistoryRefreshTaskStatus.failed => "Failed".tl,
    };
  }
}

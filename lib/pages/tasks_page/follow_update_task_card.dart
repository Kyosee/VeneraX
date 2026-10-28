part of '../tasks_page.dart';

mixin _FollowUpdateTaskCard on _TaskCardCommon {
  FollowUpdateTaskManager get followUpdateManager;

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
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('follow_update', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
getTaskTitle('follow_update', {'folder': task.folderLabel}),
          maxLines: 2,
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

  String followUpdateStatusText(FollowUpdateTask task) {
    return switch (task.status) {
      FollowUpdateTaskStatus.running => "Running".tl,
      FollowUpdateTaskStatus.completed => "Completed".tl,
      FollowUpdateTaskStatus.canceled => "Canceled".tl,
      FollowUpdateTaskStatus.failed => "Failed".tl,
    };
  }
}

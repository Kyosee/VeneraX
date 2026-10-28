part of '../tasks_page.dart';

mixin _ComicSourceUpdateTaskCard on _TaskCardCommon {
  ComicSourceUpdateTaskManager get comicSourceUpdateManager;

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
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('comic_source_update', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
getTaskTitle('comic_source_update', {}),
          maxLines: 2,
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
}

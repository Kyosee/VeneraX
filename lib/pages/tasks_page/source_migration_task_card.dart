part of '../tasks_page.dart';

mixin _SourceMigrationTaskCard on _TaskCardCommon {
  SourceMigrationTaskManager get sourceMigrationManager;

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
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('source_migration', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
getTaskTitle('source_migration', {'folder': task.folder}),
          maxLines: 2,
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

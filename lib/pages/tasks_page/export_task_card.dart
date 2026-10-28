part of '../tasks_page.dart';

mixin _ExportTaskCard on _TaskCardCommon {
  ExportTaskManager get exportManager;

  Widget buildExportTaskCard(ExportTask task, {required bool expanded}) {
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
          getTaskIcon('export', task.isActive, status: task.status.name),
          task.isActive,
          task.status.name,
        ),
        title: Text(
getTaskTitle('export', {}),
          maxLines: 2,
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
}

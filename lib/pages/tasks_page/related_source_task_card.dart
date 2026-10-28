part of '../tasks_page.dart';

mixin _RelatedSourceTaskCard on _TaskCardCommon {
  RelatedSourceTaskManager get relatedSourceManager;

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
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('related_source', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
getTaskTitle('related_source', {'folder': task.folder}),
          maxLines: 2,
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

  String relatedSourceStatusText(RelatedSourceTask task) {
    return switch (task.status) {
      RelatedSourceTaskStatus.running => "Running".tl,
      RelatedSourceTaskStatus.paused => "Paused".tl,
      RelatedSourceTaskStatus.completed => "Completed".tl,
      RelatedSourceTaskStatus.canceled => "Canceled".tl,
      RelatedSourceTaskStatus.failed => "Failed".tl,
    };
  }
}

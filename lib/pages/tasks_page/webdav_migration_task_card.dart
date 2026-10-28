part of '../tasks_page.dart';

mixin _WebdavMigrationTaskCard on _TaskCardCommon {
  WebdavMigrationTaskManager get webdavMigrationManager;

  static const _webdavMigrationFailurePreviewLimit = 20;

  Widget buildWebdavMigrationTaskCard(
    WebdavMigrationTask task, {
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
          getTaskIcon('webdav_migration', task.isActive,
              status: task.status.name),
          task.isActive,
          task.status.name,
        ),
        title: Text(
getTaskTitle('webdav_migration', {}),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [
            webdavMigrationStatusText(task),
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
                      onPressed: () => webdavMigrationManager.resume(task.id),
                      child: Text("Resume".tl),
                    )
                  else
                    TextButton(
                      onPressed: () => webdavMigrationManager.pause(task.id),
                      child: Text("Pause".tl),
                    ),
                  TextButton(
                    onPressed: () => webdavMigrationManager.cancel(task.id),
                    child: Text("Cancel".tl),
                  ),
                ],
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: _webdavMigrationBarValue(task),
            ),
          ),
          const SizedBox(height: 8),
          buildWebdavMigrationDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(
        card, 'webdav_migration', task.id, task.isRunning);
  }

  /// Bar value: the current comic's byte-fraction while a comic is uploading,
  /// else the per-comic ratio; indeterminate when running with nothing sized.
  double? _webdavMigrationBarValue(WebdavMigrationTask task) {
    if (task.isRunning && task.currentComicProgress != null) {
      return task.currentComicProgress;
    }
    return task.isRunning && task.total == 0 ? null : task.progress;
  }

  String webdavMigrationStatusText(WebdavMigrationTask task) {
    return switch (task.status) {
      WebdavMigrationStatus.running => "Running".tl,
      WebdavMigrationStatus.paused => "Paused".tl,
      WebdavMigrationStatus.completed when task.failedCount > 0 =>
        "Completed with failures".tl,
      WebdavMigrationStatus.completed => "Completed".tl,
      WebdavMigrationStatus.canceled => "Canceled".tl,
      WebdavMigrationStatus.failed => "Failed".tl,
    };
  }

  String webdavMigrationFailureReasonText(
    WebdavMigrationFailureReason reason,
  ) {
    return switch (reason) {
      WebdavMigrationFailureReason.comicUnavailable =>
        "Local comic is no longer available".tl,
      WebdavMigrationFailureReason.directoryMissing =>
        "Local files directory is missing".tl,
      WebdavMigrationFailureReason.noImages =>
        "No readable images were found".tl,
      WebdavMigrationFailureReason.readFailed =>
        "Failed to read local files".tl,
      WebdavMigrationFailureReason.uploadFailed =>
        "Failed to upload files".tl,
      WebdavMigrationFailureReason.unknown => "Migration failed".tl,
    };
  }

  String webdavMigrationFailureText(WebdavMigrationFailure failure) {
    final reason = webdavMigrationFailureReasonText(failure.reason);
    final chapter = failure.chapterTitle;
    return chapter == null || chapter.isEmpty
        ? '${failure.comicTitle}: $reason'
        : '${failure.comicTitle} - $chapter: $reason';
  }

  Map<String, List<WebdavMigrationFailure>> _groupWebdavMigrationFailures(
    List<WebdavMigrationFailure> failures,
  ) {
    final grouped = <String, List<WebdavMigrationFailure>>{};
    for (final failure in failures) {
      (grouped[failure.comicKey] ??= []).add(failure);
    }
    return grouped;
  }

  Future<void> _copyWebdavMigrationFailures(
    WebdavMigrationTask task,
  ) async {
    final details = task.failures.map(webdavMigrationFailureText).join('\n');
    try {
      await Clipboard.setData(ClipboardData(text: details));
      if (!mounted) return;
      context.showMessage(message: "Failure details copied".tl);
    } catch (_) {
      if (!mounted) return;
      context.showMessage(message: "Failed to copy failure details".tl);
    }
  }

  Widget buildWebdavMigrationDetails(WebdavMigrationTask task) {
    final visibleFailures = task.failures
        .take(_webdavMigrationFailurePreviewLimit)
        .toList();
    final hiddenFailureCount = task.failures.length - visibleFailures.length;
    return buildSourceBox(
      title: "Details".tl,
      children: [
        Text(
          "Total: @total  Migrated: @done  Failed: @failed".tlParams({
            'total': task.total,
            'done': task.done - task.failedCount - task.skippedCount < 0
                ? 0
                : task.done - task.failedCount - task.skippedCount,
            'failed': task.failedCount,
          }),
          style: ts.s14,
        ),
        if (task.skippedCount > 0) ...[
          const SizedBox(height: 2),
          Text(
            "Skipped (already in the library): @n".tlParams({
              'n': task.skippedCount,
            }),
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
        ],
        if (task.currentTitle != null && task.isRunning) ...[
          const SizedBox(height: 2),
          Text(
            "Uploading: @title".tlParams({'title': task.currentTitle!}),
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (task.failures.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 18,
                color: context.colorScheme.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  "Failed items".tl,
                  style: ts.s14.withColor(context.colorScheme.error),
                ),
              ),
              Tooltip(
                message: "Copy failure details".tl,
                child: IconButton(
                  onPressed: () => _copyWebdavMigrationFailures(task),
                  icon: const Icon(Icons.copy, size: 18),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
              ),
            ],
          ),
          ..._groupWebdavMigrationFailures(visibleFailures).values.map(
            (failures) => Padding(
              padding: const EdgeInsets.only(left: 24, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    failures.first.comicTitle,
                    style: ts.s14,
                  ),
                  ...failures.map((failure) {
                    final reason =
                        webdavMigrationFailureReasonText(failure.reason);
                    final chapter = failure.chapterTitle;
                    return Padding(
                      padding: const EdgeInsets.only(left: 12, top: 2),
                      child: SelectableText(
                        chapter == null || chapter.isEmpty
                            ? reason
                            : '$chapter: $reason',
                        style: ts.s12.withColor(
                          context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          if (hiddenFailureCount > 0)
            Padding(
              padding: const EdgeInsets.only(left: 24, top: 6),
              child: Text(
                "@count more failure items; copy details to view all".tlParams({
                  'count': hiddenFailureCount,
                }),
                style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
        if (task.status == WebdavMigrationStatus.failed &&
            task.error != null &&
            task.failures.isEmpty) ...[
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

part of '../tasks_page.dart';

mixin _ImportTaskCard on _TaskCardCommon {
  ImportTaskManager get importManager;

  Widget buildImportTaskCard(ImportTask task, {required bool expanded}) {
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon('import', task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
getTaskTitle('import', {'file': task.fileName}),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [importStatusText(task), importPhaseText(task)],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: importManager.isCancelable(task)
            ? TextButton(
                onPressed: () => importManager.cancel(task.id),
                child: Text("Cancel".tl),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning ? task.indicatorValue : 1.0,
            ),
          ),
          const SizedBox(height: 8),
          buildImportDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, 'import', task.id, task.isRunning);
  }

  String importStatusText(ImportTask task) {
    return switch (task.status) {
      ImportTaskStatus.running => "Running".tl,
      ImportTaskStatus.completed => "Completed".tl,
      ImportTaskStatus.canceled => "Canceled".tl,
      ImportTaskStatus.failed => "Failed".tl,
    };
  }

  String importPhaseText(ImportTask task) {
    if (task.phase == ImportPhase.extracting) {
      if (task.extractedBytes <= 0) return "Extracting".tl;
      return "Extracted @size".tlParams({
        'size': bytesToReadableString(task.extractedBytes),
      });
    }
    var key = task.phase == ImportPhase.applying && task.message != null
        ? task.message!
        : importPhaseLabelKey(task.phase);
    return key.tl;
  }

  Widget buildImportDetails(ImportTask task) {
    return buildSourceBox(
      title: "Details".tl,
      children: [
        Text(
          "File: @file".tlParams({
            'file': task.fileName.isEmpty ? '-' : task.fileName,
          }),
          style: ts.s14,
        ),
        if (task.fileSize > 0) ...[
          const SizedBox(height: 2),
          Text(
            "Size: @size".tlParams({
              'size': bytesToReadableString(task.fileSize),
            }),
            style: ts.s14,
          ),
        ],
        const SizedBox(height: 2),
        Text(
          "Status: @status".tlParams({'status': importPhaseText(task)}),
          style: ts.s14,
        ),
        if (task.status == ImportTaskStatus.failed && task.error != null) ...[
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

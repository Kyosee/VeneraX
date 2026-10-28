part of '../tasks_page.dart';

mixin _DataSyncTaskCard on _TaskCardCommon {
  Widget buildDataSyncTaskCard(DataSyncTask task, {required bool expanded}) {
    var progressText = "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final taskType = task.type == DataSyncTaskType.upload
        ? 'data_sync_upload'
        : 'data_sync_download';

    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon(taskType, task.isRunning, status: task.status.name),
          task.isRunning,
          task.status.name,
        ),
        title: Text(
getTaskTitle(taskType, {}),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: buildTaskSubtitle(
          [
            dataSyncStatusText(task),
            if (task.currentPhase != null) task.currentPhase!.tl,
            progressText,
          ],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: null, // WebDAV sync cannot be canceled mid-operation
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning ? task.progress : 1.0,
            ),
          ),
          const SizedBox(height: 8),
          buildDataSyncDetails(task),
        ],
      ),
    );

    return _wrapHistoryCard(card, taskType, task.id, task.isRunning);
  }

  String dataSyncStatusText(DataSyncTask task) {
    return switch (task.status) {
      DataSyncTaskStatus.running => "Running".tl,
      DataSyncTaskStatus.completed => "Completed".tl,
      DataSyncTaskStatus.failed => "Failed".tl,
      DataSyncTaskStatus.canceled => "Canceled".tl,
    };
  }

  Widget buildDataSyncDetails(DataSyncTask task) {
    return buildSourceBox(
      title: "Details".tl,
      children: [
        Text(
          "Type: @type".tlParams({
            'type': (task.type == DataSyncTaskType.upload ? 'Upload' : 'Download').tl,
          }),
          style: ts.s14,
        ),
        if (task.fileName != null) ...[
          const SizedBox(height: 2),
          Text(
            "File: @file".tlParams({'file': task.fileName!}),
            style: ts.s14,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (task.fileSize != null && task.fileSize! > 0) ...[
          const SizedBox(height: 2),
          Text(
            "Size: @size".tlParams({
              'size': bytesToReadableString(task.fileSize!),
            }),
            style: ts.s14,
          ),
        ],
        if (task.currentPhase != null) ...[
          const SizedBox(height: 2),
          Text(
            "Phase: @phase".tlParams({'phase': task.currentPhase!.tl}),
            style: ts.s14,
          ),
        ],
        if (task.status == DataSyncTaskStatus.failed && task.error != null) ...[
          const SizedBox(height: 2),
          Text(
            task.error!,
            style: ts.s14.withColor(context.colorScheme.error),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

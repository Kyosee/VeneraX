part of '../tasks_page.dart';

mixin _TaskCardCommon on State<TasksPage> {
  void _removeTask(String taskType, String id);

  /// Wrap history task card with Dismissible for swipe-to-delete
  Widget _wrapHistoryCard(
    Widget card,
    String taskType,
    String taskId,
    bool isRunning,
  ) {
    if (isRunning) return card;

    return Dismissible(
      key: Key('${taskType}_$taskId'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => _removeTask(taskType, taskId),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: context.colorScheme.errorContainer,
        child: Icon(
          Icons.delete_outline,
          color: context.colorScheme.onErrorContainer,
        ),
      ),
      child: card,
    );
  }

  /// Wrap icon with rotation animation for running tasks
  Widget _wrapIconWithRotation(IconData icon, bool isRunning, String? status) {
    if (isRunning && status != 'paused') {
      return _RotatingIcon(icon: icon);
    }
    return Icon(icon);
  }

  Widget buildTaskSubtitle(
    List<String> parts,
    DateTime createdAt,
    DateTime? finishedAt,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 任务状态和进度信息使用自适应布局
        LayoutBuilder(
          builder: (context, constraints) {
            // 在窄屏幕上每行显示更少信息，避免省略号
            final displayParts = constraints.maxWidth < 300
                ? parts.take(2).toList()
                : parts;
            return Text(
              displayParts.join(" · "),
              maxLines: constraints.maxWidth < 250 ? 2 : 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
        const SizedBox(height: 2),
        // 时间信息使用更紧凑的格式
        LayoutBuilder(
          builder: (context, constraints) {
            final timeText = constraints.maxWidth < 400
                ? taskTimeTextCompact(createdAt, finishedAt)
                : taskTimeText(createdAt, finishedAt);
            return Text(
              timeText,
              maxLines: constraints.maxWidth < 300 ? 2 : 1,
              overflow: TextOverflow.ellipsis,
              style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
            );
          },
        ),
      ],
    );
  }

  String taskTimeText(DateTime createdAt, DateTime? finishedAt) {
    return [
      "Start Time: @time".tlParams({'time': formatTaskTime(createdAt)}),
      "End Time: @time".tlParams({
        'time': finishedAt == null ? '-' : formatTaskTime(finishedAt),
      }),
    ].join(" · ");
  }

  String taskTimeTextCompact(DateTime createdAt, DateTime? finishedAt) {
    return [
      "Start: @time".tlParams({'time': formatTaskTimeCompact(createdAt)}),
      if (finishedAt != null)
        "End: @time".tlParams({'time': formatTaskTimeCompact(finishedAt)}),
    ].join("\n");
  }

  String formatTaskTime(DateTime time) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(time);
  }

  String formatTaskTimeCompact(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inDays == 0) {
      return DateFormat('HH:mm:ss').format(time);
    } else if (diff.inDays < 7) {
      return DateFormat('MM-dd HH:mm').format(time);
    }
    return DateFormat('yyyy-MM-dd').format(time);
  }

  /// 统一的任务图标获取方法
  IconData getTaskIcon(String taskType, bool isRunning, {String? status}) {
    // 优先检查状态（包括运行中可能的 paused 状态）
    if (status == 'paused') return Icons.pause_circle_outline;
    if (status == 'completed') return Icons.check_circle_outline;
    if (status == 'failed') return Icons.error_outline;
    if (status == 'canceled') return Icons.cancel_outlined;

    // 运行中的任务根据类型显示图标
    if (isRunning) {
      return switch (taskType) {
        'follow_update' => Icons.sync,
        'history_refresh' => Icons.manage_history,
        'related_source' => Icons.hub_outlined,
        'source_migration' => Icons.move_up_outlined,
        'comic_source_update' => Icons.update,
        'import' => Icons.cloud_download,
        'export' => Icons.save_alt,
        'webdav_migration' => Icons.cloud_upload_outlined,
        'data_sync_upload' => Icons.cloud_upload,
        'data_sync_download' => Icons.cloud_download,
        'pre_translate' => Icons.translate,
        _ => Icons.task,
      };
    }

    // 其他历史任务
    return Icons.history;
  }

  /// 统一的任务标题格式：[功能类型] 描述
  String getTaskTitle(String taskType, Map<String, Object> params) {
    return switch (taskType) {
      'follow_update' => "Follow Update: @folder".tlParams(params),
      'history_refresh' => "History Refresh".tl,
      'related_source' => "Auto Link Sources: @folder".tlParams(params),
      'source_migration' => "Source Migration: @folder".tlParams(params),
      'comic_source_update' => "Update Sources".tl,
      'import' => params['file']?.toString().isEmpty ?? true
          ? "Import Data".tl
          : "Import: @file".tlParams(params),
      'export' => "Export Comics".tl,
      'webdav_migration' => "WebDAV Migration".tl,
      'data_sync_upload' => "WebDAV Upload".tl,
      'data_sync_download' => "WebDAV Download".tl,
      'pre_translate' => "Pre-translate: @title".tlParams(params),
      _ => taskType,
    };
  }

  Widget buildSourceBox({
    required List<Widget> children,
    String? title,
    Widget? titleTrailing,
  }) {
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
          Row(
            children: [
              Expanded(child: Text(title ?? "By comic source".tl, style: ts.s16)),
              if (titleTrailing != null) titleTrailing,
            ],
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

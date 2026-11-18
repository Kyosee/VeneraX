part of '../tasks_page.dart';

/// Status of the whole download queue, in task-list terms.
String _comicDownloadStatus(List<DownloadTask> tasks) {
  if (tasks.any((t) => !t.isPaused && !t.isError)) return 'running';
  if (tasks.any((t) => t.isError)) return 'failed';
  return 'paused';
}

String _comicDownloadTitles(List<DownloadTask> tasks) =>
    tasks.map((t) => t.title).join('\n');

/// Relays progress from every queued download. Tasks report progress on
/// their own notifiers; [LocalManager] only notifies when the queue changes.
class _DownloadQueueListener extends ChangeNotifier {
  _DownloadQueueListener() {
    LocalManager().addListener(_onQueueChanged);
    _follow();
  }

  var _tasks = <DownloadTask>[];

  void _follow() {
    for (final t in _tasks) {
      t.removeListener(notifyListeners);
    }
    _tasks = List.of(LocalManager().downloadingTasks);
    for (final t in _tasks) {
      t.addListener(notifyListeners);
    }
  }

  void _onQueueChanged() {
    _follow();
    notifyListeners();
  }

  @override
  void dispose() {
    LocalManager().removeListener(_onQueueChanged);
    for (final t in _tasks) {
      t.removeListener(notifyListeners);
    }
    super.dispose();
  }
}

mixin _ComicDownloadTaskCard on _TaskCardCommon {
  _DownloadQueueListener get downloadQueue;

  /// One card for the whole queue; tapping opens the download manager, which
  /// holds the per-comic controls. Rebuilds on its own so per-image progress
  /// does not rebuild the page.
  Widget buildComicDownloadCard() => ListenableBuilder(
    listenable: downloadQueue,
    builder: (context, _) {
      final tasks = LocalManager().downloadingTasks;
      if (tasks.isEmpty) return const SizedBox.shrink();
      final status = _comicDownloadStatus(tasks);
      final running = status == 'running';
      final head = switch (status) {
        'running' => tasks.firstWhere((t) => !t.isPaused && !t.isError),
        'failed' => tasks.firstWhere((t) => t.isError),
        _ => tasks.first,
      };
      var speed = 0;
      for (final t in tasks) {
        if (!t.isPaused && !t.isError) speed += t.speed;
      }
      final details = [
        if (head.message.isNotEmpty) head.message,
        if (tasks.length > 1) "@c tasks".tlParams({'c': tasks.length}),
        if (speed > 0) "${bytesToReadableString(speed)}/s",
      ].join(" · ");
      final progress = head.progress.clamp(0.0, 1.0);
      return Card(
        elevation: 0,
        color: context.colorScheme.surface,
        margin: const EdgeInsets.only(bottom: 8),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          onTap: () => showPopUpWidget(context, const DownloadingPage()),
          leading: _wrapIconWithRotation(
            getTaskIcon('comic_download', running, status: status),
            running,
            status,
          ),
          title: Text(
            getTaskTitle('comic_download', {'title': head.title}),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                details,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: head.isError
                    ? TextStyle(color: context.colorScheme.error)
                    : null,
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                // Indeterminate only while it is actually working.
                value: running && progress == 0 ? null : progress,
              ),
            ],
          ),
          trailing: const Icon(Icons.chevron_right),
        ),
      );
    },
  );
}

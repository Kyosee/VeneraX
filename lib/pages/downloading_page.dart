import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/download_keepalive.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// Human-readable estimated time remaining, e.g. "45s", "5m 30s", "1h 5m".
String _formatEta(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  if (h > 0) return "${h}h ${m}m";
  if (m > 0) return "${m}m ${s}s";
  return "${s}s";
}

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  /// Tasks we've attached a listener to, so the aggregate header can reflect
  /// per-second speed/progress across every active download (not just the head).
  final _listened = <DownloadTask>{};

  @override
  void initState() {
    LocalManager().addListener(_onManagerChanged);
    _syncListeners();
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(_onManagerChanged);
    for (final t in _listened) {
      t.removeListener(update);
    }
    _listened.clear();
    super.dispose();
  }

  void _onManagerChanged() {
    _syncListeners();
    update();
  }

  /// Keep our per-task listeners in sync with the current queue contents.
  void _syncListeners() {
    final current = LocalManager().downloadingTasks.toSet();
    for (final t in current.difference(_listened)) {
      t.addListener(update);
    }
    for (final t in _listened.difference(current)) {
      t.removeListener(update);
    }
    _listened
      ..clear()
      ..addAll(current);
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = LocalManager().downloadingTasks;
    return PopUpWidgetScaffold(
      title: "Downloading".tl,
      tailing: [
        MenuButton(
          entries: [
            MenuEntry(
              icon: Icons.pause,
              text: "Pause All".tl,
              onClick: () => LocalManager().pauseAll(),
            ),
            MenuEntry(
              icon: Icons.play_arrow,
              text: "Resume All".tl,
              onClick: () {
                LocalManager().resumeAll();
                DownloadKeepAlive.instance.refresh();
              },
            ),
            MenuEntry(
              icon: Icons.delete_outline,
              text: "Cancel All".tl,
              color: context.colorScheme.error,
              onClick: _confirmCancelAll,
            ),
          ],
        ),
      ],
      body: Column(
        children: [
          _buildHeader(tasks),
          Expanded(
            child: tasks.isEmpty
                ? Center(
                    child: Text(
                      "No downloading tasks".tl,
                      style: ts.s14.copyWith(
                        color: context.colorScheme.outline,
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: tasks.length,
                    onReorder: (oldIndex, newIndex) {
                      LocalManager().reorderTask(oldIndex, newIndex);
                    },
                    itemBuilder: (context, i) {
                      final task = tasks[i];
                      return _DownloadTaskTile(
                        key: ValueKey(task),
                        task: task,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _confirmCancelAll() {
    showDialog(
      context: context,
      builder: (context) => ContentDialog(
        title: "Cancel All".tl,
        content: Text("Cancel all downloading tasks?".tl).paddingHorizontal(16),
        actions: [
          Button.filled(
            color: context.colorScheme.error,
            onPressed: () {
              context.pop();
              LocalManager().cancelAll();
            },
            child: Text("Confirm".tl),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(List<DownloadTask> tasks) {
    // Aggregate the speed of every actively-running task so the header reflects
    // total throughput when several comics download in parallel.
    var speed = 0;
    var active = 0;
    var paused = 0;
    var errored = 0;
    for (final t in tasks) {
      if (t.isError) {
        errored++;
      } else if (t.isPaused) {
        paused++;
      } else {
        active++;
        speed += t.speed;
      }
    }

    String label;
    if (active > 0) {
      label = "${bytesToReadableString(speed)}/s";
    } else if (errored > 0) {
      label = "Error".tl;
    } else if (paused > 0) {
      label = "Paused".tl;
    } else {
      label = "";
    }

    final allPaused = active == 0 && (paused > 0 || errored > 0);

    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Text(label, style: ts.s18.bold),
          const SizedBox(width: 12),
          if (tasks.length > 1)
            Text(
              "@c tasks".tlParams({"c": tasks.length}),
              style: ts.s12.copyWith(color: context.colorScheme.outline),
            ),
          const Spacer(),
          if (tasks.isNotEmpty)
            allPaused
                ? OutlinedButton(
                    onPressed: () {
                      LocalManager().resumeAll();
                      DownloadKeepAlive.instance.refresh();
                    },
                    child: Row(
                      children: [
                        const Icon(Icons.play_arrow, size: 18),
                        const SizedBox(width: 4),
                        Text("Resume All".tl),
                      ],
                    ),
                  )
                : OutlinedButton(
                    onPressed: () => LocalManager().pauseAll(),
                    child: Row(
                      children: [
                        const Icon(Icons.pause, size: 18),
                        const SizedBox(width: 4),
                        Text("Pause All".tl),
                      ],
                    ),
                  ),
        ],
      ).paddingHorizontal(16),
    );
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({required this.task, super.key});

  final DownloadTask task;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      oldWidget.task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    if (mounted) setState(() {});
  }

  /// Trailing status line: ETA + remaining when running, else the task message.
  String _statusLine() {
    final eta = task.eta;
    if (!task.isPaused && !task.isError && eta != null) {
      return "${task.message} · ${"~@t left".tlParams({
            "t": _formatEta(eta),
          })}";
    }
    return task.message;
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    return Container(
      height: 136,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 82,
            height: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: context.colorScheme.primaryContainer,
            ),
            clipBehavior: Clip.antiAlias,
            child: t.cover == null
                ? null
                : Image(
                    image: CachedImageProvider(t.cover!),
                    filterQuality: FilterQuality.medium,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 2,
                      ),
                    ),
                    // Per-task pause / resume / retry.
                    if (t.isError)
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        tooltip: "Retry".tl,
                        onPressed: () => LocalManager().resumeTask(t),
                      )
                    else if (t.isPaused)
                      IconButton(
                        icon: const Icon(Icons.play_arrow, size: 20),
                        tooltip: "Start".tl,
                        onPressed: () => LocalManager().resumeTask(t),
                      )
                    else
                      IconButton(
                        icon: const Icon(Icons.pause, size: 20),
                        tooltip: "Pause".tl,
                        onPressed: () => LocalManager().pauseTask(t),
                      ),
                    MenuButton(
                      entries: [
                        MenuEntry(
                          icon: Icons.close,
                          text: "Cancel".tl,
                          onClick: () => t.cancel(),
                        ),
                        MenuEntry(
                          icon: Icons.vertical_align_top,
                          text: "Move To First".tl,
                          onClick: () => LocalManager().moveToFirst(t),
                        ),
                      ],
                    ),
                  ],
                ),
                const Spacer(),
                Text(
                  _statusLine(),
                  style: ts.s12.copyWith(
                    color: t.isError ? context.colorScheme.error : null,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: t.progress == 0 ? null : t.progress,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/battery_optimization.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import '../foundation/global_state.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/tasks_page.dart';
import 'package:venera/utils/ext.dart';

/// Above this row count the scope is loaded in a background isolate so opening
/// the page doesn't jank the transition. See favorites.dart.
///
/// Going off-thread is not free: it spawns an isolate, opens its own database
/// connection and copies every row back. With the scope able to cover many
/// folders the old 500 tripped almost immediately, so a moderate library paid
/// that on every open AND every refresh. The load itself is ~25ms per 10k rows
/// now that the dedupe happens in SQL, so the bar sits far higher.
const _asyncDataFetchLimit = 4000;

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  void getCount() {
    // A folder that no longer exists is filtered out by the scope rather than
    // clearing the setting: with "all folders" on there is nothing to clear,
    // and a store that is merely still initializing reads as "no folders".
    _count = LocalFavoritesManager().countUpdatesIn(
      FollowUpdateScope.folders(),
    );
  }

  void updateCount() {
    setState(() {
      getCount();
    });
  }

  @override
  void initState() {
    super.initState();
    getCount();
    FollowUpdateTaskManager.instance.addListener(updateCount);
  }

  @override
  void dispose() {
    FollowUpdateTaskManager.instance.removeListener(updateCount);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final updatesText = _count > 0
        ? '@c updates'.tlParams({'c': _count})
        : null;

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Material(
          color: context.colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: context.colorScheme.outlineVariant.toOpacity(0.35),
              width: 0.6,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  context.to(() => FollowUpdatesPage());
                },
                child: SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      Icon(
                        Icons.notifications_active_outlined,
                        size: 20,
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Follow Updates'.tl,
                          style: Theme.of(context).textTheme.titleMedium!
                              .copyWith(fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      if (updatesText != null)
                        Container(
                          constraints: const BoxConstraints(maxWidth: 120),
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(20),
                            color: context.colorScheme.primaryContainer,
                          ),
                          child: Text(
                            updatesText,
                            style: Theme.of(context).textTheme.labelMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 32,
                        height: 56,
                        child: Center(
                          child: Icon(
                            Icons.chevron_right_rounded,
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ).paddingHorizontal(16),
              ),
              const FollowUpdateProgressBar(embedded: true),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

/// A thin progress bar shown while a follow-update check is running. It listens
/// to [FollowUpdateTaskManager] and renders nothing when no task is active.
/// Tapping it opens the tasks page with the running task's card expanded.
///
/// When [embedded] is true it drops its own border/margin so it can sit inside
/// an existing panel (e.g. the home follow-updates card).
class FollowUpdateProgressBar extends StatefulWidget {
  const FollowUpdateProgressBar({super.key, this.embedded = false});

  final bool embedded;

  @override
  State<FollowUpdateProgressBar> createState() =>
      _FollowUpdateProgressBarState();
}

class _FollowUpdateProgressBarState extends State<FollowUpdateProgressBar> {
  @override
  void initState() {
    super.initState();
    FollowUpdateTaskManager.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    FollowUpdateTaskManager.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  FollowUpdateTask? get _runningTask => FollowUpdateTaskManager
      .instance
      .currentTasks
      .where((t) => t.isRunning)
      .firstOrNull;

  @override
  Widget build(BuildContext context) {
    final task = _runningTask;
    if (task == null) {
      return const SizedBox.shrink();
    }
    final indeterminate = task.total == 0;
    final percent = indeterminate
        ? null
        : "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final inner = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        context.to(() => TasksPage(initialExpandedTaskId: task.id));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Checking for updates...".tl,
                    style: ts.s14,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  "@checked/@total".tlParams({
                    'checked': task.checked,
                    'total': task.total,
                  }),
                  style: ts.s12.withColor(
                    Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (percent != null) ...[
                  const SizedBox(width: 8),
                  Text(percent, style: ts.s12),
                ],
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: indeterminate ? null : task.progress,
                minHeight: 4,
              ),
            ),
          ],
        ),
      ),
    );

    // Embedded inside a host panel (home widget): render without its own
    // border/margin so it reads as one panel with the follow-updates entry.
    // A hairline divider separates it from the entry above it.
    if (widget.embedded) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Divider(
            height: 0.6,
            thickness: 0.6,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          inner,
        ],
      );
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: inner,
    );
  }
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  List<String> get folders => FollowUpdateScope.folders();

  bool get isConfigured => FollowUpdateScope.isConfigured;

  var updatedComics = <FavoriteItemWithUpdateInfo>[];
  var completedComics = <FavoriteItemWithUpdateInfo>[];
  var unreadComics = <FavoriteItemWithUpdateInfo>[];
  var allComics = <FavoriteItemWithUpdateInfo>[];

  /// Most recent check across the loaded rows, or null if nothing was ever
  /// checked. Derived with the other lists in [_recomputeDerived].
  DateTime? lastCheckTime;

  bool isLoading = false;

  /// Sort comics by update time in descending order with nulls at the end.
  void sortComics() {
    allComics.sort((a, b) {
      if (a.updateTime == null && b.updateTime == null) {
        return 0;
      } else if (a.updateTime == null) {
        return -1;
      } else if (b.updateTime == null) {
        return 1;
      }
      try {
        var aNums = a.updateTime!.split('-').map(int.parse).toList();
        var bNums = b.updateTime!.split('-').map(int.parse).toList();
        for (int i = 0; i < aNums.length; i++) {
          if (aNums[i] != bNums[i]) {
            return bNums[i] - aNums[i];
          }
        }
        return 0;
      } catch (_) {
        return 0;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // While a check runs, update marks land in the database comic-by-comic,
    // but this page used to reload only when the whole task finished — the
    // home badge counted up while an already-open list stayed stale (#106).
    FollowUpdateTaskManager.instance.addListener(_onTaskProgress);
    final scope = folders;
    if (_rowCountOf(scope) >= _asyncDataFetchLimit) {
      // Large scope: defer + load off the UI thread so the page-push
      // transition isn't blocked. A spinner shows until it's ready.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAsync(scope));
    } else {
      // Small (or unconfigured): load synchronously now — cheap, no flash.
      _loadSync();
    }
  }

  /// Rows across [scope] before dedupe — an upper bound, enough to decide
  /// whether the load needs to go off the UI thread.
  static int _rowCountOf(List<String> scope) {
    final manager = LocalFavoritesManager();
    var total = 0;
    for (final folder in scope) {
      total += manager.folderComics(folder);
    }
    return total;
  }

  @override
  void dispose() {
    _liveRefreshTimer?.cancel();
    FollowUpdateTaskManager.instance.removeListener(_onTaskProgress);
    super.dispose();
  }

  Timer? _liveRefreshTimer;

  /// Reloads the list while a check is writing new update marks, throttled to
  /// once per second (the manager notifies per checked comic). The trailing
  /// timer also picks up the final progress events; a full unconditional
  /// reload still happens on task finish via [updateFollowUpdatesUI].
  void _onTaskProgress() {
    if (_liveRefreshTimer != null) {
      return;
    }
    _liveRefreshTimer = Timer(const Duration(seconds: 1), () {
      _liveRefreshTimer = null;
      if (!mounted) {
        return;
      }
      final scope = folders;
      if (scope.isEmpty) {
        return;
      }
      // Cheap change signal: reload only when the flagged count moved, so an
      // idle notify doesn't re-read and re-sort the whole scope.
      if (LocalFavoritesManager().countUpdatesIn(scope) ==
          updatedComics.length) {
        return;
      }
      if (_rowCountOf(scope) >= _asyncDataFetchLimit) {
        _loadAsync(scope);
      } else {
        setState(_loadSync);
      }
    });
  }

  /// Recompute the cached tab lists from [allComics]. `updated` (has-new-update)
  /// and `completed` (comic status) only change when the folder data reloads, so
  /// they're cached here. `completed` is the expensive filter (status lookup per
  /// item); caching it is the main win. `unread` depends on read history (changes
  /// whenever the user reads a comic), so it is NOT cached — it's recomputed in
  /// build(), where each lookup is O(1) via the history-id cache.
  void _recomputeDerived() {
    updatedComics = allComics.where((c) => c.hasNewUpdate == true).toList();
    completedComics = allComics.where(_isReadCompleted).toList();
    // `unread` and the last-check stamp used to be derived in build(). That was
    // affordable while the scope was one folder, but a scope covering every
    // folder made both a full scan of the library on every frame — and the page
    // rebuilds several times a second while a check runs (#263). Reading a comic
    // routes through updateFollowUpdatesUI(), so recomputing on load stays
    // correct.
    unreadComics = allComics.where(_isUnread).toList();
    lastCheckTime = null;
    for (final comic in allComics) {
      final time = comic.lastCheckDateTime;
      final latest = lastCheckTime;
      if (time != null && (latest == null || time.isAfter(latest))) {
        lastCheckTime = time;
      }
    }
  }

  /// Synchronously (re)load the followed folder and refresh derived lists.
  /// Safe inside initState (assigns fields only); wrap in setState elsewhere.
  void _loadSync() {
    allComics = LocalFavoritesManager().getComicsWithUpdatesInfoIn(folders);
    sortComics();
    _recomputeDerived();
  }

  /// Load [scope] off the UI thread. Always clears [isLoading] when done — on
  /// success, on error (falls back to a sync load), and if the user changed the
  /// scope mid-load (drops the stale result and resyncs to the current one).
  void _loadAsync(List<String> scope) async {
    if (!mounted) return;
    setState(() => isLoading = true);
    List<FavoriteItemWithUpdateInfo>? value;
    try {
      value = await LocalFavoritesManager()
          .getComicsWithUpdatesInfoInAsync(scope)
          .minTime(const Duration(milliseconds: 200));
    } catch (e, s) {
      Log.error("FollowUpdates", "async load failed: $e", s);
    }
    if (!mounted) return;
    if (!listEquals(folders, scope) || value == null) {
      _loadSync();
    } else {
      allComics = value;
      sortComics();
      _recomputeDerived();
    }
    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text('Follow Updates'.tl),
        actions: [
          Tooltip(
            message: "Follow Updates Settings".tl,
            child: IconButton(
              icon: const Icon(Icons.settings_outlined),
              onPressed: showSettings,
            ),
          ),
        ],
      ),
      body: !isConfigured
          ? SmoothCustomScrollView(slivers: [buildNotConfigured(context)])
          : (isLoading && allComics.isEmpty)
          ? const Center(child: CircularProgressIndicator())
          : buildConfiguredTabs(context),
    );
  }

  Widget buildNotConfigured(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text("Not Configured".tl),
            ),
            Text(
              "Open the settings above to pick the folders to follow.".tl,
              style: ts.s16,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: showSettings,
              child: Text("Follow Updates Settings".tl),
            ).paddingHorizontal(16).toAlign(Alignment.centerRight),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Replaces what used to be a plain folder-name row: the scope is now a set,
  /// so the useful thing to show is what the check covers and when it last ran.
  Widget buildSummary(BuildContext context) {
    final scope = folders;
    final last = lastCheckTime;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              children: [
                Icon(
                  FollowUpdateScope.allFolders
                      ? Icons.all_inbox_outlined
                      : Icons.folder_copy_outlined,
                  color: context.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        FollowUpdateScope.allFolders
                            ? "All folders".tl
                            : FollowUpdateScope.describeFolders(scope),
                        style: ts.s14.bold,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "@a comics · @b updates".tlParams({
                          'a': allComics.length,
                          'b': updatedComics.length,
                        }),
                        style: ts.s12.withColor(
                          context.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: scope.isEmpty ? null : checkNow,
                  child: Text("Check Now".tl),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Row(
              children: [
                Icon(
                  Icons.schedule,
                  size: 14,
                  color: context.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    [
                      FollowUpdateScope.describeInterval(
                        FollowUpdateScope.intervalHours,
                      ),
                      last == null
                          ? "Never checked".tl
                          : "Last check: @a".tlParams({
                              'a': _formatCheckTime(last),
                            }),
                    ].join(" · "),
                    style: ts.s12.withColor(
                      context.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const FollowUpdateProgressBar(embedded: true),
        ],
      ),
    );
  }

  static String _formatCheckTime(DateTime time) {
    var text = time.toIso8601String().replaceFirst('T', ' ');
    return text.substring(0, 16);
  }

  Widget buildConfiguredTabs(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          buildSummary(context),
          Material(
            child: AppTabBar(
              tabs: [
                Tab(text: "${"Updates".tl} ${updatedComics.length}"),
                Tab(text: "${"Unread".tl} ${unreadComics.length}"),
                Tab(text: "${"Ended".tl} ${completedComics.length}"),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                buildComicsTab(
                  updatedComics,
                  emptyText: "No updates found".tl,
                  top: buildUpdatedComicsHint(),
                ),
                buildComicsTab(unreadComics, emptyText: "No unread comics".tl),
                buildComicsTab(
                  completedComics,
                  emptyText: "No ended comics".tl,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isReadCompleted(FavoriteItemWithUpdateInfo comic) {
    // Use the tags-only status (no DB lookups): this runs over the whole folder
    // (hundreds of comics) on the UI thread right after the load, so the heavy
    // displayInfoFor() here was the main source of the entry stutter.
    final status = const ComicStateRepository()
        .quickStatusFor(comic)
        ?.trim()
        .toLowerCase();
    if (status == null || status.isEmpty) {
      return false;
    }
    if (status.contains("连载") ||
        status.contains("連載") ||
        status.contains("ongoing")) {
      return false;
    }
    return status.contains("完结") ||
        status.contains("完結") ||
        status.contains("completed") ||
        status.contains("finished") ||
        status.contains("ended");
  }

  bool _isUnread(FavoriteItemWithUpdateInfo comic) {
    return HistoryManager().find(
          comic.id,
          ComicType.fromKey(comic.sourceKey),
        ) ==
        null;
  }

  Widget buildUpdatedComicsHint() {
    if (updatedComics.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        Expanded(
          child: Text(
            "The comic will be marked as no updates as soon as you read it.".tl,
          ).paddingHorizontal(16).paddingVertical(4),
        ),
        IconButton(
          icon: Icon(Icons.done_all),
          onPressed: () {
            showConfirmDialog(
              context: App.rootContext,
              title: "Mark all as read".tl,
              content: "Do you want to mark all as read?".tl,
              onConfirm: () {
                for (var comic in updatedComics) {
                  LocalFavoritesManager().markAsRead(comic.id, comic.type);
                }
                updateFollowUpdatesUI();
                appdata.saveData();
              },
            );
          },
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget buildComicsTab(
    List<FavoriteItemWithUpdateInfo> comics, {
    required String emptyText,
    Widget? top,
  }) {
    return SmoothCustomScrollView(
      slivers: [
        if (top != null) SliverToBoxAdapter(child: top),
        if (comics.isNotEmpty)
          SliverGridComics(comics: comics)
        else
          SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(emptyText, style: ts.s16),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget buildUpdatedComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.update),
                const SizedBox(width: 8),
                Text("Updates".tl, style: ts.s18),
                const Spacer(),
                if (updatedComics.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.done_all),
                    onPressed: () {
                      showConfirmDialog(
                        context: App.rootContext,
                        title: "Mark all as read".tl,
                        content: "Do you want to mark all as read?".tl,
                        onConfirm: () {
                          for (var comic in updatedComics) {
                            LocalFavoritesManager().markAsRead(
                              comic.id,
                              comic.type,
                            );
                          }
                          updateFollowUpdatesUI();
                          appdata.saveData();
                        },
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (updatedComics.isNotEmpty)
          SliverToBoxAdapter(
            child: Text(
              "The comic will be marked as no updates as soon as you read it."
                  .tl,
            ).paddingHorizontal(16).paddingVertical(4),
          ),
        if (updatedComics.isNotEmpty)
          SliverGridComics(comics: updatedComics)
        else
          SliverToBoxAdapter(
            child: Row(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [Text("No updates found".tl, style: ts.s16)],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget buildAllComics() {
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.list),
                const SizedBox(width: 8),
                Text("All Comics".tl, style: ts.s18),
              ],
            ),
          ),
        ),
        SliverGridComics(comics: allComics),
      ],
    );
  }

  /// Opens the follow-updates settings: which folders are followed, and how
  /// often each comic is re-checked. Returns the chosen scope, or null when the
  /// user dismissed the dialog.
  void showSettings() async {
    var applied = await showDialog<_SettingsChoice>(
      context: App.rootContext,
      builder: (context) => const _FollowUpdateSettingsDialog(),
    );
    if (applied == null) {
      return;
    }
    await FollowUpdateScope.saveSchedule(
      intervalHours: applied.intervalHours,
      checkOnStart: applied.checkOnStart,
      fixedTime: applied.fixedTime,
    );
    await applyScope(allFolders: applied.allFolders, folders: applied.folders);
  }

  Future<void> applyScope({
    required bool allFolders,
    required List<String> folders,
  }) async {
    var previous = this.folders.toSet();
    FollowUpdatesService._cancelChecking?.call();
    // Persisted without a sync upload: the scope is device-local, and uploading
    // here could push a transient (pre-check) state over good data on other
    // devices. Real update marks travel with the normal data-change syncs.
    await FollowUpdateScope.save(allFolders: allFolders, folders: folders);
    var next = this.folders;
    // A folder dropped from the scope is an explicit cancellation: its pending
    // resumable check must not come back on the next launch.
    for (final folder in previous) {
      if (!next.contains(folder)) {
        FollowUpdateTaskManager.instance.cancelForFolder(folder);
      }
    }
    // Do NOT clear has_new_update here. Choosing the scope is a configuration
    // action; wiping the flags would discard update marks just synced from
    // another device. Read marks are cleared by the read path, and real new
    // chapters are written by the check itself.
    for (final folder in next) {
      LocalFavoritesManager().prepareTableForFollowUpdates(folder, false);
    }
    // Refreshes this page (via updateComics) as well as the home badge.
    updateFollowUpdatesUI();
    if (next.any((f) => !previous.contains(f))) {
      // Newly followed folders have never been checked; get their first pass
      // going instead of leaving the list empty until the periodic check.
      checkNow(silent: true);
    }
  }

  void checkNow({bool silent = false}) async {
    final List<String> scope = folders;
    if (scope.isEmpty) {
      if (!silent) {
        context.showMessage(message: "No folders available".tl);
      }
      return;
    }
    unawaited(maybePromptBatteryOptimization());
    FollowUpdatesService._cancelChecking?.call();
    FollowUpdateTaskManager.instance.startCheck(scope, manual: true);
    context.showMessage(message: "Task started".tl);
  }

  void updateComics() {
    // Refreshes fire per read and per task tick. They always reload in place:
    // the list is already on screen, and an isolate spawn per notification cost
    // far more than the (now cheap) query it was meant to move off-thread.
    setState(_loadSync);
  }

  @override
  Object? get key => 'FollowUpdatesPage';
}

/// Background service for checking updates
abstract class FollowUpdatesService {
  static bool _isChecking = false;

  static void Function()? _cancelChecking;

  static bool _isInitialized = false;

  static bool _cancelRequested = false;

  static Timer? _checkerTimer;

  static void _check() async {
    if (_isChecking) {
      return;
    }
    // A degraded session (favorites init failed) must not start a check: every
    // step would trip over the uninitialized store. The periodic timer simply
    // retries on a later tick.
    if (!LocalFavoritesManager().isInitialized) {
      return;
    }
    if (FollowUpdateScope.folders().isEmpty) {
      return;
    }
    _cancelRequested = false;
    _cancelChecking = () {
      _cancelRequested = true;
    };

    _isChecking = true;

    try {
      // Applying a backup restores the favorites DB in place; hold the check
      // until both the download AND the apply (which manual imports run
      // without a download) are over, so its writes don't interleave.
      while (DataSync().isDownloading || DataSync().isApplyingBackup) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_cancelRequested) {
          return;
        }
      }

      if (_cancelRequested) {
        return;
      }
      // The wait above can outlive a scope change; re-read it so a check isn't
      // started for folders no longer followed.
      var scope = FollowUpdateScope.folders();
      if (scope.isEmpty) {
        return;
      }
      var task = FollowUpdateTaskManager.instance.startCheck(
        scope,
        manual: false,
      );
      if (task == null) {
        return;
      }
      var completer = Completer<void>();
      void completeChecking() {
        if (!completer.isCompleted) {
          completer.complete();
        }
      }

      _cancelChecking = () {
        _cancelRequested = true;
        FollowUpdateTaskManager.instance.cancel(task.id);
        completeChecking();
      };
      void onTaskChanged() {
        if (_cancelRequested || !task.isRunning) {
          completeChecking();
        }
      }

      FollowUpdateTaskManager.instance.addListener(onTaskChanged);
      await completer.future.whenComplete(() {
        FollowUpdateTaskManager.instance.removeListener(onTaskChanged);
      });
    } finally {
      _cancelChecking = null;
      _cancelRequested = false;
      _isChecking = false;
    }
  }

  /// Initialize the checker.
  static void initChecker() {
    if (_isInitialized) return;
    _isInitialized = true;
    FollowUpdateTaskManager.instance.onTaskFinished = (_) {
      updateFollowUpdatesUI();
    };
    // Resume any check that was interrupted by the app being killed before
    // starting a fresh periodic check, so it continues from its breakpoint.
    FollowUpdateTaskManager.instance.resumePendingTasks();
    // A resumed check finishes regardless; only a fresh startup check is opt-in.
    if (FollowUpdateScope.checkOnStart) {
      _check();
    }
    DataSync().addListener(updateFollowUpdatesUI);
    // Polling this often is cheap: the per-comic interval decides what actually
    // gets fetched, so a tick with nothing due starts no task at all.
    _checkerTimer ??= Timer.periodic(const Duration(minutes: 10), (timer) {
      if (FollowUpdateScope.isPastFixedTime(
        FollowUpdateScope.fixedTime,
        DateTime.now(),
      )) {
        _check();
      }
    });
  }
}

/// Update the UI of follow updates.
void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}

/// What a settings dialog was closed with: the folder scope plus the schedule
/// preferences, all applied together on confirm.
class _SettingsChoice {
  const _SettingsChoice({
    required this.allFolders,
    required this.folders,
    required this.intervalHours,
    required this.checkOnStart,
    required this.fixedTime,
  });

  final bool allFolders;
  final List<String> folders;
  final int intervalHours;
  final bool checkOnStart;
  final String fixedTime;
}

/// Follow-updates settings, split into a schedule tab and a folder tab.
///
/// Nothing is written until confirm, so backing out of the dialog leaves the
/// current configuration alone. Deliberately built without a `TabBarView`: the
/// dialog measures its content with `IntrinsicWidth`, which a page view (or any
/// other viewport) cannot answer, so the body is switched by hand instead.
class _FollowUpdateSettingsDialog extends StatefulWidget {
  const _FollowUpdateSettingsDialog();

  @override
  State<_FollowUpdateSettingsDialog> createState() =>
      _FollowUpdateSettingsDialogState();
}

class _FollowUpdateSettingsDialogState
    extends State<_FollowUpdateSettingsDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  late bool allFolders = FollowUpdateScope.allFolders;

  /// Kept as a set so toggling a folder is order-independent; the saved list is
  /// rebuilt in folder order on confirm.
  late Set<String> selected = FollowUpdateScope.selected.toSet();

  late int intervalHours = FollowUpdateScope.intervalHours;

  late bool checkOnStart = FollowUpdateScope.checkOnStart;

  late String fixedTime = FollowUpdateScope.fixedTime;

  List<String> get availableFolders => LocalFavoritesManager().folderNames;

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _pickFixedTime() async {
    var current = FollowUpdateScope.parseFixedTime(fixedTime);
    var picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: current?.hour ?? 8,
        minute: current?.minute ?? 0,
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      fixedTime =
          "${picked.hour.toString().padLeft(2, '0')}:"
          "${picked.minute.toString().padLeft(2, '0')}";
    });
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: ts.s12.bold.withColor(context.colorScheme.primary),
    ).paddingVertical(8);
  }

  Widget _buildScheduleTab() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel("Check interval".tl),
        Text(
          "A comic is checked again only after this much time.".tl,
          style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Select(
            minWidth: 140,
            current: FollowUpdateScope.describeInterval(intervalHours),
            values: FollowUpdateScope.intervalOptions
                .map(FollowUpdateScope.describeInterval)
                .toList(),
            onTap: (index) => setState(
              () => intervalHours = FollowUpdateScope.intervalOptions[index],
            ),
          ),
        ),
        const Divider(height: 24),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text("Check on startup".tl),
          subtitle: Text(
            "Run one check right after the app starts.".tl,
            style: ts.s12,
          ),
          value: checkOnStart,
          onChanged: (value) => setState(() => checkOnStart = value),
        ),
        const Divider(height: 24),
        _sectionLabel("Fixed check time".tl),
        Text(
          "Automatic checks wait until this time of day.".tl,
          style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.tonal(
              onPressed: _pickFixedTime,
              child: Text(FollowUpdateScope.describeFixedTime(fixedTime)),
            ),
            const SizedBox(width: 8),
            if (FollowUpdateScope.parseFixedTime(fixedTime) != null)
              TextButton(
                onPressed: () => setState(() => fixedTime = ""),
                child: Text("Clear".tl),
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildFoldersTab(List<String> folders) {
    if (folders.isEmpty) {
      return Text(
        "No folders available".tl,
        style: ts.s14.withColor(context.colorScheme.onSurfaceVariant),
      ).paddingVertical(16);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text("All folders".tl),
          subtitle: Text(
            "Folders added later are followed too.".tl,
            style: ts.s12,
          ),
          value: allFolders,
          onChanged: (value) => setState(() => allFolders = value),
        ),
        const Divider(height: 8),
        // Left visible but inert while "all folders" is on, so the user can see
        // what an individual selection would fall back to.
        for (var folder in folders)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(folder, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              "@a comics".tlParams({
                'a': LocalFavoritesManager().folderComics(folder),
              }),
              style: ts.s12,
            ),
            value: allFolders || selected.contains(folder),
            onChanged: allFolders
                ? null
                : (value) => setState(() {
                    if (value == true) {
                      selected.add(folder);
                    } else {
                      selected.remove(folder);
                    }
                  }),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    var folders = availableFolders;
    var chosen = folders.where(selected.contains).toList();
    return ContentDialog(
      title: "Follow Updates Settings".tl,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 46,
            child: TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: "Folders".tl),
                Tab(text: "Settings".tl),
              ],
            ),
          ),
          const SizedBox(height: 4),
          if (_tabs.index == 0)
            _buildFoldersTab(folders)
          else
            _buildScheduleTab(),
        ],
      ),
      actions: [
        if (FollowUpdateScope.isConfigured)
          TextButton(
            onPressed: () => context.pop(
              _SettingsChoice(
                allFolders: false,
                folders: const [],
                intervalHours: intervalHours,
                checkOnStart: checkOnStart,
                fixedTime: fixedTime,
              ),
            ),
            child: Text("Disable".tl),
          ),
        FilledButton(
          onPressed: (allFolders || chosen.isNotEmpty)
              ? () => context.pop(
                  _SettingsChoice(
                    allFolders: allFolders,
                    folders: chosen,
                    intervalHours: intervalHours,
                    checkOnStart: checkOnStart,
                    fixedTime: fixedTime,
                  ),
                )
              : null,
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}

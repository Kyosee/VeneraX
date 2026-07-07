import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/battery_optimization.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import '../foundation/global_state.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/ext.dart';

/// Above this row count, the followed folder is loaded in a background isolate
/// so opening the page doesn't jank the transition. See favorites.dart.
const _asyncDataFetchLimit = 500;

class FollowUpdatesWidget extends StatefulWidget {
  const FollowUpdatesWidget({super.key});

  @override
  State<FollowUpdatesWidget> createState() => _FollowUpdatesWidgetState();
}

class _FollowUpdatesWidgetState
    extends AutomaticGlobalState<FollowUpdatesWidget> {
  int _count = 0;

  String? get folder => appdata.settings["followUpdatesFolder"];

  void getCount() {
    if (folder == null) {
      _count = 0;
      return;
    }
    final manager = LocalFavoritesManager();
    if (!manager.isInitialized) {
      // Store down (still initializing, or init failed): folderNames reads
      // empty then, and the branch below would permanently unconfigure the
      // device-local follow folder. Report zero and keep the setting.
      _count = 0;
      return;
    }
    if (!manager.folderNames.contains(folder)) {
      _count = 0;
      appdata.settings["followUpdatesFolder"] = null;
      Future.microtask(() {
        appdata.saveData();
      });
    } else {
      _count = manager.countUpdates(folder!);
    }
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
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => FollowUpdatesPage());
          },
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Follow Updates'.tl,
                    style: ts.s18,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                if (updatesText != null)
                  Container(
                    constraints: const BoxConstraints(maxWidth: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: Theme.of(context).colorScheme.primaryContainer,
                    ),
                    child: Text(
                      updatesText,
                      style: ts.s16,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_right),
              ],
            ),
          ).paddingHorizontal(16),
        ),
      ),
    );
  }

  @override
  Object? get key => 'FollowUpdatesWidget';
}

class FollowUpdatesPage extends StatefulWidget {
  const FollowUpdatesPage({super.key});

  @override
  State<FollowUpdatesPage> createState() => _FollowUpdatesPageState();
}

class _FollowUpdatesPageState extends AutomaticGlobalState<FollowUpdatesPage> {
  String? get folder => appdata.settings["followUpdatesFolder"];

  var updatedComics = <FavoriteItemWithUpdateInfo>[];
  var completedComics = <FavoriteItemWithUpdateInfo>[];
  var allComics = <FavoriteItemWithUpdateInfo>[];
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
    final f = folder;
    if (f != null &&
        LocalFavoritesManager().folderComics(f) >= _asyncDataFetchLimit) {
      // Large folder: defer + load off the UI thread so the page-push
      // transition isn't blocked. A spinner shows until it's ready.
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAsync(f));
    } else {
      // Small (or unconfigured): load synchronously now — cheap, no flash.
      _loadSync();
    }
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
      final f = folder;
      if (f == null) {
        return;
      }
      // Cheap change signal: reload only when the flagged count moved, so an
      // idle notify doesn't re-read and re-sort the whole folder.
      if (LocalFavoritesManager().countUpdates(f) == updatedComics.length) {
        return;
      }
      if (LocalFavoritesManager().folderComics(f) >= _asyncDataFetchLimit) {
        _loadAsync(f);
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
  }

  /// Synchronously (re)load the followed folder and refresh derived lists.
  /// Safe inside initState (assigns fields only); wrap in setState elsewhere.
  void _loadSync() {
    final f = folder;
    if (f == null) {
      allComics = [];
    } else {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(f);
      sortComics();
    }
    _recomputeDerived();
  }

  /// Load folder [f] off the UI thread. Always clears [isLoading] when done —
  /// on success, on error (falls back to a sync load), and if the user switched
  /// folders mid-load (drops the stale result and resyncs to the current one).
  void _loadAsync(String f) async {
    if (!mounted) return;
    setState(() => isLoading = true);
    List<FavoriteItemWithUpdateInfo>? value;
    try {
      value = await LocalFavoritesManager()
          .getComicsWithUpdatesInfoAsync(f)
          .minTime(const Duration(milliseconds: 200));
    } catch (e, s) {
      Log.error("FollowUpdates", "async load failed: $e", s);
    }
    if (!mounted) return;
    if (folder != f) {
      _loadSync();
    } else if (value != null) {
      allComics = value;
      sortComics();
      _recomputeDerived();
    } else {
      _loadSync();
    }
    setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text('Follow Updates'.tl)),
      body: folder == null
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
              "Choose a folder to follow updates.".tl,
              style: ts.s16,
            ).paddingHorizontal(16),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: showSelector,
              child: Text("Choose Folder".tl),
            ).paddingHorizontal(16).toAlign(Alignment.centerRight),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget buildConfigured(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.stars_outlined),
            const SizedBox(width: 12),
            Expanded(child: Text(folder!, style: ts.s14)),
            TextButton(
              onPressed: showSelector,
              child: Text("Change Folder".tl),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: checkNow,
              child: Text("Check Now".tl),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildConfiguredTabs(BuildContext context) {
    // `unread` is read-history-dependent (cheap O(1) lookups), so compute it
    // live here rather than caching, to stay correct after the user reads a
    // comic. `updated`/`completed` come from the cached fields.
    final unreadComics = allComics.where(_isUnread).toList();
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          buildConfigured(context),
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
      scrollbar: true,
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

  void showSelector() {
    var folders = LocalFavoritesManager().folderNames;
    if (folders.isEmpty) {
      context.showMessage(message: "No folders available".tl);
      return;
    }
    String? selectedFolder;
    showDialog(
      context: App.rootContext,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Choose Folder".tl,
              content: Column(
                children: [
                  ListTile(
                    title: Text("Folder".tl),
                    trailing: Select(
                      minWidth: 120,
                      current: selectedFolder,
                      values: folders,
                      onTap: (i) {
                        setState(() {
                          selectedFolder = folders[i];
                        });
                      },
                    ),
                  ),
                ],
              ),
              actions: [
                if (appdata.settings["followUpdatesFolder"] != null)
                  TextButton(
                    onPressed: () {
                      disable();
                      context.pop();
                    },
                    child: Text("Disable".tl),
                  ),
                FilledButton(
                  onPressed: selectedFolder == null
                      ? null
                      : () {
                          context.pop();
                          setFolder(selectedFolder!);
                        },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void disable() {
    var oldFolder = appdata.settings["followUpdatesFolder"];
    appdata.settings["followUpdatesFolder"] = null;
    appdata.saveData();
    // Disabling follow-updates is an explicit cancellation: drop any pending
    // resumable check for that folder so it isn't resumed on the next launch.
    if (oldFolder is String) {
      FollowUpdateTaskManager.instance.cancelForFolder(oldFolder);
    }
    updateFollowUpdatesUI();
  }

  void setFolder(String folder) async {
    FollowUpdatesService._cancelChecking?.call();
    // Switching to a different folder cancels any pending resumable check for
    // the previously-followed folder (treated as user-initiated cancellation).
    var oldFolder = appdata.settings["followUpdatesFolder"];
    if (oldFolder is String && oldFolder != folder) {
      FollowUpdateTaskManager.instance.cancelForFolder(oldFolder);
    }
    // Do NOT clear has_new_update here. Selecting a follow-updates folder is a
    // local configuration action; wiping the flags would discard update marks
    // that were just synced from another device (and, since this is followed
    // by a sync upload, would propagate the cleared state back to every other
    // device). Read marks are cleared by the normal read path, and real new
    // chapters are written incrementally by the update check below.
    LocalFavoritesManager().prepareTableForFollowUpdates(folder, false);

    var count = LocalFavoritesManager().count(folder);

    void applyFolderSelection() {
      if (!mounted) {
        return;
      }
      setState(() {
        appdata.settings["followUpdatesFolder"] = folder;
        _loadSync();
      });
      // Persist the folder choice locally without triggering a sync upload:
      // this is a local config change, and uploading here could push a
      // transient (pre-check) state over the good data on other devices.
      // Real update marks propagate later via normal data-change syncs.
      appdata.saveData(false);
    }

    if (count > 0) {
      unawaited(maybePromptBatteryOptimization());
      var task = FollowUpdateTaskManager.instance.startCheck(
        folder,
        manual: true,
      );
      if (task == null) {
        return;
      }
      final activeTask = task;
      var completer = Completer<void>();
      var backgrounded = false;
      var canceled = false;

      var loadingController = showLoadingDialog(
        App.rootContext,
        withProgress: true,
        cancelButtonText: "Cancel".tl,
        onCancel: () {
          canceled = true;
          FollowUpdateTaskManager.instance.cancel(activeTask.id);
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
        secondaryButtonText: "Background".tl,
        onSecondary: () {
          backgrounded = true;
          applyFolderSelection();
          context.showMessage(message: "Task started".tl);
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
        message: "Updating comics...".tl,
      );

      void onTaskChanged() {
        loadingController.setProgress(activeTask.progress);
        if (!activeTask.isRunning && !completer.isCompleted) {
          completer.complete();
        }
      }

      FollowUpdateTaskManager.instance.addListener(onTaskChanged);
      onTaskChanged();

      try {
        await completer.future;
      } finally {
        FollowUpdateTaskManager.instance.removeListener(onTaskChanged);
        loadingController.close();
      }

      if (canceled || backgrounded) {
        return;
      }
    }

    applyFolderSelection();
  }

  void checkNow() async {
    unawaited(maybePromptBatteryOptimization());
    FollowUpdatesService._cancelChecking?.call();
    FollowUpdateTaskManager.instance.startCheck(folder!, manual: true);
    context.showMessage(message: "Task started".tl);
  }

  void updateComics() {
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
    var folder = appdata.settings["followUpdatesFolder"];
    if (folder == null) {
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
      // The wait above can outlive a folder change/disable; re-read the
      // setting so a check isn't started for a folder no longer followed.
      folder = appdata.settings["followUpdatesFolder"];
      if (folder == null) {
        return;
      }
      var task = FollowUpdateTaskManager.instance.startCheck(
        folder,
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
    _check();
    DataSync().addListener(updateFollowUpdatesUI);
    // A short interval will not affect the performance since every comic has a check time.
    _checkerTimer ??= Timer.periodic(const Duration(minutes: 10), (timer) {
      _check();
    });
  }
}

/// Update the UI of follow updates.
void updateFollowUpdatesUI() {
  GlobalState.findOrNull<_FollowUpdatesWidgetState>()?.updateCount();
  GlobalState.findOrNull<_FollowUpdatesPageState>()?.updateComics();
}

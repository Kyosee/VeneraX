import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_tasks.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';
import '../foundation/global_state.dart';
import 'package:venera/foundation/history.dart';

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
    if (!LocalFavoritesManager().folderNames.contains(folder)) {
      _count = 0;
      appdata.settings["followUpdatesFolder"] = null;
      Future.microtask(() {
        appdata.saveData();
      });
    } else {
      _count = LocalFavoritesManager().countUpdates(folder!);
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
  var allComics = <FavoriteItemWithUpdateInfo>[];

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
    if (folder != null) {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text('Follow Updates'.tl)),
      body: folder == null
          ? SmoothCustomScrollView(slivers: [buildNotConfigured(context)])
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(leading: Icon(Icons.stars_outlined), title: Text(folder!)),
          Text(
            "Automatic update checking enabled.".tl,
            style: ts.s14,
          ).paddingHorizontal(16),
          Text(
            "The app will check for updates at most once a day.".tl,
            style: ts.s14,
          ).paddingHorizontal(16),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: showSelector,
                child: Text("Change Folder".tl),
              ),
              FilledButton.tonal(
                onPressed: checkNow,
                child: Text("Check Now".tl),
              ),
              const SizedBox(width: 16),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget buildConfiguredTabs(BuildContext context) {
    final unreadComics = allComics.where(_isUnread).toList();
    final completedComics = allComics.where(_isReadCompleted).toList();
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          buildConfigured(context),
          Material(
            child: AppTabBar(
              tabs: [
                Tab(text: "Updates".tl),
                Tab(text: "Unread".tl),
                Tab(text: "Ended".tl),
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
    var history = HistoryManager().find(
      comic.id,
      ComicType.fromKey(comic.sourceKey),
    );
    return history != null &&
        history.maxPage != null &&
        history.maxPage! > 0 &&
        history.page >= history.maxPage!;
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
    appdata.settings["followUpdatesFolder"] = null;
    appdata.saveData();
    updateFollowUpdatesUI();
  }

  void setFolder(String folder) async {
    FollowUpdatesService._cancelChecking?.call();
    LocalFavoritesManager().prepareTableForFollowUpdates(folder);

    var count = LocalFavoritesManager().count(folder);

    void applyFolderSelection() {
      if (!mounted) {
        return;
      }
      setState(() {
        appdata.settings["followUpdatesFolder"] = folder;
        updatedComics = [];
        allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
        sortComics();
      });
      appdata.saveData();
    }

    if (count > 0) {
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
    FollowUpdatesService._cancelChecking?.call();
    FollowUpdateTaskManager.instance.startCheck(folder!, manual: true);
    context.showMessage(message: "Task started".tl);
  }

  void updateComics() {
    if (folder == null) {
      setState(() {
        allComics = [];
        updatedComics = [];
      });
      return;
    }
    setState(() {
      allComics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder!);
      sortComics();
      updatedComics = allComics.where((c) => c.hasNewUpdate).toList();
    });
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
      while (DataSync().isDownloading) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_cancelRequested) {
          return;
        }
      }

      if (_cancelRequested) {
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

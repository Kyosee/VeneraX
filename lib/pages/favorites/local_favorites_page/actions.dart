part of '../favorites_page.dart';

mixin _LocalFavoritesActions on SelectionMixin<_LocalFavoritesPage, Comic> {
  _FavoritesPageState get favPage;

  List<FavoriteItem> get comics;

  List<String> get added;

  Set<String> get selectedLocalFolders;

  bool get isAllFolder;

  LocalFavoritesManager get manager;

  String? get networkSource;

  String? get networkFolder;

  List<FavoriteItem> filterComics(List<FavoriteItem> curComics);

  void updateComics();

  Future<bool> downloadComic(FavoriteItem c) async {
    var source = c.type.comicSource;
    if (source != null) {
      bool isDownloaded = LocalManager().isDownloaded(c.id, (c).type);
      if (isDownloaded) {
        return false;
      }
      if (!await ensureDownloadStorageWritable()) return false;
      LocalManager().addTask(
        ImagesDownloadTask(
          source: source,
          comicId: c.id,
          comicTitle: c.title,
          comicCover: c.cover,
        ),
      );
      return true;
    }
    return false;
  }

  void downloadSelected() async {
    if (!await ensureDownloadStorageWritable()) return;
    // Build the tasks first, then enqueue them in one batch so the queue is
    // persisted a single time instead of once per comic (#17).
    var tasks = <DownloadTask>[];
    for (var c in selectedItems.keys) {
      var fav = c as FavoriteItem;
      var source = fav.type.comicSource;
      if (source == null) continue;
      if (LocalManager().isDownloading(fav.id, fav.type)) continue;
      if (LocalManager().isDownloaded(fav.id, fav.type)) continue;
      tasks.add(
        ImagesDownloadTask(
          source: source,
          comicId: fav.id,
          comicTitle: fav.title,
          comicCover: fav.cover,
        ),
      );
    }
    if (tasks.isNotEmpty) {
      LocalManager().addTasks(tasks);
      App.rootContext.showMessage(
        message: "Added @c comics to download queue.".tlParams(
          {"c": tasks.length},
        ),
      );
    }
  }

  void _showSyncDialog() {
    if (networkSource == null) return;
    final selectUpdatePageNumKey = GlobalKey<_SelectUpdatePageNumState>();
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: "Sync".tl,
          content: _SelectUpdatePageNum(
            networkSource: networkSource!,
            networkFolder: networkFolder,
            key: selectUpdatePageNumKey,
          ).paddingHorizontal(4),
          actions: [
            Button.filled(
              child: Text("Update".tl),
              onPressed: () {
                context.pop();
                importNetworkFolder(
                  networkSource!,
                  selectUpdatePageNumKey.currentState!.updatePageNum,
                  widget.folder,
                  networkFolder!,
                ).then((value) {
                  updateComics();
                });
              },
            ),
          ],
        );
      },
    );
  }

  void _showAutoLinkSourcesDialog() {
    final searchableSources = ComicSource.all()
        .where(
          (source) =>
              source.searchPageData?.loadPage != null ||
              source.searchPageData?.loadNext != null,
        )
        .toList();
    final selectedSources = searchableSources
        .map((source) => source.key)
        .toSet();
    final targetComics = filterComics(comics);
    if (targetComics.isEmpty) {
      context.showMessage(message: "No comics".tl);
      return;
    }
    if (searchableSources.isEmpty) {
      context.showMessage(message: "No searchable sources".tl);
      return;
    }
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Dialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: context.brightness == Brightness.dark
                    ? BorderSide(color: context.colorScheme.outlineVariant)
                    : BorderSide.none,
              ),
              insetPadding: context.width < 400
                  ? const EdgeInsets.symmetric(horizontal: 4)
                  : const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: min(600, max(280, context.width - 64)),
                height: min(560, max(320, context.height - 96)),
                child: Column(
                  children: [
                    Appbar(
                      leading: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: context.pop,
                      ),
                      title: Text("Auto link comic sources".tl),
                      backgroundColor: Colors.transparent,
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Auto link sources warning".tlParams({
                              "count": targetComics.length,
                            }),
                            style: TextStyle(
                              color: context.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Text("Select Source".tl, style: ts.s16),
                              const Spacer(),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    selectedSources
                                      ..clear()
                                      ..addAll(
                                        searchableSources.map(
                                          (source) => source.key,
                                        ),
                                      );
                                  });
                                },
                                child: Text("Select All".tl),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(selectedSources.clear);
                                },
                                child: Text("Deselect".tl),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: ListView.builder(
                              itemCount: searchableSources.length,
                              itemBuilder: (context, index) {
                                final source = searchableSources[index];
                                return CheckboxListTile(
                                  dense: true,
                                  value: selectedSources.contains(source.key),
                                  title: Text(source.name),
                                  onChanged: (value) {
                                    setState(() {
                                      if (value == true) {
                                        selectedSources.add(source.key);
                                      } else {
                                        selectedSources.remove(source.key);
                                      }
                                    });
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ).paddingHorizontal(16),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Button.text(
                            onPressed: () => context.pop(),
                            child: Text("Cancel".tl),
                          ),
                          const SizedBox(width: 8),
                          Button.filled(
                            onPressed: () {
                              if (selectedSources.isEmpty) {
                                context.showMessage(
                                  message: "Invalid input".tl,
                                );
                                return;
                              }
                              RelatedSourceTaskManager.instance.startAutoLink(
                                folder: isAllFolder
                                    ? "All Comics".tl
                                    : widget.folder,
                                favorites: targetComics,
                                targetSourceKeys: selectedSources.toList(),
                              );
                              context.pop();
                              App.rootContext.showMessage(
                                message: "Task started".tl,
                              );
                            },
                            child: Text("Start".tl),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void favoriteOption(String option) {
    // Reset target selection so previous choices don't carry over.
    selectedLocalFolders.clear();
    var targetFolders = LocalFavoritesManager().folderNames
        .where((folder) => folder != favPage.folder)
        .toList();

    showPopUpWidget(
      App.rootContext,
      StatefulBuilder(
        builder: (context, setState) {
          return PopUpWidgetScaffold(
            title: isAllFolder
                ? "All".tl
                : (favPage.folder ?? "Unselected".tl),
            body: Padding(
              // The scaffold already clears the system inset; this is just
              // extra breathing room under the confirm button.
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                constraints: const BoxConstraints(
                  maxHeight: 700,
                  maxWidth: 500,
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: targetFolders.length + 1,
                        itemBuilder: (context, index) {
                          if (index == targetFolders.length) {
                            return SizedBox(
                              height: 36,
                              child: Center(
                                child: TextButton(
                                  onPressed: () {
                                    newFolder().then((v) {
                                      setState(() {
                                        targetFolders = LocalFavoritesManager()
                                            .folderNames
                                            .where(
                                              (folder) =>
                                                  folder != favPage.folder,
                                            )
                                            .toList();
                                      });
                                    });
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.add, size: 20),
                                      const SizedBox(width: 4),
                                      Text("New Folder".tl),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                          var folder = targetFolders[index];
                          var disabled = false;
                          if (selectedLocalFolders.isNotEmpty) {
                            if (added.contains(folder) &&
                                !added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            } else if (!added.contains(folder) &&
                                added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            }
                          }
                          return CheckboxListTile(
                            title: Row(
                              children: [
                                Text(folder),
                                const SizedBox(width: 8),
                              ],
                            ),
                            value: selectedLocalFolders.contains(folder),
                            onChanged: disabled
                                ? null
                                : (v) {
                                    setState(() {
                                      if (v!) {
                                        // Moving from the aggregated view can
                                        // only target a single folder, so keep
                                        // the selection single-choice.
                                        if (option == 'move' && isAllFolder) {
                                          selectedLocalFolders.clear();
                                        }
                                        selectedLocalFolders.add(folder);
                                      } else {
                                        selectedLocalFolders.remove(folder);
                                      }
                                    });
                                  },
                          );
                        },
                      ),
                    ),
                    Center(
                      child: FilledButton(
                        onPressed: () {
                          if (selectedLocalFolders.isEmpty) {
                            return;
                          }
                          var comics = selectedItems.keys
                              .map((e) => e as FavoriteItem)
                              .toList();
                          void execute() {
                            if (option == 'move') {
                              if (isAllFolder) {
                                // Aggregated view: each comic may live in a
                                // different folder, so move it out of all its
                                // source folders into the single target.
                                LocalFavoritesManager()
                                    .batchMoveFavoritesToFolder(
                                  selectedLocalFolders.first,
                                  comics,
                                );
                              } else {
                                for (var f in selectedLocalFolders) {
                                  LocalFavoritesManager().batchMoveFavorites(
                                    favPage.folder as String,
                                    f,
                                    comics,
                                  );
                                }
                              }
                            } else {
                              if (isAllFolder) {
                                for (var f in selectedLocalFolders) {
                                  LocalFavoritesManager()
                                      .batchCopyFavoritesToFolder(f, comics);
                                }
                              } else {
                                for (var f in selectedLocalFolders) {
                                  LocalFavoritesManager().batchCopyFavorites(
                                    favPage.folder as String,
                                    f,
                                    comics,
                                  );
                                }
                              }
                            }
                            App.rootContext.pop();
                            updateComics();
                            _cancel();
                          }

                          // Moving from the aggregated view removes the comics
                          // from every folder they currently belong to, so ask
                          // the user to confirm before doing it.
                          if (option == 'move' && isAllFolder) {
                            showConfirmDialog(
                              context: App.rootContext,
                              title: "Move to folder".tl,
                              content: "Move @c comics to \"@f\"? They will be removed from all other folders."
                                  .tlParams({
                                "c": comics.length,
                                "f": selectedLocalFolders.first,
                              }),
                              onConfirm: execute,
                            );
                          } else {
                            execute();
                          }
                        },
                        child: Text(option == 'move' ? "Move".tl : "Add".tl),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _cancel() => exitSelectMode();

  void _deleteComicWithId() {
    var toBeDeleted = selectedItems.keys
        .map((e) => e as FavoriteItem)
        .toList();
    LocalFavoritesManager().batchDeleteComics(widget.folder, toBeDeleted);
    _cancel();
  }

  /// Swipe-cancel a favorite from the list without opening the comic. In a
  /// specific folder it removes the comic from that folder; in the aggregated
  /// "All" view "cancel favorite" means a full unfavorite, so it removes the
  /// comic from every folder it belongs to. Either way an undo toast restores
  /// the exact membership (mirrors the read-later swipe-delete pattern).
  void _removeFavoriteSwipe(FavoriteItem c) {
    void showUndo(VoidCallback undo) {
      if (!mounted) return;
      showToast(
        context: context,
        message: "Removed from favorites".tl,
        trailing: TextButton(
          onPressed: undo,
          child: Text("Undo".tl),
        ),
      );
    }

    if (isAllFolder) {
      var folders = manager.find(c.id, c.type);
      manager.batchDeleteComicsInAllFolders([ComicID(c.type, c.id)]);
      showUndo(() {
        for (var f in folders) {
          manager.addComic(f, c);
        }
      });
    } else {
      manager.deleteComicWithId(widget.folder, c.id, c.type);
      showUndo(() => manager.addComic(widget.folder, c));
    }
  }
}

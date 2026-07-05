import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/export_tasks.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/pages/home_page.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

class _LocalComicsPageState extends State<LocalComicsPage>
    with SingleTickerProviderStateMixin,
        SelectionMixin<LocalComicsPage, LocalComic> {
  late List<LocalComic> comics;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  @override
  List<LocalComic> get selectableItems => comics;

  LocalComicStatus? currentTab; // null means "全部" (all)

  /// Builds the comic list for the current tab/keyword, merging active
  /// downloading tasks that aren't persisted in the database yet, so an
  /// in-progress comic shows under "All"/"Downloading" right away instead of
  /// only after switching tabs forces a rebuild (#90).
  List<LocalComic> _collectComics() {
    List<LocalComic> all;
    if (keyword.isEmpty) {
      all = LocalManager().getComics(sortType);
    } else {
      all = LocalManager().search(keyword);
    }
    // Merge active downloading tasks that aren't yet in the database
    var existingIds = all.map((c) => '${c.id}_${c.comicType}').toSet();
    var downloadingComics = LocalManager()
        .downloadingTasks
        .where((task) =>
            !existingIds.contains('${task.id}_${task.comicType}'))
        .map((task) => task.toLocalComic())
        .toList();
    all = [...downloadingComics, ...all];
    return currentTab == null
        ? all
        : all.where((c) => c.status == currentTab).toList();
  }

  void update() {
    setState(() {
      comics = _collectComics();
    });
  }

  late TabController _tabController;

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "default";
    sortType = LocalSortType.fromString(sort);
    comics = _collectComics();
    LocalManager().addListener(update);
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
    super.initState();
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    LocalManager().removeListener(update);
    super.dispose();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {
      currentTab = switch (_tabController.index) {
        1 => LocalComicStatus.downloaded,
        2 => LocalComicStatus.downloading,
        3 => LocalComicStatus.notDownloaded,
        _ => null,
      };
    });
    update();
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "Sort".tl,
            content: RadioGroup<LocalSortType>(
              groupValue: sortType,
              onChanged: (v) {
                setState(() {
                  sortType = v ?? sortType;
                });
              },
              child: Column(
                children: [
                  RadioListTile<LocalSortType>(
                    title: Text("Default".tl),
                    value: LocalSortType.defaultSort,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Name Asc".tl),
                    value: LocalSortType.name,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Name Desc".tl),
                    value: LocalSortType.nameDesc,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Newest First".tl),
                    value: LocalSortType.timeDesc,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Oldest First".tl),
                    value: LocalSortType.timeAsc,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Author".tl),
                    value: LocalSortType.author,
                  ),
                  RadioListTile<LocalSortType>(
                    title: Text("Last Read".tl),
                    value: LocalSortType.lastRead,
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () {
                  appdata.implicitData["local_sort"] = sortType.value;
                  appdata.writeImplicitData();
                  Navigator.pop(context);
                  update();
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        });
      },
    );
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(entries: [
      MenuEntry(
        icon: Icons.delete_outline,
        text: "Delete".tl,
        onClick: () {
          deleteComics(selectedItems.keys.toList()).then((value) {
            if (value) {
              exitSelectMode();
            }
          });
        },
      ),
      MenuEntry(
        icon: Icons.favorite_border,
        text: "Add to favorites".tl,
        onClick: () {
          addFavorite(selectedItems.keys.toList());
        },
      ),
      if (selectedItems.length == 1)
        MenuEntry(
          icon: Icons.folder_open,
          text: "Open Folder".tl,
          onClick: () {
            openComicFolder(selectedItems.keys.first);
          },
        ),
      if (selectedItems.length == 1)
        MenuEntry(
          icon: Icons.chrome_reader_mode_outlined,
          text: "View Detail".tl,
          onClick: () {
            context.to(() => ComicPage(
                  id: selectedItems.keys.first.id,
                  sourceKey: selectedItems.keys.first.sourceKey,
                ));
          },
        ),
      if (selectedItems.isNotEmpty)
        ...exportActions(selectedItems.keys.toList()),
      if (selectedItems.isNotEmpty)
        MenuEntry(
          icon: Icons.archive_outlined,
          text: "Export .venera_comics".tl,
          onClick: () => _startVeneraExport(selectedItems.keys.toList()),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: "Select All".tl,
          onPressed: selectAll),
      IconButton(
          icon: const Icon(Icons.deselect),
          tooltip: "Deselect".tl,
          onPressed: deSelect),
      IconButton(
          icon: const Icon(Icons.flip),
          tooltip: "Invert Selection".tl,
          onPressed: invertSelection),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(
          icon: const Icon(Icons.sort),
          onPressed: sort,
        ),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
      MenuButton(entries: [
          MenuEntry(
            icon: Icons.file_download_outlined,
            text: "Import".tl,
            onClick: () {
              showDialog(
                barrierDismissible: false,
                context: context,
                builder: (context) => const ImportComicsWidget(),
              );
            },
          ),
          MenuEntry(
            icon: Icons.file_upload_outlined,
            text: "Export".tl,
            onClick: () {
              setState(() {
                multiSelectMode = true;
              });
            },
          ),
        ]),
    ];

    var body = Scaffold(
      body: SmoothCustomScrollView(
        scrollbar: true,
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          if (!searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      exitSelectMode();
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedItems.length.toString())
                  : Text("Local".tl),
              actions: multiSelectMode ? selectActions : normalActions,
            )
          else if (searchMode)
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Cancel".tl,
                child: IconButton(
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.close),
                  onPressed: () {
                    if (multiSelectMode) {
                      exitSelectMode();
                    } else {
                      setState(() {
                        searchMode = false;
                        keyword = "";
                        update();
                      });
                    }
                  },
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedItems.length.toString())
                  : TextField(
                      autofocus: true,
                      decoration: InputDecoration(
                        hintText: "Search".tl,
                        border: InputBorder.none,
                      ),
                      onChanged: (v) {
                        keyword = v;
                        update();
                      },
                    ),
              actions: multiSelectMode ? selectActions : null,
            ),
          if (!searchMode && !multiSelectMode)
            SliverToBoxAdapter(
              child: Material(
                child: AppTabBar(
                  controller: _tabController,
                  tabs: [
                    Tab(text: "All".tl),
                    Tab(text: "Downloaded".tl),
                    Tab(text: "Downloading".tl),
                    Tab(text: "Not Downloaded".tl),
                  ],
                ),
              ),
            ),
          SliverGridComics(
            comics: comics,
            enableHero: false,
            selections: selectedItems,
            onLongPressed: (c, heroID) {
              setState(() {
                multiSelectMode = true;
                selectedItems[c as LocalComic] = true;
              });
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                toggleSelect(c as LocalComic);
              } else {
                // `c` is already a LocalComic from the list; re-querying via
                // find() returns null for a still-downloading comic that isn't
                // persisted yet, and the `!` would crash. Use it directly.
                var comic = c as LocalComic;
                if (comic.status == LocalComicStatus.notDownloaded) {
                  _showNotDownloadedDialog(comic);
                } else {
                  // Unified entry: open the comic detail page (same as online
                  // comics). The detail page loads local data first so it opens
                  // instantly and can be read offline.
                  context.to(() => ComicPage(
                        id: comic.id,
                        sourceKey: comic.sourceKey,
                      ));
                }
              }
            },
            menuBuilder: (c) {
              return [
                MenuEntry(
                  icon: Icons.folder_open,
                  text: "Open Folder".tl,
                  onClick: () {
                    openComicFolder(c as LocalComic);
                  },
                ),
                MenuEntry(
                  icon: Icons.delete,
                  text: "Delete".tl,
                  onClick: () {
                    deleteComics([c as LocalComic]).then((value) {
                      if (value && multiSelectMode) {
                        exitSelectMode();
                      }
                    });
                  },
                ),
                ...exportActions([c as LocalComic]),
              ];
            },
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          exitSelectMode();
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  void _showNotDownloadedDialog(LocalComic comic) {
    final hasSource = comic.comicType != ComicType.local &&
        comic.comicType.comicSource != null;
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: "Comic Not Available".tl,
          content: Text(
            "This comic has not been downloaded yet. You can import local files or download it from the source.".tl,
          ).paddingHorizontal(16).paddingVertical(8),
          actions: [
            Button.text(
              onPressed: () {
                Navigator.pop(context);
                showDialog(
                  barrierDismissible: false,
                  context: this.context,
                  builder: (context) => const ImportComicsWidget(),
                );
              },
              child: Text("Import".tl),
            ),
            if (hasSource)
              Button.filled(
                onPressed: () {
                  Navigator.pop(context);
                  this.context.to(() => ComicPage(
                        id: comic.id,
                        sourceKey: comic.sourceKey,
                      ));
                },
                child: Text("Download".tl),
              ),
          ],
        );
      },
    );
  }

  Future<String?> _pickExportFolder() async {
    if (App.isAndroid) {
      return (await DirectoryPicker().pickDirectory())?.path;
    } else if (App.isIOS) {
      return await selectDirectoryIOS();
    } else {
      return await selectDirectory();
    }
  }

  String _exportTaskMessage(ExportTask task) {
    // Show the current phase so the dialog no longer reads "Exporting N/N"
    // frozen while packaging and writing to the destination run (#92).
    switch (task.phase) {
      case ExportPhase.packaging:
        return "Packaging".tl;
      case ExportPhase.writing:
        var pct = task.writeProgress;
        if (pct != null) {
          return "Writing to folder @p%".tlParams({
            'p': (pct * 100).clamp(0, 100).toStringAsFixed(0),
          });
        }
        return "Writing to folder".tl;
      case ExportPhase.preparing:
      case ExportPhase.processing:
        return "Exporting @done/@total".tlParams({
          'done': task.done,
          'total': task.total,
        });
    }
  }

  /// Picks a destination folder, then starts a background export task that
  /// writes each comic as one file into it (issue #54). A bound loading dialog
  /// shows progress and offers a "Background" button; the task keeps running
  /// in the background and is visible in the Tasks page.
  /// Asks whether to merge into a single .venera_comics bundle (default off),
  /// then starts the export. Per-comic files (default) keep the export
  /// resumable and importable from a folder.
  void _startVeneraExport(List<LocalComic> comics) async {
    if (comics.isEmpty) return;
    bool merge = false;
    var go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => ContentDialog(
          title: "Export .venera_comics".tl,
          content: SwitchListTile(
            title: Text("Merge into a single .venera_comics".tl),
            value: merge,
            onChanged: (v) => setLocal(() => merge = v),
          ),
          actions: [
            Button.text(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text("Cancel".tl),
            ),
            Button.filled(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text("Export".tl),
            ),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    _startExportTask(comics, ExportFormat.veneraComics, merged: merge);
  }

  void _startExportTask(
    List<LocalComic> comics,
    ExportFormat format, {
    bool merged = false,
  }) async {
    if (comics.isEmpty) return;
    var manager = ExportTaskManager.instance;
    if (manager.hasActiveTask) {
      context.showMessage(message: "An export task is already running".tl);
      return;
    }
    var folder = await _pickExportFolder();
    if (folder == null || !mounted) return;
    var task = manager.startExport(
      folderPath: folder,
      format: format,
      comics: comics,
      merged: merged,
    );
    if (task == null) return;
    var controller = showLoadingDialog(
      context,
      withProgress: true,
      barrierDismissible: false,
      message: _exportTaskMessage(task),
      secondaryButtonText: "Background",
      onSecondary: () {
        // The task keeps running and lives on in the Tasks page; tell the user
        // where to find it since the dialog can't be re-summoned (#92).
        App.rootContext.showMessage(
          message: "Export moved to background; see the Tasks page".tl,
        );
      },
      cancelButtonText: "Cancel",
      onCancel: () => manager.cancel(task.id),
    );
    void listener() {
      if (controller.closed) {
        manager.removeListener(listener);
        return;
      }
      // Prefer real byte progress while writing to the destination; fall back
      // to the per-comic ratio for the earlier phases, and an indeterminate
      // bar while packaging in the isolate.
      double? barValue;
      if (task.phase == ExportPhase.writing) {
        barValue = task.writeProgress;
      } else if (task.phase == ExportPhase.packaging) {
        barValue = null;
      } else {
        barValue = task.total == 0 ? null : task.progress;
      }
      controller.setProgress(barValue);
      controller.setMessage(_exportTaskMessage(task));
      if (!task.isActive) {
        manager.removeListener(listener);
        controller.close();
        if (task.status == ExportTaskStatus.completed) {
          App.rootContext.showMessage(message: "Export completed".tl);
        } else if (task.status == ExportTaskStatus.failed) {
          App.rootContext.showMessage(
            message: (task.error ?? "Export failed").tl,
          );
        }
      }
    }

    manager.addListener(listener);
    listener();
  }

  Future<bool> deleteComics(List<LocalComic> comics) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeComicFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(builder: (context, state) {
          return ContentDialog(
            title: "Delete".tl,
            content: Column(
              children: [
                CheckboxListTile(
                  title: Text("Remove local favorite and history".tl),
                  value: removeFavoriteAndHistory,
                  onChanged: (v) {
                    state(() {
                      removeFavoriteAndHistory = !removeFavoriteAndHistory;
                    });
                  },
                ),
                CheckboxListTile(
                  title: Text("Also remove files on disk".tl),
                  value: removeComicFile,
                  onChanged: (v) {
                    state(() {
                      removeComicFile = !removeComicFile;
                    });
                  },
                )
              ],
            ),
            actions: [
              if (comics.length == 1 && comics.first.hasChapters)
                TextButton(
                  child: Text("Delete Chapters".tl),
                  onPressed: () {
                    context.pop();
                    showDeleteChaptersPopWindow(context, comics.first);
                  },
                ),
              FilledButton(
                onPressed: () {
                  context.pop();
                  LocalManager().batchDeleteComics(
                    comics,
                    removeComicFile,
                    removeFavoriteAndHistory,
                  );
                  isDeleted = true;
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        });
      },
    );
    return isDeleted;
  }

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () => _startExportTask(comics, ExportFormat.cbz),
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () => _startExportTask(comics, ExportFormat.pdf),
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () => _startExportTask(comics, ExportFormat.epub),
      )
    ];
  }
}

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  try {
    final folderPath = comic.baseDir;

    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      // For mobile platforms, use the URL launcher with file:// protocol
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(builder: (context, setState) {
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: comic.downloadedChapters.length,
                itemBuilder: (context, index) {
                  var id = comic.downloadedChapters[index];
                  var chapter = comic.chapters![id] ?? "Unknown Chapter";
                  return CheckboxListTile(
                    title: Text(chapter),
                    value: chapters.contains(id),
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          chapters.add(id);
                        } else {
                          chapters.remove(id);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  FilledButton(
                    onPressed: () {
                      Future.delayed(const Duration(milliseconds: 200), () {
                        LocalManager().deleteComicChapters(comic, chapters);
                      });
                      App.rootContext.pop();
                    },
                    child: Text("Submit".tl),
                  )
                ],
              ),
            )
          ],
        );
      }),
    ),
  );
}

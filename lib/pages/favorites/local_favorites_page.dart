part of 'favorites_page.dart';

const _localAllFolderLabel = '^_^[%local_all%]^_^';

/// Sort choice stored in implicit data. Each folder may override the
/// global value; a folder without an override follows it.
@visibleForTesting
abstract final class FavoriteFolderSort {
  static const globalKey = "local_favorites_sort";
  static const folderKey = "local_favorites_folder_sort";

  static LocalSortType read(Map<String, dynamic> data, String folder) {
    var map = data[folderKey];
    var value = map is Map ? map[folder] : null;
    return LocalSortType.fromString(value ?? data[globalKey] ?? "default");
  }

  static void setFolder(
    Map<String, dynamic> data,
    String folder,
    LocalSortType type,
  ) {
    _map(data)[folder] = type.value;
  }

  /// Applies [type] everywhere, dropping every folder override.
  static void setGlobal(Map<String, dynamic> data, LocalSortType type) {
    data[globalKey] = type.value;
    data.remove(folderKey);
  }

  /// Returns whether [data] changed.
  static bool rename(Map<String, dynamic> data, String before, String after) {
    var map = _map(data);
    if (!map.containsKey(before)) return false;
    map[after] = map.remove(before);
    return true;
  }

  /// Returns whether [data] changed.
  static bool remove(Map<String, dynamic> data, String folder) {
    return _map(data).remove(folder) != null;
  }

  static Map<String, dynamic> _map(Map<String, dynamic> data) {
    var stored = data[folderKey];
    if (stored is Map<String, dynamic>) return stored;
    var map = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    data[folderKey] = map;
    return map;
  }
}

/// If the number of comics in a folder exceeds this limit, it will be
/// fetched asynchronously.
const _asyncDataFetchLimit = 500;

/// Prepares keyword variants once, then matches each word across comic fields.
List<FavoriteItem> searchLocalFavorites(
  List<FavoriteItem> comics,
  String keyword,
) {
  if (keyword.trim().isEmpty) return comics;
  final hasUpper = keyword.contains(RegExp(r'[A-Z]'));
  final translateTags = App.locale.languageCode != 'en';
  final terms = keyword
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty)
      .map(
        (word) => {
          word,
          if (OpenCC.hasChineseSimplified(word))
            OpenCC.simplifiedToTraditional(word),
          if (OpenCC.hasChineseTraditional(word))
            OpenCC.traditionalToSimplified(word),
        },
      )
      .toList();

  bool matches(Set<String> variants, String text, {bool exact = false}) {
    final value = hasUpper ? text : text.toLowerCase();
    return variants.any((word) => exact ? value == word : value.contains(word));
  }

  return comics
      .where(
        (comic) => terms.every((variants) {
          if (matches(variants, comic.title) ||
              (comic.subtitle != null && matches(variants, comic.subtitle!))) {
            return true;
          }
          if (comic.tags.any(
            (tag) =>
                matches(variants, tag, exact: true) ||
                (tag.contains(':') &&
                    matches(variants, tag.split(':')[1], exact: true)) ||
                (translateTags &&
                    matches(variants, tag.translateTagsToCN, exact: true)),
          )) {
            return true;
          }
          return matches(variants, comic.author, exact: true);
        }),
      )
      .toList();
}

class _LocalFavoritesPage extends StatefulWidget {
  const _LocalFavoritesPage({required this.folder, super.key});

  final String folder;

  @override
  State<_LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<_LocalFavoritesPage>
    with SelectionMixin<_LocalFavoritesPage, Comic>, _LocalFavoritesActions {
  @override
  late _FavoritesPageState favPage;

  @override
  late List<FavoriteItem> comics;

  var filteredComics = <FavoriteItem>[];

  @override
  String? networkSource;
  @override
  String? networkFolder;

  @override
  var selectedLocalFolders = <String>{};

  @override
  late List<String> added = [];

  String keyword = "";

  bool searchMode = false;

  int? lastSelectedIndex;

  @override
  List<Comic> get selectableItems => visibleComics;

  @override
  bool get isAllFolder => widget.folder == _localAllFolderLabel;

  @override
  LocalFavoritesManager get manager => LocalFavoritesManager();

  bool isLoading = false;

  late String readFilterSelect;
  late String downloadFilterSelect;
  late Set<String> sourceFilterSelect;
  late Set<String> tagFilterSelect;
  late Set<String> authorFilterSelect;
  late bool tagMatchAll;
  late bool authorMatchAll;
  late LocalSortType favSortType;

  var searchResults = <FavoriteItem>[];

  void updateSearchResult() {
    setState(() {
      searchResults = searchLocalFavorites(comics, keyword);
    });
  }

  @override
  void updateComics() {
    if (isLoading) return;
    if (isAllFolder) {
      var totalComics = manager.totalComics;
      if (totalComics < _asyncDataFetchLimit) {
        comics = manager.getAllComics();
        updateFilteredComics();
      } else {
        isLoading = true;
        manager
            .getAllComicsAsync()
            .minTime(const Duration(milliseconds: 200))
            .then((value) {
              if (mounted) {
                setState(() {
                  isLoading = false;
                  comics = value;
                  updateFilteredComics();
                });
              }
            });
      }
    } else {
      var folderComics = manager.folderComics(widget.folder);
      if (folderComics < _asyncDataFetchLimit) {
        comics = manager.getFolderComics(widget.folder);
        updateFilteredComics();
      } else {
        isLoading = true;
        manager
            .getFolderComicsAsync(widget.folder)
            .minTime(const Duration(milliseconds: 200))
            .then((value) {
              if (mounted) {
                setState(() {
                  isLoading = false;
                  comics = value;
                  updateFilteredComics();
                });
              }
            });
      }
    }
    setState(() {});
  }

  @override
  List<FavoriteItem> filterComics(List<FavoriteItem> curComics) {
    return curComics.where((comic) {
      if (sourceFilterSelect.isNotEmpty &&
          !sourceFilterSelect.contains(comic.sourceKey)) {
        return false;
      }
      if (tagFilterSelect.isNotEmpty) {
        final comicTags = _resolveTags(comic).toSet();
        if (tagMatchAll) {
          for (var t in tagFilterSelect) {
            if (!comicTags.contains(t)) return false;
          }
        } else {
          if (!tagFilterSelect.any((t) => comicTags.contains(t))) return false;
        }
      }
      if (authorFilterSelect.isNotEmpty) {
        final comicAuthors = _resolveAuthors(comic).toSet();
        if (authorMatchAll) {
          for (var a in authorFilterSelect) {
            if (!comicAuthors.contains(a)) return false;
          }
        } else {
          if (!authorFilterSelect.any((a) => comicAuthors.contains(a))) {
            return false;
          }
        }
      }
      if (downloadFilterSelect != downloadFilterList[0]) {
        final isDownloaded = LocalManager().isDownloaded(comic.id, comic.type);
        if (downloadFilterSelect == "Downloaded" && !isDownloaded) {
          return false;
        }
        if (downloadFilterSelect == "Not Downloaded" && isDownloaded) {
          return false;
        }
      }
      var history = HistoryManager().find(
        comic.id,
        ComicType.fromKey(comic.sourceKey),
      );
      if (readFilterSelect == "UnCompleted") {
        return history == null || history.page != history.maxPage;
      } else if (readFilterSelect == "Completed") {
        return history != null && history.page == history.maxPage;
      }
      return true;
    }).toList();
  }

  /// Returns the comic's pure content tags. Prefers the new dedicated
  /// `tags` column (already prefix-stripped during favoriting); falls back
  /// to classifying the legacy mixed string list for rows that haven't been
  /// re-favorited since the schema upgrade.
  List<String> _resolveTags(FavoriteItem comic) {
    if (comic.tags.any((t) => t.contains(':'))) {
      // Legacy row — classify on the fly.
      return splitFavoriteTags(comic.tags).tags;
    }
    return comic.tags;
  }

  List<String> _resolveAuthors(FavoriteItem comic) {
    if (comic.authors.isNotEmpty) return comic.authors;
    // Legacy row — classify on the fly.
    return splitFavoriteTags(comic.tags).authors;
  }

  void updateFilteredComics() {
    filteredComics = filterComics(comics);
    _applySorting();
    // `searchResults` is a cached field, so a data change while searching (e.g.
    // a swipe-cancel or menu delete) must refresh it too — otherwise the
    // dismissed row lingers in the search view as a ghost.
    if (searchMode) {
      updateSearchResult();
    }
  }

  void _applySorting() {
    if (favSortType == LocalSortType.defaultSort) return;
    filteredComics.sort((a, b) {
      switch (favSortType) {
        case LocalSortType.name:
          return a.name.compareTo(b.name);
        case LocalSortType.nameDesc:
          return b.name.compareTo(a.name);
        case LocalSortType.timeDesc:
          return b.time.compareTo(a.time);
        case LocalSortType.timeAsc:
          return a.time.compareTo(b.time);
        case LocalSortType.author:
          return a.author.compareTo(b.author);
        case LocalSortType.lastRead:
          var historyA = HistoryManager().find(a.id, a.type);
          var historyB = HistoryManager().find(b.id, b.type);
          var timeA = historyA?.time ?? DateTime.fromMillisecondsSinceEpoch(0);
          var timeB = historyB?.time ?? DateTime.fromMillisecondsSinceEpoch(0);
          return timeB.compareTo(timeA);
        case LocalSortType.defaultSort:
          return 0;
      }
    });
  }

  void showSortDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "Sort".tl,
            content: RadioGroup<LocalSortType>(
              groupValue: favSortType,
              onChanged: (v) {
                setState(() {
                  favSortType = v ?? favSortType;
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
              TextButton(
                onPressed: () {
                  FavoriteFolderSort.setGlobal(
                    appdata.implicitData,
                    favSortType,
                  );
                  appdata.writeImplicitData();
                  Navigator.pop(context);
                  this.setState(() {
                    updateFilteredComics();
                  });
                },
                child: Text("Apply to All Folders".tl),
              ),
              FilledButton(
                onPressed: () {
                  FavoriteFolderSort.setFolder(
                    appdata.implicitData,
                    widget.folder,
                    favSortType,
                  );
                  appdata.writeImplicitData();
                  Navigator.pop(context);
                  this.setState(() {
                    updateFilteredComics();
                  });
                },
                child: Text("Confirm".tl),
              ),
            ],
          );
        });
      },
    );
  }

  List<FavoriteItem> get visibleComics {
    return searchMode ? searchResults : filteredComics;
  }

  List<String> get sourceFilterValues {
    var values = {
      ...comics.map((comic) => comic.sourceKey),
      ...sourceFilterSelect,
    }.toList();
    values.sort((a, b) => sourceFilterLabel(a).compareTo(sourceFilterLabel(b)));
    return values;
  }

  String sourceFilterLabel(String sourceKey) {
    if (sourceKey == 'local') {
      return 'Local'.tl;
    }
    if (sourceKey.startsWith('Unknown:')) {
      return sourceKey;
    }
    return ComicType.fromKey(sourceKey).comicSource?.name ?? sourceKey;
  }

  Set<String> parseSourceFilter(Object? value) {
    if (value is List) {
      return value.whereType<String>().toSet();
    }
    if (value is String && value != readFilterList[0]) {
      return {value};
    }
    return {};
  }

  /// Returns all tags appearing in current folder's comics with their counts,
  /// sorted by count desc, then name asc.
  List<MapEntry<String, int>> get tagFilterValues {
    final counts = <String, int>{};
    for (var c in comics) {
      for (var t in _resolveTags(c)) {
        if (t.isEmpty) continue;
        counts[t] = (counts[t] ?? 0) + 1;
      }
    }
    final list = counts.entries.toList();
    list.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return list;
  }

  /// Returns all authors appearing in current folder's comics with their
  /// counts, sorted by count desc, then name asc.
  List<MapEntry<String, int>> get authorFilterValues {
    final counts = <String, int>{};
    for (var c in comics) {
      for (var a in _resolveAuthors(c)) {
        if (a.isEmpty) continue;
        counts[a] = (counts[a] ?? 0) + 1;
      }
    }
    final list = counts.entries.toList();
    list.sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    return list;
  }

  Set<String> parseTagFilter(Object? value) {
    if (value is List) {
      return value.whereType<String>().toSet();
    }
    return {};
  }

  @override
  void initState() {
    readFilterSelect =
        appdata.implicitData["local_favorites_read_filter"] ??
        readFilterList[0];
    downloadFilterSelect =
        appdata.implicitData["local_favorites_download_filter"] ??
        downloadFilterList[0];
    sourceFilterSelect = parseSourceFilter(
      appdata.implicitData["local_favorites_source_filter"],
    );
    tagFilterSelect = parseTagFilter(
      appdata.implicitData["local_favorites_tag_filter"],
    );
    authorFilterSelect = parseTagFilter(
      appdata.implicitData["local_favorites_author_filter"],
    );
    tagMatchAll =
        appdata.implicitData["local_favorites_tag_match_all"] ?? false;
    authorMatchAll =
        appdata.implicitData["local_favorites_author_match_all"] ?? false;
    favSortType = FavoriteFolderSort.read(appdata.implicitData, widget.folder);
    favPage = context.findAncestorStateOfType<_FavoritesPageState>()!;
    if (!isAllFolder) {
      var (a, b) = LocalFavoritesManager().findLinked(widget.folder);
      networkSource = a;
      networkFolder = b;
    } else {
      networkSource = null;
      networkFolder = null;
    }
    comics = [];
    updateComics();
    LocalFavoritesManager().addListener(updateComics);
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    LocalFavoritesManager().removeListener(updateComics);
  }

  var scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    var title = favPage.folder ?? "Unselected".tl;
    if (title == _localAllFolderLabel) {
      title = "All".tl;
    }
    final currentComics = visibleComics;

    Widget body = SmoothCustomScrollView(
      controller: scrollController,
      scrollbarTopPadding: context.padding.top + 56,
      slivers: [
        if (!searchMode && !multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Folders".tl,
              child: context.width <= _kTwoPanelChangeWidth
                  ? IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: favPage.showFolderSelector,
                    )
                  : const SizedBox(),
            ),
            title: GestureDetector(
              onTap: context.width < _kTwoPanelChangeWidth
                  ? favPage.showFolderSelector
                  : null,
              child: Text(title),
            ),
            actions: [
              Tooltip(
                message: "Sort".tl,
                child: IconButton(
                  icon: const Icon(Icons.sort),
                  color: favSortType != LocalSortType.defaultSort
                      ? context.colorScheme.primaryContainer
                      : null,
                  onPressed: showSortDialog,
                ),
              ),
              Tooltip(
                message: "Filter".tl,
                child: IconButton(
                  icon: const Icon(Icons.filter_alt_outlined),
                  color:
                      readFilterSelect != readFilterList[0] ||
                          downloadFilterSelect != downloadFilterList[0] ||
                          sourceFilterSelect.isNotEmpty ||
                          tagFilterSelect.isNotEmpty ||
                          authorFilterSelect.isNotEmpty
                      ? context.colorScheme.primaryContainer
                      : null,
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        return _LocalFavoritesFilterDialog(
                          initReadFilterSelect: readFilterSelect,
                          initDownloadFilterSelect: downloadFilterSelect,
                          initSourceFilterSelect: sourceFilterSelect,
                          initTagFilterSelect: tagFilterSelect,
                          initAuthorFilterSelect: authorFilterSelect,
                          initTagMatchAll: tagMatchAll,
                          initAuthorMatchAll: authorMatchAll,
                          sourceFilterValues: sourceFilterValues,
                          sourceFilterLabel: sourceFilterLabel,
                          tagFilterValues: tagFilterValues,
                          authorFilterValues: authorFilterValues,
                          updateConfig:
                              (
                                readFilter,
                                downloadFilter,
                                sourceFilter,
                                tagFilter,
                                authorFilter,
                                newTagMatchAll,
                                newAuthorMatchAll,
                              ) {
                                setState(() {
                                  readFilterSelect = readFilter;
                                  downloadFilterSelect = downloadFilter;
                                  sourceFilterSelect = sourceFilter;
                                  tagFilterSelect = tagFilter;
                                  authorFilterSelect = authorFilter;
                                  tagMatchAll = newTagMatchAll;
                                  authorMatchAll = newAuthorMatchAll;
                                });
                                updateComics();
                              },
                        );
                      },
                    );
                  },
                ),
              ),
              Tooltip(
                message: "Search".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: () {
                    setState(() {
                      keyword = "";
                      searchMode = true;
                      updateSearchResult();
                    });
                  },
                ),
              ),
              MenuButton(
                entries: [
                  if (networkSource != null && !isAllFolder)
                    MenuEntry(
                      icon: Icons.sync,
                      text: "Sync".tl,
                      onClick: _showSyncDialog,
                    ),
                  MenuEntry(
                    icon: Icons.hub_outlined,
                    text: "Auto link comic sources".tl,
                    onClick: _showAutoLinkSourcesDialog,
                  ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.edit_outlined,
                      text: "Rename".tl,
                      onClick: () {
                        showInputDialog(
                          context: App.rootContext,
                          title: "Rename".tl,
                          hintText: "New Name".tl,
                          initialValue: widget.folder,
                          onConfirm: (value) {
                            // Pre-filled with the current name: confirming it
                            // unchanged is a no-op, not a "folder exists" error.
                            if (value.toString() == widget.folder) {
                              return null;
                            }
                            var err = validateFolderName(value.toString());
                            if (err != null) {
                              return err;
                            }
                            LocalFavoritesManager().rename(
                              widget.folder,
                              value.toString(),
                            );
                            if (FavoriteFolderSort.rename(
                              appdata.implicitData,
                              widget.folder,
                              value.toString(),
                            )) {
                              appdata.writeImplicitData();
                            }
                            favPage.folderList?.updateFolders();
                            favPage.setFolder(false, value.toString());
                            return null;
                          },
                        );
                      },
                    ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.reorder,
                      text: "Reorder".tl,
                      onClick: () {
                        context
                            .to(() {
                              return _ReorderComicsPage(widget.folder, (
                                comics,
                              ) {
                                this.comics = comics;
                              });
                            })
                            .then((value) {
                              if (mounted) {
                                setState(() {});
                              }
                            });
                      },
                    ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.upload_file,
                      text: "Export".tl,
                      onClick: () {
                        var json = LocalFavoritesManager().folderToJson(
                          widget.folder,
                        );
                        saveFile(
                          data: utf8.encode(json),
                          filename: "${widget.folder}.json",
                        );
                      },
                    ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.update,
                      text: "Update Comics Info".tl,
                      onClick: () {
                        updateComicsInfo(widget.folder).then((newComics) {
                          if (mounted) {
                            setState(() {
                              comics = newComics;
                            });
                          }
                        });
                      },
                    ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Folder".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        showConfirmDialog(
                          context: App.rootContext,
                          title: "Delete".tl,
                          content: "Delete folder '@f' ?".tlParams({
                            "f": widget.folder,
                          }),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            favPage.setFolder(false, null);
                            LocalFavoritesManager().deleteFolder(widget.folder);
                            if (FavoriteFolderSort.remove(
                              appdata.implicitData,
                              widget.folder,
                            )) {
                              appdata.writeImplicitData();
                            }
                            favPage.folderList?.updateFolders();
                          },
                        );
                      },
                    ),
                ],
              ),
            ],
          )
        else if (multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  exitSelectMode();
                },
              ),
            ),
            title: Text(
              "Selected @c comics".tlParams({"c": selectedItems.length}),
            ),
            actions: [
              MenuButton(
                entries: [
                  MenuEntry(
                    icon: Icons.drive_file_move,
                    text: "Move to folder".tl,
                    onClick: () => favoriteOption('move'),
                  ),
                  MenuEntry(
                    icon: Icons.copy,
                    text: "Copy to folder".tl,
                    onClick: () => favoriteOption('add'),
                  ),
                  MenuEntry(
                    icon: Icons.select_all,
                    text: "Select All".tl,
                    onClick: selectAll,
                  ),
                  MenuEntry(
                    icon: Icons.deselect,
                    text: "Deselect".tl,
                    onClick: _cancel,
                  ),
                  MenuEntry(
                    icon: Icons.flip,
                    text: "Invert Selection".tl,
                    onClick: invertSelection,
                  ),
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Comic".tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        showConfirmDialog(
                          context: context,
                          title: "Delete".tl,
                          content: "Delete @c comics?".tlParams({
                            "c": selectedItems.length,
                          }),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            _deleteComicWithId();
                          },
                        );
                      },
                    ),
                  // Building a collection out of the volumes sitting in one
                  // folder is the main way this feature gets used. Hidden when
                  // the selection contains a collection, since collections
                  // cannot nest.
                  if (!selectedItems.keys.any(
                    (e) =>
                        ComicCollectionStore.isCollectionSourceKey(e.sourceKey),
                  ))
                    MenuEntry(
                      icon: Icons.library_books_outlined,
                      text: "Add to collection".tl,
                      onClick: () {
                        final comics = selectedItems.keys.toList();
                        exitSelectMode();
                        showAddToCollectionDialog(context, comics);
                      },
                    ),
                  MenuEntry(
                    icon: Icons.download,
                    text: "Download".tl,
                    onClick: downloadSelected,
                  ),
                  MenuEntry(
                    icon: Icons.move_up_outlined,
                    text: "Migrate Source".tl,
                    onClick: () {
                      showBatchSourceMigrationDialog(
                        context,
                        folder: isAllFolder ? "All Comics".tl : widget.folder,
                        comics: selectedItems.keys
                            .map((e) => e as FavoriteItem)
                            .toList(),
                        onStarted: _cancel,
                      );
                    },
                  ),
                  if (selectedItems.length == 1)
                    MenuEntry(
                      icon: Icons.copy,
                      text: "Copy Title".tl,
                      onClick: () {
                        Clipboard.setData(
                          ClipboardData(text: selectedItems.keys.first.title),
                        );
                        context.showMessage(message: "Copied".tl);
                      },
                    ),
                  if (selectedItems.length == 1)
                    MenuEntry(
                      icon: Icons.chrome_reader_mode_outlined,
                      text: "Read".tl,
                      onClick: () {
                        final c = selectedItems.keys.first as FavoriteItem;
                        App.rootContext.to(
                          () => ReaderWithLoading(
                            id: c.id,
                            sourceKey: c.sourceKey,
                          ),
                        );
                      },
                    ),
                  if (selectedItems.length == 1)
                    MenuEntry(
                      icon: Icons.arrow_forward_ios,
                      text: "Jump to Detail".tl,
                      onClick: () {
                        final c = selectedItems.keys.first as FavoriteItem;
                        App.mainNavigatorKey?.currentContext?.to(
                          () => ComicPage(id: c.id, sourceKey: c.sourceKey),
                        );
                      },
                    ),
                ],
              ),
            ],
          )
        else if (searchMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    setState(() {
                      searchMode = false;
                    });
                  });
                },
              ),
            ),
            title: AppSearchField(
              autofocus: true,
              height: AppSearchField.toolbarHeight,
              onChanged: (v) {
                keyword = v;
                updateSearchResult();
              },
            ).paddingRight(8),
          ),
        if (isLoading)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200,
              child: const Center(child: CircularProgressIndicator()),
            ),
          )
        else
          SliverGridComics(
            comics: currentComics,
            selections: selectedItems,
            swipeActionBuilder: multiSelectMode
                ? null
                : (c) => (
                    start: null,
                    end: SwipePane(
                      dismissOnFullSwipe: true,
                      onFullSwipe: () =>
                          _removeFavoriteSwipe(c as FavoriteItem),
                      actions: [
                        SwipeAction(
                          icon: Icons.heart_broken_outlined,
                          label: "Cancel favorite".tl,
                          onPressed: () =>
                              _removeFavoriteSwipe(c as FavoriteItem),
                        ),
                      ],
                    ),
                  ),
            menuBuilder: (c) {
              return [
                if (!isAllFolder)
                  MenuEntry(
                    icon: Icons.delete,
                    text: "Delete".tl,
                    onClick: () {
                      LocalFavoritesManager().deleteComicWithId(
                        widget.folder,
                        c.id,
                        (c as FavoriteItem).type,
                      );
                    },
                  ),
                MenuEntry(
                  icon: Icons.check,
                  text: "Select".tl,
                  onClick: () {
                    setState(() {
                      if (!multiSelectMode) {
                        multiSelectMode = true;
                      }
                      if (selectedItems.containsKey(c as FavoriteItem)) {
                        selectedItems.remove(c);
                      } else {
                        selectedItems[c] = true;
                      }
                      lastSelectedIndex = currentComics.indexOf(c);
                      if (selectedItems.isEmpty) {
                        multiSelectMode = false;
                      }
                    });
                  },
                ),
                MenuEntry(
                  icon: Icons.drive_file_move,
                  text: "Move to folder".tl,
                  onClick: () {
                    selectedItems
                      ..clear()
                      ..[c as FavoriteItem] = true;
                    favoriteOption('move');
                  },
                ),
                MenuEntry(
                  icon: Icons.copy,
                  text: "Copy to folder".tl,
                  onClick: () {
                    selectedItems
                      ..clear()
                      ..[c as FavoriteItem] = true;
                    favoriteOption('add');
                  },
                ),
                MenuEntry(
                  icon: Icons.download,
                  text: "Download".tl,
                  onClick: () async {
                    if (await downloadComic(c as FavoriteItem)) {
                      App.rootContext.showMessage(
                        message: "Download started".tl,
                      );
                    }
                  },
                ),
                MenuEntry(
                  icon: Icons.move_up_outlined,
                  text: "Migrate Source".tl,
                  onClick: () {
                    showSourceMigrationDialog(context, c as FavoriteItem);
                  },
                ),
                if (appdata.settings["onClickFavorite"] == "viewDetail")
                  MenuEntry(
                    icon: Icons.menu_book_outlined,
                    text: "Read".tl,
                    onClick: () {
                      App.mainNavigatorKey?.currentContext?.to(
                        () =>
                            ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
                      );
                    },
                  ),
              ];
            },
            onTapWithIndex: (c, heroID, index) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedItems.containsKey(c as FavoriteItem)) {
                    selectedItems.remove(c);
                  } else {
                    selectedItems[c] = true;
                  }
                  lastSelectedIndex = index;
                  if (selectedItems.isEmpty) {
                    multiSelectMode = false;
                  }
                });
              } else if (appdata.settings["onClickFavorite"] == "viewDetail") {
                App.mainNavigatorKey?.currentContext?.to(
                  () => ComicPage(
                    id: c.id,
                    sourceKey: c.sourceKey,
                    cover: c.cover,
                    title: c.title,
                    heroID: heroID,
                  ),
                );
              } else {
                App.mainNavigatorKey?.currentContext?.to(
                  () => ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
                );
              }
            },
            onLongPressedWithIndex: (c, heroID, index) {
              setState(() {
                if (!multiSelectMode) {
                  multiSelectMode = true;
                  if (!selectedItems.containsKey(c as FavoriteItem)) {
                    selectedItems[c] = true;
                  }
                  lastSelectedIndex = index;
                } else {
                  if (lastSelectedIndex != null) {
                    int start = lastSelectedIndex!;
                    int end = index;
                    if (start > end) {
                      int temp = start;
                      start = end;
                      end = temp;
                    }

                    for (int i = start; i <= end; i++) {
                      if (i == lastSelectedIndex) continue;

                      var comic = currentComics[i];
                      if (selectedItems.containsKey(comic)) {
                        selectedItems.remove(comic);
                      } else {
                        selectedItems[comic] = true;
                      }
                    }
                  }
                  lastSelectedIndex = index;
                }
                if (selectedItems.isEmpty) {
                  multiSelectMode = false;
                }
              });
            },
          ),
      ],
    );
    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          exitSelectMode();
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            updateComics();
          });
        }
      },
      child: body,
    );
  }
}

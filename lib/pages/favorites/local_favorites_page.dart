part of 'favorites_page.dart';

const _localAllFolderLabel = '^_^[%local_all%]^_^';

/// If the number of comics in a folder exceeds this limit, it will be
/// fetched asynchronously.
const _asyncDataFetchLimit = 500;

class _LocalFavoritesPage extends StatefulWidget {
  const _LocalFavoritesPage({required this.folder, super.key});

  final String folder;

  @override
  State<_LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<_LocalFavoritesPage> {
  late _FavoritesPageState favPage;

  late List<FavoriteItem> comics;

  var filteredComics = <FavoriteItem>[];

  String? networkSource;
  String? networkFolder;

  Map<Comic, bool> selectedComics = {};

  var selectedLocalFolders = <String>{};

  late List<String> added = [];

  String keyword = "";
  bool searchHasUpper = false;

  bool searchMode = false;

  bool multiSelectMode = false;

  int? lastSelectedIndex;

  bool get isAllFolder => widget.folder == _localAllFolderLabel;

  LocalFavoritesManager get manager => LocalFavoritesManager();

  bool isLoading = false;

  late String readFilterSelect;
  late Set<String> sourceFilterSelect;
  late Set<String> tagFilterSelect;
  late Set<String> authorFilterSelect;
  late bool tagMatchAll;
  late bool authorMatchAll;
  late LocalSortType favSortType;

  var searchResults = <FavoriteItem>[];

  void updateSearchResult() {
    setState(() {
      if (keyword.trim().isEmpty) {
        searchResults = comics;
      } else {
        searchResults = [];
        for (var comic in comics) {
          if (matchKeyword(keyword, comic) ||
              matchKeywordT(keyword, comic) ||
              matchKeywordS(keyword, comic)) {
            searchResults.add(comic);
          }
        }
      }
    });
  }

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
              FilledButton(
                onPressed: () {
                  appdata.implicitData["local_favorites_sort"] =
                      favSortType.value;
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

  bool matchKeyword(String keyword, FavoriteItem comic) {
    var list = keyword.split(" ");
    for (var k in list) {
      if (k.isEmpty) continue;
      if (checkKeyWordMatch(k, comic.title, false)) {
        continue;
      } else if (comic.subtitle != null &&
          checkKeyWordMatch(k, comic.subtitle!, false)) {
        continue;
      } else if (comic.tags.any((tag) {
        if (checkKeyWordMatch(k, tag, true)) {
          return true;
        } else if (tag.contains(':') &&
            checkKeyWordMatch(k, tag.split(':')[1], true)) {
          return true;
        } else if (App.locale.languageCode != 'en' &&
            checkKeyWordMatch(k, tag.translateTagsToCN, true)) {
          return true;
        }
        return false;
      })) {
        continue;
      } else if (checkKeyWordMatch(k, comic.author, true)) {
        continue;
      }
      return false;
    }
    return true;
  }

  bool checkKeyWordMatch(String keyword, String compare, bool needEqual) {
    String temp = compare;
    // 没有大写的话, 就转成小写比较, 避免搜索需要注意大小写
    if (!searchHasUpper) {
      temp = temp.toLowerCase();
    }
    if (needEqual) {
      return keyword == temp;
    }
    return temp.contains(keyword);
  }

  // Convert keyword to traditional Chinese to match comics
  bool matchKeywordT(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseSimplified(keyword)) {
      return false;
    }
    keyword = OpenCC.simplifiedToTraditional(keyword);
    return matchKeyword(keyword, comic);
  }

  // Convert keyword to simplified Chinese to match comics
  bool matchKeywordS(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseTraditional(keyword)) {
      return false;
    }
    keyword = OpenCC.traditionalToSimplified(keyword);
    return matchKeyword(keyword, comic);
  }

  @override
  void initState() {
    readFilterSelect =
        appdata.implicitData["local_favorites_read_filter"] ??
        readFilterList[0];
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
    favSortType = LocalSortType.fromString(
      appdata.implicitData["local_favorites_sort"] ?? "default",
    );
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

  void selectAll() {
    setState(() {
      selectedComics = {for (final comic in visibleComics) comic: true};
    });
  }

  void invertSelection() {
    setState(() {
      for (var c in visibleComics) {
        if (selectedComics.containsKey(c)) {
          selectedComics.remove(c);
        } else {
          selectedComics[c] = true;
        }
      }
      if (selectedComics.isEmpty) {
        multiSelectMode = false;
      }
    });
  }

  bool downloadComic(FavoriteItem c) {
    if (App.isWeb) {
      return false;
    }
    var source = c.type.comicSource;
    if (source != null) {
      bool isDownloaded = LocalManager().isDownloaded(c.id, (c).type);
      if (isDownloaded) {
        return false;
      }
      LocalManager().addTask(
        ImagesDownloadTask(source: source, comicId: c.id, comicTitle: c.title),
      );
      return true;
    }
    return false;
  }

  void downloadSelected() {
    if (App.isWeb) {
      context.showMessage(message: "Download is not supported on WebPWA".tl);
      return;
    }
    int count = 0;
    for (var c in selectedComics.keys) {
      if (downloadComic(c as FavoriteItem)) {
        count++;
      }
    }
    if (count > 0) {
      context.showMessage(
        message: "Added @c comics to download queue.".tlParams({"c": count}),
      );
    }
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
              if (networkSource != null && !isAllFolder)
                Tooltip(
                  message: "Sync".tl,
                  child: Flyout(
                    flyoutBuilder: (context) {
                      final GlobalKey<_SelectUpdatePageNumState>
                      selectUpdatePageNumKey =
                          GlobalKey<_SelectUpdatePageNumState>();
                      var updatePageWidget = _SelectUpdatePageNum(
                        networkSource: networkSource!,
                        networkFolder: networkFolder,
                        key: selectUpdatePageNumKey,
                      );
                      return FlyoutContent(
                        title: "Sync".tl,
                        content: updatePageWidget,
                        actions: [
                          Button.filled(
                            child: Text("Update".tl),
                            onPressed: () {
                              context.pop();
                              importNetworkFolder(
                                networkSource!,
                                selectUpdatePageNumKey
                                    .currentState!
                                    .updatePageNum,
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
                    child: Builder(
                      builder: (context) {
                        return IconButton(
                          icon: const Icon(Icons.sync),
                          onPressed: () {
                            Flyout.of(context).show();
                          },
                        );
                      },
                    ),
                  ),
                ),
              Tooltip(
                message: "Auto link comic sources".tl,
                child: IconButton(
                  icon: const Icon(Icons.hub_outlined),
                  onPressed: _showAutoLinkSourcesDialog,
                ),
              ),
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
                                sourceFilter,
                                tagFilter,
                                authorFilter,
                                newTagMatchAll,
                                newAuthorMatchAll,
                              ) {
                                setState(() {
                                  readFilterSelect = readFilter;
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
              if (!isAllFolder)
                MenuButton(
                  entries: [
                    MenuEntry(
                      icon: Icons.edit_outlined,
                      text: "Rename".tl,
                      onClick: () {
                        showInputDialog(
                          context: App.rootContext,
                          title: "Rename".tl,
                          hintText: "New Name".tl,
                          onConfirm: (value) {
                            var err = validateFolderName(value.toString());
                            if (err != null) {
                              return err;
                            }
                            LocalFavoritesManager().rename(
                              widget.folder,
                              value.toString(),
                            );
                            favPage.folderList?.updateFolders();
                            favPage.setFolder(false, value.toString());
                            return null;
                          },
                        );
                      },
                    ),
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
                  setState(() {
                    multiSelectMode = false;
                    selectedComics.clear();
                  });
                },
              ),
            ),
            title: Text(
              "Selected @c comics".tlParams({"c": selectedComics.length}),
            ),
            actions: [
              MenuButton(
                entries: [
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.drive_file_move,
                      text: "Move to folder".tl,
                      onClick: () => favoriteOption('move'),
                    ),
                  if (!isAllFolder)
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
                            "c": selectedComics.length,
                          }),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            _deleteComicWithId();
                          },
                        );
                      },
                    ),
                  if (!App.isWeb)
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
                        comics: selectedComics.keys
                            .map((e) => e as FavoriteItem)
                            .toList(),
                        onStarted: _cancel,
                      );
                    },
                  ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.copy,
                      text: "Copy Title".tl,
                      onClick: () {
                        Clipboard.setData(
                          ClipboardData(text: selectedComics.keys.first.title),
                        );
                        context.showMessage(message: "Copied".tl);
                      },
                    ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.chrome_reader_mode_outlined,
                      text: "Read".tl,
                      onClick: () {
                        final c = selectedComics.keys.first as FavoriteItem;
                        App.rootContext.to(
                          () => ReaderWithLoading(
                            id: c.id,
                            sourceKey: c.sourceKey,
                          ),
                        );
                      },
                    ),
                  if (selectedComics.length == 1)
                    MenuEntry(
                      icon: Icons.arrow_forward_ios,
                      text: "Jump to Detail".tl,
                      onClick: () {
                        final c = selectedComics.keys.first as FavoriteItem;
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
            title: TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: "Search".tl,
                border: UnderlineInputBorder(),
              ),
              onChanged: (v) {
                keyword = v;
                searchHasUpper = keyword.contains(RegExp(r'[A-Z]'));
                updateSearchResult();
              },
            ).paddingBottom(8).paddingRight(8),
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
            selections: selectedComics,
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
                      if (selectedComics.containsKey(c as FavoriteItem)) {
                        selectedComics.remove(c);
                      } else {
                        selectedComics[c] = true;
                      }
                      lastSelectedIndex = currentComics.indexOf(c);
                      if (selectedComics.isEmpty) {
                        multiSelectMode = false;
                      }
                    });
                  },
                ),
                if (!App.isWeb)
                  MenuEntry(
                    icon: Icons.download,
                    text: "Download".tl,
                    onClick: () {
                      if (downloadComic(c as FavoriteItem)) {
                        context.showMessage(message: "Download started".tl);
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
                  if (selectedComics.containsKey(c as FavoriteItem)) {
                    selectedComics.remove(c);
                  } else {
                    selectedComics[c] = true;
                  }
                  lastSelectedIndex = index;
                  if (selectedComics.isEmpty) {
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
                  if (!selectedComics.containsKey(c as FavoriteItem)) {
                    selectedComics[c] = true;
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
                      if (selectedComics.containsKey(comic)) {
                        selectedComics.remove(comic);
                      } else {
                        selectedComics[comic] = true;
                      }
                    }
                  }
                  lastSelectedIndex = index;
                }
                if (selectedComics.isEmpty) {
                  multiSelectMode = false;
                }
              });
            },
          ),
      ],
    );
    body = AppScrollBar(
      topPadding: 48,
      controller: scrollController,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: body,
      ),
    );
    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
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
    var targetFolders = LocalFavoritesManager().folderNames
        .where((folder) => folder != favPage.folder)
        .toList();

    showPopUpWidget(
      App.rootContext,
      StatefulBuilder(
        builder: (context, setState) {
          return PopUpWidgetScaffold(
            title: favPage.folder ?? "Unselected".tl,
            body: Padding(
              padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
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
                          if (option == 'move') {
                            var comics = selectedComics.keys
                                .map((e) => e as FavoriteItem)
                                .toList();
                            for (var f in selectedLocalFolders) {
                              LocalFavoritesManager().batchMoveFavorites(
                                favPage.folder as String,
                                f,
                                comics,
                              );
                            }
                          } else {
                            var comics = selectedComics.keys
                                .map((e) => e as FavoriteItem)
                                .toList();
                            for (var f in selectedLocalFolders) {
                              LocalFavoritesManager().batchCopyFavorites(
                                favPage.folder as String,
                                f,
                                comics,
                              );
                            }
                          }
                          App.rootContext.pop();
                          updateComics();
                          _cancel();
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

  void _cancel() {
    setState(() {
      selectedComics.clear();
      multiSelectMode = false;
    });
  }

  void _deleteComicWithId() {
    var toBeDeleted = selectedComics.keys
        .map((e) => e as FavoriteItem)
        .toList();
    LocalFavoritesManager().batchDeleteComics(widget.folder, toBeDeleted);
    _cancel();
  }
}

class _ReorderComicsPage extends StatefulWidget {
  const _ReorderComicsPage(this.name, this.onReorder);

  final String name;

  final void Function(List<FavoriteItem>) onReorder;

  @override
  State<_ReorderComicsPage> createState() => _ReorderComicsPageState();
}

class _ReorderComicsPageState extends State<_ReorderComicsPage> {
  final _key = GlobalKey();
  var reorderWidgetKey = UniqueKey();
  final _scrollController = ScrollController();
  late var comics = LocalFavoritesManager().getFolderComics(widget.name);
  bool changed = false;

  static int _floatToInt8(double x) {
    return (x * 255.0).round() & 0xff;
  }

  Color lightenColor(Color color, double lightenValue) {
    int red = (_floatToInt8(color.r) + ((255 - color.r) * lightenValue))
        .round();
    int green = (_floatToInt8(color.g) * 255 + ((255 - color.g) * lightenValue))
        .round();
    int blue = (_floatToInt8(color.b) * 255 + ((255 - color.b) * lightenValue))
        .round();

    return Color.fromARGB(_floatToInt8(color.a), red, green, blue);
  }

  @override
  void dispose() {
    if (changed) {
      // Delay to ensure navigation is completed
      Future.delayed(const Duration(milliseconds: 200), () {
        LocalFavoritesManager().reorder(comics, widget.name);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicDisplayMode'];
    var tiles = comics.map((e) {
      var comicSource = e.type.comicSource;
      return ComicTile(
        key: Key(e.hashCode.toString()),
        enableLongPressed: false,
        comic: Comic(
          e.name,
          e.coverPath,
          e.id,
          e.author,
          e.tags,
          type == 'detailed'
              ? "${e.time} | ${comicSource?.name ?? "Unknown"}"
              : "${e.type.comicSource?.name ?? "Unknown"} | ${e.time}",
          comicSource?.key ?? (e.type == ComicType.local ? "local" : "Unknown"),
          null,
          null,
        ),
      );
    }).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Reorder".tl),
        actions: [
          Tooltip(
            message: "Information".tl,
            child: IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                showInfoDialog(
                  context: context,
                  title: "Reorder".tl,
                  content: "Long press and drag to reorder.".tl,
                );
              },
            ),
          ),
          Tooltip(
            message: "Reverse".tl,
            child: IconButton(
              icon: const Icon(Icons.swap_vert),
              onPressed: () {
                setState(() {
                  comics = comics.reversed.toList();
                  changed = true;
                });
              },
            ),
          ),
        ],
      ),
      body: ReorderableBuilder<FavoriteItem>(
        key: reorderWidgetKey,
        scrollController: _scrollController,
        longPressDelay: App.isDesktop
            ? const Duration(milliseconds: 100)
            : const Duration(milliseconds: 500),
        onReorder: (reorderFunc) {
          changed = true;
          setState(() {
            comics = reorderFunc(comics);
          });
          widget.onReorder(comics);
        },
        dragChildBoxDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: lightenColor(
            Theme.of(context).splashColor.withAlpha(255),
            0.2,
          ),
        ),
        builder: (children) {
          return GridView(
            key: _key,
            controller: _scrollController,
            gridDelegate: SliverGridDelegateWithComics(),
            children: children,
          );
        },
        children: tiles,
      ),
    );
  }
}

class _SelectUpdatePageNum extends StatefulWidget {
  const _SelectUpdatePageNum({
    required this.networkSource,
    this.networkFolder,
    super.key,
  });

  final String? networkFolder;
  final String networkSource;

  @override
  State<_SelectUpdatePageNum> createState() => _SelectUpdatePageNumState();
}

class _SelectUpdatePageNumState extends State<_SelectUpdatePageNum> {
  int updatePageNum = 9999999;

  String get _allPageText => 'All'.tl;

  List<String> get pageNumList => [
    '1',
    '2',
    '3',
    '5',
    '10',
    '20',
    '50',
    '100',
    '200',
    _allPageText,
  ];

  @override
  void initState() {
    updatePageNum =
        appdata.implicitData["local_favorites_update_page_num"] ?? 9999999;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var source = ComicSource.find(widget.networkSource);
    var sourceName = source?.name ?? widget.networkSource;
    var text = "The folder is Linked to @source".tlParams({
      "source": sourceName,
    });
    if (widget.networkFolder != null && widget.networkFolder!.isNotEmpty) {
      text += "\n${"Source Folder".tl}: ${widget.networkFolder}";
    }

    return Column(
      children: [
        Row(children: [Text(text)]),
        Row(
          children: [
            Text("Update the page number by the latest collection".tl),
            Spacer(),
            Select(
              current: updatePageNum.toString() == '9999999'
                  ? _allPageText
                  : updatePageNum.toString(),
              values: pageNumList,
              minWidth: 48,
              onTap: (index) {
                setState(() {
                  updatePageNum = int.parse(
                    pageNumList[index] == _allPageText
                        ? '9999999'
                        : pageNumList[index],
                  );
                  appdata.implicitData["local_favorites_update_page_num"] =
                      updatePageNum;
                  appdata.writeImplicitData();
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _LocalFavoritesFilterDialog extends StatefulWidget {
  const _LocalFavoritesFilterDialog({
    required this.initReadFilterSelect,
    required this.initSourceFilterSelect,
    required this.initTagFilterSelect,
    required this.initAuthorFilterSelect,
    required this.initTagMatchAll,
    required this.initAuthorMatchAll,
    required this.sourceFilterValues,
    required this.sourceFilterLabel,
    required this.tagFilterValues,
    required this.authorFilterValues,
    required this.updateConfig,
  });

  final String initReadFilterSelect;
  final Set<String> initSourceFilterSelect;
  final Set<String> initTagFilterSelect;
  final Set<String> initAuthorFilterSelect;
  final bool initTagMatchAll;
  final bool initAuthorMatchAll;
  final List<String> sourceFilterValues;
  final String Function(String sourceKey) sourceFilterLabel;
  final List<MapEntry<String, int>> tagFilterValues;
  final List<MapEntry<String, int>> authorFilterValues;
  final void Function(
    String readFilter,
    Set<String> sourceFilter,
    Set<String> tagFilter,
    Set<String> authorFilter,
    bool tagMatchAll,
    bool authorMatchAll,
  )
  updateConfig;

  @override
  State<_LocalFavoritesFilterDialog> createState() =>
      _LocalFavoritesFilterDialogState();
}

const readFilterList = ['All', 'UnCompleted', 'Completed'];

class _LocalFavoritesFilterDialogState
    extends State<_LocalFavoritesFilterDialog> {
  late var readFilter = widget.initReadFilterSelect;
  late var sourceFilter = {...widget.initSourceFilterSelect};
  late var tagFilter = {...widget.initTagFilterSelect};
  late var authorFilter = {...widget.initAuthorFilterSelect};
  late bool tagMatchAll = widget.initTagMatchAll;
  late bool authorMatchAll = widget.initAuthorMatchAll;
  String tagSearch = "";
  String authorSearch = "";
  bool sourceExpanded = false;
  bool tagExpanded = false;
  bool authorExpanded = false;

  @override
  void initState() {
    super.initState();
    sourceExpanded = sourceFilter.isNotEmpty;
    tagExpanded = tagFilter.isNotEmpty;
    authorExpanded = authorFilter.isNotEmpty;
  }

  Widget _buildSection({
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget Function() childBuilder,
    String? badge,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (badge != null && badge.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: context.colorScheme.primary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
          ),
        ),
        if (expanded) childBuilder(),
      ],
    );
  }


  Widget _buildChipSection({
    required List<MapEntry<String, int>> values,
    required Set<String> selected,
    required String search,
    required ValueChanged<String> onSearchChanged,
    required void Function(String tag, bool sel) onSelectChanged,
    required String emptyText,
    required String emptyMatchText,
    required String searchHint,
    required bool matchAll,
    required ValueChanged<bool> onMatchModeChanged,
  }) {
    final filtered = search.trim().isEmpty
        ? values
        : values
              .where(
                (e) => e.key.toLowerCase().contains(
                  search.trim().toLowerCase(),
                ),
              )
              .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: values.length > 8
                      ? TextField(
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: searchHint,
                            prefixIcon: const Icon(Icons.search, size: 18),
                            border: const OutlineInputBorder(),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                          ),
                          onChanged: onSearchChanged,
                        )
                      : const SizedBox.shrink(),
                ),
                if (values.length > 8) const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => onMatchModeChanged(!matchAll),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: matchAll
                          ? context.colorScheme.primaryContainer
                          : null,
                      border: Border.all(
                        color: matchAll
                            ? context.colorScheme.primary
                            : context.colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      matchAll ? "Match all".tl : "Match any".tl,
                      style: TextStyle(
                        fontSize: 12,
                        color: matchAll
                            ? context.colorScheme.primary
                            : context.colorScheme.outline,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (values.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                emptyText,
                style: TextStyle(color: context.colorScheme.outline),
              ),
            )
          else if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                emptyMatchText,
                style: TextStyle(color: context.colorScheme.outline),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: filtered.map((entry) {
                final isSel = selected.contains(entry.key);
                return FilterChip(
                  label: Text("${entry.key} (${entry.value})"),
                  selected: isSel,
                  onSelected: (s) => onSelectChanged(entry.key, s),
                );
              }).toList(),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Filter".tl,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text("Filter reading status".tl),
                trailing: Select(
                  current: readFilter.tl,
                  values: readFilterList.map((e) => e.tl).toList(),
                  minWidth: 64,
                  onTap: (index) {
                    setState(() {
                      readFilter = readFilterList[index];
                    });
                  },
                ),
              ),
              const Divider(height: 1),
              _buildSection(
                title: "Filter comic source".tl,
                expanded: sourceExpanded,
                badge: sourceFilter.isEmpty ? null : "${sourceFilter.length}",
                onToggle: () =>
                    setState(() => sourceExpanded = !sourceExpanded),
                childBuilder: () => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: widget.sourceFilterValues.map((sourceKey) {
                    return CheckboxListTile(
                      dense: true,
                      title: Text(widget.sourceFilterLabel(sourceKey)),
                      value: sourceFilter.contains(sourceKey),
                      onChanged: (checked) {
                        setState(() {
                          if (checked ?? false) {
                            sourceFilter.add(sourceKey);
                          } else {
                            sourceFilter.remove(sourceKey);
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 1),
              _buildSection(
                title: "Filter authors".tl,
                expanded: authorExpanded,
                badge: authorFilter.isEmpty
                    ? null
                    : "${authorFilter.length}",
                onToggle: () =>
                    setState(() => authorExpanded = !authorExpanded),
                childBuilder: () => _buildChipSection(
                  values: widget.authorFilterValues,
                  selected: authorFilter,
                  search: authorSearch,
                  onSearchChanged: (v) =>
                      setState(() => authorSearch = v),
                  onSelectChanged: (a, sel) => setState(() {
                    if (sel) {
                      authorFilter.add(a);
                    } else {
                      authorFilter.remove(a);
                    }
                  }),
                  emptyText: "No authors".tl,
                  emptyMatchText: "No matched authors".tl,
                  searchHint: "Search authors".tl,
                  matchAll: authorMatchAll,
                  onMatchModeChanged: (v) =>
                      setState(() => authorMatchAll = v),
                ),
              ),
              const Divider(height: 1),
              _buildSection(
                title: "Filter tags".tl,
                expanded: tagExpanded,
                badge: tagFilter.isEmpty ? null : "${tagFilter.length}",
                onToggle: () => setState(() => tagExpanded = !tagExpanded),
                childBuilder: () => _buildChipSection(
                  values: widget.tagFilterValues,
                  selected: tagFilter,
                  search: tagSearch,
                  onSearchChanged: (v) =>
                      setState(() => tagSearch = v),
                  onSelectChanged: (t, sel) => setState(() {
                    if (sel) {
                      tagFilter.add(t);
                    } else {
                      tagFilter.remove(t);
                    }
                  }),
                  emptyText: "No tags".tl,
                  emptyMatchText: "No matched tags".tl,
                  searchHint: "Search tags".tl,
                  matchAll: tagMatchAll,
                  onMatchModeChanged: (v) =>
                      setState(() => tagMatchAll = v),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            setState(() {
              readFilter = readFilterList[0];
              sourceFilter.clear();
              tagFilter.clear();
              authorFilter.clear();
              tagSearch = "";
              authorSearch = "";
            });
          },
          child: Text("Reset".tl),
        ),
        FilledButton(
          onPressed: () {
            appdata.implicitData["local_favorites_read_filter"] = readFilter;
            appdata.implicitData["local_favorites_source_filter"] = sourceFilter
                .toList();
            appdata.implicitData["local_favorites_tag_filter"] = tagFilter
                .toList();
            appdata.implicitData["local_favorites_author_filter"] =
                authorFilter.toList();
            appdata.implicitData["local_favorites_tag_match_all"] = tagMatchAll;
            appdata.implicitData["local_favorites_author_match_all"] =
                authorMatchAll;
            appdata.writeImplicitData();
            if (mounted) {
              Navigator.pop(context);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                widget.updateConfig(
                  readFilter,
                  Set<String>.from(sourceFilter),
                  Set<String>.from(tagFilter),
                  Set<String>.from(authorFilter),
                  tagMatchAll,
                  authorMatchAll,
                );
              });
            }
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}

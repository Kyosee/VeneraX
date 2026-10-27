part of 'components.dart';

class ComicList extends StatefulWidget {
  const ComicList({
    super.key,
    this.loadPage,
    this.loadNext,
    this.leadingSliver,
    this.trailingSliver,
    this.errorLeading,
    this.menuBuilder,
    this.controller,
    this.refreshHandlerCallback,
    this.selectionHandlerCallback,
    this.onSelectionStateChanged,
    this.enablePageStorage = false,
    this.enableSelection = false,
    this.scrollbar = true,
    this.scrollbarTopPadding = 0,
  });

  final Future<Res<List<Comic>>> Function(int page)? loadPage;

  final Future<Res<List<Comic>>> Function(String? next)? loadNext;

  final Widget? leadingSliver;

  final Widget? trailingSliver;

  final Widget? errorLeading;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final ScrollController? controller;

  final void Function(VoidCallback c)? refreshHandlerCallback;

  /// Receives a callback the host can invoke to enter multi-select mode (e.g.
  /// from a toolbar button), since long-press isn't discoverable for everyone.
  /// Only meaningful together with [enableSelection].
  final void Function(VoidCallback enterSelection)? selectionHandlerCallback;

  /// Fires with the new selecting state whenever multi-select is entered or
  /// exited. Hosts with their own app bar use it to hide that bar while the
  /// grid shows its selection bar, avoiding two stacked bars.
  final void Function(bool selecting)? onSelectionStateChanged;

  final bool enablePageStorage;

  /// When true, comics can be multi-selected (via the long-press menu or the
  /// host's [selectionHandlerCallback] button) to batch-favorite them; on
  /// mobile, a left-swipe quick-favorites a single comic to the configured
  /// Quick Favorite folder. Off by default so other ComicList pages are
  /// unaffected.
  final bool enableSelection;

  /// Whether to overlay a draggable [AppScrollBar] for fast scrolling. On by
  /// default since every ComicList is a top-level comic grid.
  final bool scrollbar;

  /// Top inset for the scrollbar thumb so it clears a top app bar (e.g. a
  /// pinned [Appbar] when [Scaffold.extendBodyBehindAppBar] is used).
  final double scrollbarTopPadding;

  @override
  State<ComicList> createState() => ComicListState();
}

class ComicListState extends State<ComicList> {
  int? _maxPage;

  final Map<int, List<Comic>> _data = {};

  int _page = 1;

  String? _error;

  final Map<int, bool> _loading = {};

  String? _nextUrl;

  late bool enablePageStorage = widget.enablePageStorage;

  // ---- Multi-select (only active when widget.enableSelection) ----
  bool _selecting = false;
  final Map<Comic, bool> _selected = {};

  /// Comics currently loaded: the current page in paging mode, every loaded
  /// page in continuous mode. "Select all" is necessarily limited to these —
  /// results on not-yet-loaded pages can't be selected without fetching them.
  List<Comic> get _loadedComics {
    final mode = appdata.settings['comicListDisplayMode'];
    if (mode == 'paging') return _data[_page] ?? const [];
    return _data.values.expand((e) => e).toList();
  }

  void _enterSelect(Comic c) {
    setState(() {
      _selecting = true;
      _selected[c] = true;
    });
    widget.onSelectionStateChanged?.call(true);
  }

  void _toggleSelect(Comic c) {
    setState(() {
      // remove() returns null when the key was absent → it wasn't selected.
      if (_selected.remove(c) == null) {
        _selected[c] = true;
      }
    });
  }

  void _exitSelect() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
    widget.onSelectionStateChanged?.call(false);
  }

  /// Enter selection mode without pre-selecting any comic — used by the host's
  /// toolbar button (long-press isn't discoverable for everyone).
  void _enterSelectMode() {
    if (_selecting) return;
    setState(() => _selecting = true);
    widget.onSelectionStateChanged?.call(true);
  }

  /// Quick-favorite [comic] to the configured Quick Favorite folder
  /// (Settings → Local Favorites → Quick Favorite). Falls back to the folder
  /// picker when it isn't set or the folder no longer exists.
  void _quickFavorite(Comic comic) {
    final folder = appdata.settings['quickFavorite'];
    if (folder is! String ||
        folder.isEmpty ||
        !LocalFavoritesManager().folderNames.contains(folder)) {
      addFavorite([comic]);
      return;
    }
    final ok = LocalFavoritesManager().addComic(
      folder,
      favoriteItemFromComic(comic),
    );
    App.rootContext.showMessage(
      message: ok ? "Added to favorites".tl : "Already in favorites".tl,
    );
  }

  /// Remove [comic] from every favorite folder it belongs to.
  void _removeAllFavorites(Comic comic) => _removeAllFavoritesOf([comic]);

  /// Remove each of [comics] from every favorite folder it belongs to.
  void _removeAllFavoritesOf(List<Comic> comics) {
    LocalFavoritesManager().batchDeleteComicsInAllFolders([
      for (final c in comics) ComicID(ComicType.fromKey(c.sourceKey), c.id),
    ]);
    App.rootContext.showMessage(message: "Removed from favorites".tl);
  }

  /// Swipe panes for a grid tile. Mobile only (gated in SliverGridComics).
  ///
  /// Left swipe reveals "Add to collection" then "Add to favorites" (orange,
  /// at the trailing edge); a large left swipe quick-favorites to the
  /// configured folder without a tap. When the comic is already favorited, a
  /// right swipe reveals a red "Cancel favorite" that clears every folder, and
  /// a large right swipe does it without a tap. Neither full swipe removes the
  /// tile — these lists aren't the item's home.
  SwipePanes _favoriteSwipePanes(Comic comic) {
    final favorited = LocalFavoritesManager().isExist(
      comic.id,
      ComicType.fromKey(comic.sourceKey),
    );
    final canCollect =
        !ComicCollectionStore.isCollectionSourceKey(comic.sourceKey);
    return (
      start: favorited
          ? SwipePane(
              extentRatio: 0.3,
              dismissOnFullSwipe: true,
              keepItemOnFullSwipe: true,
              // Clear gap below so resting to reveal the button doesn't trip
              // the quick-cancel.
              dismissThreshold: 0.7,
              onFullSwipe: () => _removeAllFavorites(comic),
              actions: [
                SwipeAction(
                  icon: Icons.heart_broken_outlined,
                  label: "Cancel favorite".tl,
                  onPressed: () => _removeAllFavorites(comic),
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                ),
              ],
            )
          : null,
      end: SwipePane(
        extentRatio: canCollect ? 0.5 : 0.3,
        dismissOnFullSwipe: true,
        keepItemOnFullSwipe: true,
        dismissThreshold: 0.7,
        onFullSwipe: () => _quickFavorite(comic),
        actions: [
          // Collection sits on the leading side; a collection can't nest.
          if (canCollect)
            SwipeAction(
              icon: Icons.library_books_outlined,
              label: "Add to collection".tl,
              onPressed: () => showAddToCollectionDialog(context, [comic]),
              backgroundColor: context.colorScheme.secondaryContainer,
              foregroundColor: context.colorScheme.onSecondaryContainer,
            ),
          // Favorite sits at the trailing edge, in the common orange.
          SwipeAction(
            icon: Icons.favorite_outline,
            label: "Add to favorites".tl,
            onPressed: () => addFavorite([comic]),
            backgroundColor: const Color(0xFFFF9800),
            foregroundColor: Colors.white,
          ),
        ],
      ),
    );
  }

  List<MenuEntry> _menuBuilderWithSelect(Comic c) {
    return [
      MenuEntry(
        icon: Icons.checklist,
        text: "Multi-Select".tl,
        onClick: () => _enterSelect(c),
      ),
      ...?widget.menuBuilder?.call(c),
    ];
  }

  /// Overflow menu for the multi-select bar: batch favorite, file into a
  /// collection, or clear from all folders. Each action no-ops on an empty
  /// selection.
  Widget _buildSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.favorite_outline,
          text: "Add to favorites".tl,
          onClick: () {
            if (_selected.isEmpty) return;
            addFavorite(_selected.keys.toList());
            _exitSelect();
          },
        ),
        // The batch path is the main way a collection gets built: pick the
        // three volumes of one story, then file them together in one step.
        MenuEntry(
          icon: Icons.library_books_outlined,
          text: "Add to collection".tl,
          onClick: () {
            if (_selected.isEmpty) return;
            showAddToCollectionDialog(context, _selected.keys.toList());
            _exitSelect();
          },
        ),
        // Undo a mis-tapped batch favorite: clear the selected comics from
        // every folder in one step.
        MenuEntry(
          icon: Icons.heart_broken_outlined,
          text: "Cancel favorite".tl,
          onClick: () {
            if (_selected.isEmpty) return;
            _removeAllFavoritesOf(_selected.keys.toList());
            _exitSelect();
          },
        ),
      ],
    );
  }

  Widget _buildSelectAppbar() {
    return SliverAppbar(
      leading: Tooltip(
        message: "Cancel".tl,
        child: IconButton(icon: const Icon(Icons.close), onPressed: _exitSelect),
      ),
      title: Text(_selected.length.toString()),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: "Select All".tl,
          onPressed: () => setState(() {
            for (final c in _loadedComics) {
              _selected[c] = true;
            }
          }),
        ),
        IconButton(
          icon: const Icon(Icons.deselect),
          tooltip: "Deselect".tl,
          onPressed: _selected.isEmpty
              ? null
              : () => setState(() => _selected.clear()),
        ),
        // Favorite / collection / unfavorite live in an overflow menu, like
        // the other multi-select pages, keeping the bar uncluttered.
        _buildSelectMenu(),
      ],
    );
  }

  /// SliverGridComics configured for the current (normal / selecting) mode.
  Widget _buildGrid(List<Comic> comics, {void Function()? onLastItemBuild}) {
    return SliverGridComics(
      comics: comics,
      onLastItemBuild: onLastItemBuild,
      menuBuilder: _selecting
          ? null
          : (widget.enableSelection
                ? _menuBuilderWithSelect
                : widget.menuBuilder),
      selections: _selecting ? _selected : null,
      onTapWithIndex:
          _selecting ? (comic, heroID, index) => _toggleSelect(comic) : null,
      swipeActionBuilder:
          (widget.enableSelection && !_selecting && App.isMobile)
          ? _favoriteSwipePanes
          : null,
    );
  }

  Map<String, dynamic> get state => {
    'maxPage': _maxPage,
    'data': _data,
    'page': _page,
    'error': _error,
    'loading': _loading,
    'nextUrl': _nextUrl,
  };

  void restoreState(Map<String, dynamic>? state) {
    if (state == null || !enablePageStorage) {
      return;
    }
    _maxPage = state['maxPage'];
    _data.clear();
    _data.addAll(state['data']);
    _page = state['page'];
    _error = state['error'];
    _loading.clear();
    _loading.addAll(state['loading']);
    _nextUrl = state['nextUrl'];
  }

  void storeState() {
    if (enablePageStorage) {
      PageStorage.of(context).writeState(context, state);
    }
  }

  void refresh() {
    _data.clear();
    _page = 1;
    _maxPage = null;
    _error = null;
    _nextUrl = null;
    _loading.clear();
    storeState();
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    restoreState(PageStorage.of(context).readState(context));
    widget.refreshHandlerCallback?.call(refresh);
    widget.selectionHandlerCallback?.call(_enterSelectMode);
  }

  void remove(Comic c) {
    if (_data[_page] == null || !_data[_page]!.remove(c)) {
      for (var page in _data.values) {
        if (page.remove(c)) {
          break;
        }
      }
    }
    setState(() {});
  }

  Widget _buildPageSelector() {
    return Row(
      children: [
        FilledButton(
          onPressed: _page > 1
              ? () {
                  setState(() {
                    _error = null;
                    _page--;
                  });
                }
              : null,
          child: Text("Back".tl),
        ).fixWidth(84),
        Expanded(
          child: Center(
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  String value = '';
                  showDialog(
                    context: App.rootContext,
                    builder: (context) {
                      return ContentDialog(
                        title: "Jump to page".tl,
                        content: TextField(
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: "Page".tl),
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onChanged: (v) {
                            value = v;
                          },
                        ).paddingHorizontal(16),
                        actions: [
                          Button.filled(
                            onPressed: () {
                              Navigator.of(context).pop();
                              var page = int.tryParse(value);
                              if (page == null) {
                                context.showMessage(message: "Invalid page".tl);
                              } else {
                                if (page > 0 &&
                                    (_maxPage == null || page <= _maxPage!)) {
                                  setState(() {
                                    _error = null;
                                    _page = page;
                                  });
                                } else {
                                  context.showMessage(
                                    message: "Invalid page".tl,
                                  );
                                }
                              }
                            },
                            child: Text("Jump".tl),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Text("Page $_page / ${_maxPage ?? '?'}"),
                ),
              ),
            ),
          ),
        ),
        FilledButton(
          onPressed: _page < (_maxPage ?? (_page + 1))
              ? () {
                  setState(() {
                    _error = null;
                    _page++;
                  });
                }
              : null,
          child: Text("Next".tl),
        ).fixWidth(84),
      ],
    ).paddingVertical(8).paddingHorizontal(16);
  }

  Widget _buildSliverPageSelector() {
    return SliverToBoxAdapter(child: _buildPageSelector());
  }

  Future<void> _loadPage(int page) async {
    if (widget.loadPage == null && widget.loadNext == null) {
      _error = "loadPage and loadNext can't be null at the same time";
      Future.microtask(() {
        setState(() {});
      });
    }
    if (_data[page] != null || _loading[page] == true) {
      return;
    }
    _loading[page] = true;
    try {
      if (widget.loadPage != null) {
        var res = await widget.loadPage!(page);
        if (!mounted) return;
        if (res.success) {
          if (res.data.isEmpty) {
            setState(() {
              _data[page] = const [];
              _maxPage ??= page;
            });
          } else {
            setState(() {
              _data[page] = res.data;
              if (res.subData != null && res.subData is int) {
                _maxPage = res.subData;
              }
            });
            _mirrorComicsToDomain(res.data);
          }
        } else {
          setState(() {
            _error = res.errorMessage ?? "Unknown error".tl;
          });
        }
      } else {
        try {
          while (_data[page] == null) {
            await _fetchNext();
          }
          if (mounted) {
            setState(() {});
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _error = e.toString();
            });
          }
        }
      }
    } finally {
      _loading[page] = false;
      storeState();
    }
  }

  Future<void> _fetchNext() async {
    var res = await widget.loadNext!(_nextUrl);
    _data[_data.length + 1] = res.data;
    if (res.subData == null) {
      _maxPage = _data.length;
    } else {
      _nextUrl = res.subData;
    }
  }

  void _mirrorComicsToDomain(List<Comic> comics) {
    Future.microtask(() {
      final repo = const ComicStateRepository();
      for (final comic in comics) {
        try {
          repo.mirrorComic(comic);
        } catch (_) {}
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicListDisplayMode'];
    Widget child = type == 'paging'
        ? buildPagingMode()
        : buildContinuousMode();
    if (widget.enableSelection) {
      // While selecting, the system back gesture / button cancels selection
      // instead of leaving the page.
      child = PopScope(
        canPop: !_selecting,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _selecting) _exitSelect();
        },
        child: child,
      );
    }
    return child;
  }

  Widget buildPagingMode() {
    if (_error != null) {
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          _buildPageSelector(),
          Expanded(
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
              },
            ),
          ),
        ],
      );
    }
    if (_data[_page] == null) {
      _loadPage(_page);
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: widget.controller,
      scrollbar: widget.scrollbar,
      scrollbarTopPadding: widget.scrollbarTopPadding,
      slivers: [
        if (_selecting)
          _buildSelectAppbar()
        else if (widget.leadingSliver != null)
          widget.leadingSliver!,
        if (_maxPage != 1) _buildSliverPageSelector(),
        _buildGrid(_data[_page] ?? const []),
        if (_data[_page]!.length > 6 && _maxPage != 1)
          _buildSliverPageSelector(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }

  Widget buildContinuousMode() {
    if (_error != null && _data.isEmpty) {
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          _buildPageSelector(),
          Expanded(
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
              },
            ),
          ),
        ],
      );
    }
    if (_data[1] == null) {
      _loadPage(1);
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: widget.controller,
      scrollbar: widget.scrollbar,
      scrollbarTopPadding: widget.scrollbarTopPadding,
      slivers: [
        if (_selecting)
          _buildSelectAppbar()
        else if (widget.leadingSliver != null)
          widget.leadingSliver!,
        _buildGrid(
          _data.values.expand((element) => element).toList(),
          onLastItemBuild: () {
            if (_error == null &&
                (_maxPage == null || _data.length < _maxPage!)) {
              _loadPage(_data.length + 1);
            }
          },
        ),
        if (_error != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.error_outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, maxLines: 3)),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _error = null;
                      });
                    },
                    child: Text("Retry".tl),
                  ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          )
        else if (_maxPage == null || _data.length < _maxPage!)
          const SliverListLoadingIndicator(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }
}

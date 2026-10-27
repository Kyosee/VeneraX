part of 'components.dart';

/// Collections whose cover warm-up has already been kicked off, so a list of
/// tiles rebuilding repeatedly fires one load per collection rather than one per
/// build. Not cleared: a successful warm-up writes a cover, and a failing one
/// would keep failing for the same reason.
final _warmingCollectionCovers = <String>{};

/// Marker colour for "already in a collection". Distinct from the favourite
/// (green), read-later (orange) and history (blue) badges so four states stay
/// tellable apart on one cover.
const _kCollectionStatusColor = Color(0xFF7E57C2);

/// Corner marker saying this comic already sits in at least one collection, so a
/// long list needn't be opened item by item to avoid filing something twice.
///
/// Watches the store instead of taking a flag captured at build time: filing a
/// comic from the very list showing it has to light up its marker with no
/// reload. Renders nothing when the comic is in no collection, so callers can
/// place it unconditionally.
class CollectionMemberMarker extends StatelessWidget {
  const CollectionMemberMarker({
    super.key,
    required this.sourceKey,
    required this.comicId,
    this.size = 13,
    this.padding = 3,
  });

  final String sourceKey;

  final String comicId;

  final double size;

  final double padding;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ComicCollectionStore.changes,
      builder: (context, _) {
        if (!ComicCollectionStore.isMember(sourceKey, comicId)) {
          return const SizedBox.shrink();
        }
        return Container(
          padding: EdgeInsets.all(padding),
          decoration: BoxDecoration(
            color: _kCollectionStatusColor.toOpacity(0.9),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            Icons.library_add_check_rounded,
            size: size,
            color: Colors.white,
          ),
        );
      },
    );
  }
}

/// Loads a collection's members once so their titles and covers land in the
/// store, then rebuilds the tiles that are waiting on it.
void _warmCollectionCover(String collectionId) {
  if (!_warmingCollectionCovers.add(collectionId)) return;
  Future.microtask(() async {
    final source = ComicSource.find(
      ComicCollectionStore.find(collectionId)?.sourceKey ?? '',
    );
    if (source?.loadComicInfo == null) return;
    try {
      // Going through the source rather than calling the loader directly keeps
      // this file free of a dependency on the collection source internals; the
      // load writes the member caches as a side effect, which is the point.
      await source!.loadComicInfo!(collectionId);
    } catch (e) {
      Log.error('ComicCollection', 'Cover warm-up failed: $e');
    }
    // cacheMemberInfo already pinged listeners if anything changed; nothing to
    // do here when the load found no new cover.
  });
}

/// Picks the loader for a comic's cover. Exposed for tests.
ImageProvider? findImageProvider(Comic comic) {
  ImageProvider image;
  // A collection's cover is resolved from the store, not from the passed-in
  // comic: a favourite or history row froze whatever the cover was when it was
  // recorded, which is empty when the collection was favourited before its
  // members had ever loaded. The store always holds the current one.
  if (ComicCollectionStore.isCollectionSourceKey(comic.sourceKey)) {
    final collection = ComicCollectionStore.find(comic.id);
    final cover = collection?.displayCover ?? comic.cover;
    if (cover.isEmpty) {
      // Nothing cached yet, which happens when a collection is favourited
      // before it has ever been opened. Warming it fills the member caches (and
      // so the cover) for the next build.
      if (collection != null && collection.members.isNotEmpty) {
        _warmCollectionCover(collection.id);
      }
      return null;
    }
    // The cover belongs to a member, so image loading has to go through the
    // collection's source to pick up that member's auth headers.
    return CachedImageProvider(
      cover,
      sourceKey: comic.sourceKey,
      cid: comic.id,
    );
  }
  if (comic is LocalComic) {
    // A queued download task merged into the grid has no directory on disk yet,
    // so its `cover` holds the remote url carried over from the list that
    // started it (see ImagesDownloadTask.toLocalComic) rather than a file name.
    if (comic.directory.isEmpty && comic.cover.isNotEmpty) {
      image = CachedImageProvider(
        comic.cover,
        sourceKey: comic.sourceKey,
        cid: comic.id,
      );
    } else {
      image = LocalComicImageProvider(comic);
    }
  } else if (comic is History) {
    image = HistoryImageProvider(comic);
  } else if (comic.sourceKey == 'local') {
    var localComic = LocalManager().find(comic.id, ComicType.local);
    if (localComic == null) {
      return null;
    }
    image = LocalComicImageProvider(localComic);
  } else {
    // Only this branch cannot recover from an empty cover: the downloader has
    // no url to fetch. Every branch above self-heals (local dir scan, history
    // re-fetch), so the check must not be hoisted out of here.
    final fallbackToLocalCover = comic is FavoriteItem;
    if (comic.cover.isEmpty && !fallbackToLocalCover) {
      return null;
    }
    image = CachedImageProvider(
      comic.cover,
      sourceKey: comic.sourceKey,
      cid: comic.id,
      fallbackToLocalCover: fallbackToLocalCover,
    );
  }
  return image;
}

class ComicTile extends StatelessWidget {
  const ComicTile({
    super.key,
    required this.comic,
    this.enableLongPressed = true,
    this.enableContextMenu = true,
    this.badge,
    this.menuOptions,
    this.onTap,
    this.onLongPressed,
    this.heroID,
  });

  final Comic comic;

  final bool enableLongPressed;

  final bool enableContextMenu;

  final String? badge;

  final List<MenuEntry>? menuOptions;

  final VoidCallback? onTap;

  final VoidCallback? onLongPressed;

  final int? heroID;

  static final _chapterProgressLoads =
      <String, Future<ComicChapterProgressInfo>>{};

  /// Badge text for the tile. A collection gets its own label instead of a
  /// source name (its members may come from several sources), so it is
  /// recognisable in a list without opening it. An explicit [badge] from the
  /// host still wins.
  String? get _effectiveBadge {
    if (badge != null) return badge;
    if (ComicCollectionStore.isCollectionSourceKey(comic.sourceKey)) {
      return 'Collection'.tl;
    }
    return null;
  }

  bool get _isCollection =>
      ComicCollectionStore.isCollectionSourceKey(comic.sourceKey);

  /// Whether this tile should say that the comic is already filed into a
  /// collection. Never for a collection itself — collections cannot nest, so
  /// the two markers share the same corner.
  bool get _showCollectionStatus =>
      !_isCollection && appdata.settings['showCollectionStatusOnTile'] == true;

  /// Whether the tile shows a page count. Never for a collection: its members
  /// each have their own count, so a single number there would be meaningless.
  bool get _showPageCount =>
      !_isCollection && appdata.settings['showPageCountOnTile'] == true;

  /// Corner marker drawn over the cover of a collection, in both display modes:
  /// the text badge only exists in detailed mode, and a cover marker is what
  /// makes a collection recognisable at a glance either way.
  Widget _buildCollectionMarker(BuildContext context, {double size = 13}) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.toOpacity(0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        Icons.library_books_outlined,
        size: size,
        color: Colors.white,
      ),
    );
  }

  Widget _buildCollectionStatusMarker({double size = 13}) =>
      CollectionMemberMarker(
        sourceKey: comic.sourceKey,
        comicId: comic.id,
        size: size,
      );

  void _onTap() {
    if (onTap != null) {
      onTap!();
      return;
    }
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
        heroID: heroID,
      ),
    );
  }

  void _onLongPressed(context) {
    if (onLongPressed != null) {
      onLongPressed!();
      return;
    }
    onLongPress(context);
  }

  void onLongPress(BuildContext context) {
    var renderBox = context.findRenderObject() as RenderBox;
    var size = renderBox.size;
    var location = renderBox.localToGlobal(
      Offset((size.width - 242) / 2, size.height / 2),
    );
    showMenu(location, context);
  }

  void onSecondaryTap(TapDownDetails details, BuildContext context) {
    showMenu(details.globalPosition, context);
  }

  void showMenu(Offset location, BuildContext context) {
    if (!enableContextMenu) return;
    showMenuX(App.rootContext, location, [
      MenuEntry(
        icon: Icons.chrome_reader_mode_outlined,
        text: 'Details'.tl,
        onClick: () {
          App.mainNavigatorKey?.currentContext?.to(
            () => ComicPage(
              id: comic.id,
              sourceKey: comic.sourceKey,
              cover: comic.cover,
              title: comic.title,
            ),
          );
        },
      ),
      MenuEntry(
        icon: Icons.copy,
        text: 'Copy Title'.tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.title));
          App.rootContext.showMessage(message: 'Title copied'.tl);
        },
      ),
      MenuEntry(
        icon: Icons.stars_outlined,
        text: 'Add to favorites'.tl,
        onClick: () {
          addFavorite([comic]);
        },
      ),
      // A collection cannot hold another collection, so the entry is hidden
      // rather than shown and refused.
      if (!ComicCollectionStore.isCollectionSourceKey(comic.sourceKey))
        MenuEntry(
          icon: Icons.library_books_outlined,
          text: 'Add to collection'.tl,
          onClick: () => showAddToCollectionDialog(context, [comic]),
        ),
      MenuEntry(
        icon: ReadLaterManager().isExist(comic.id, ComicType.fromKey(comic.sourceKey))
            ? Icons.bookmark_remove_outlined
            : Icons.watch_later_outlined,
        text: ReadLaterManager().isExist(comic.id, ComicType.fromKey(comic.sourceKey))
            ? 'Remove from read later'.tl
            : 'Read later'.tl,
        onClick: () async {
          final added = await ReadLaterManager().toggle(comic);
          App.rootContext.showMessage(
            message: added ? 'Added to read later'.tl : 'Removed from read later'.tl,
          );
        },
      ),
      // Cross-source linking and migration are meaningless for a collection: it
      // has no upstream source, and "migrating" it would search other sources
      // for its name and rebind it, silently discarding the grouping. Members
      // are still individually migratable from their own tiles.
      if (!_isCollection)
        MenuEntry(
          icon: Icons.hub_outlined,
          text: 'Linked entries'.tl,
          onClick: () => showRelatedSourcesDialog(context, comic),
        ),
      if (!_isCollection)
        MenuEntry(
          icon: Icons.move_up_outlined,
          text: 'Migrate Source'.tl,
          onClick: () =>
              showSourceMigrationDialog(context, favoriteItemFromComic(comic)),
        ),
      MenuEntry(
        icon: Icons.block,
        text: 'Block'.tl,
        onClick: () => block(context),
      ),
      ...?menuOptions,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicDisplayMode'];

    final comicType = ComicType.fromKey(comic.sourceKey);
    var isFavorite = appdata.settings['showFavoriteStatusOnTile']
        ? LocalFavoritesManager().isExist(comic.id, comicType)
        : false;
    var isReadLater = appdata.settings['showReadLaterStatusOnTile']
        ? ReadLaterManager().isExist(comic.id, comicType)
        : false;
    final showHistoryOnTile = appdata.settings['showHistoryStatusOnTile'];
    final history = showHistoryOnTile || type == 'detailed'
        ? HistoryManager().find(comic.id, comicType)
        : null;
    final tileHistory = showHistoryOnTile ? history : null;
    final chapterProgress = const ComicStateRepository().chapterProgressFor(
      comic,
      history,
    );
    if (tileHistory?.page == 0) {
      tileHistory!.page = 1;
    }

    Widget child = type == 'detailed'
        ? _buildDetailedMode(context, history, tileHistory, chapterProgress)
        : _buildBriefMode(context, tileHistory, chapterProgress);

    if (!isFavorite && !isReadLater && tileHistory == null) {
      return child;
    }

    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: type == 'detailed' ? 16 : 6,
          top: 8,
          child: Container(
            height: 24,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                if (isFavorite)
                  Container(
                    height: 24,
                    width: 24,
                    color: Colors.green,
                    child: const Icon(
                      Icons.bookmark_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                if (isReadLater)
                  Container(
                    height: 24,
                    width: 24,
                    color: Colors.orange,
                    child: const Icon(
                      Icons.watch_later_rounded,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                if (tileHistory != null)
                  Container(
                    height: 24,
                    color: Colors.blue.toOpacity(0.9),
                    constraints: const BoxConstraints(minWidth: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: CustomPaint(
                      painter: _ReadingHistoryPainter(
                        tileHistory.page,
                        tileHistory.maxPage,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEpisodeBadge(
    BuildContext context,
    ComicChapterProgressInfo chapterProgress,
    double maxWidth,
    History? history,
  ) {
    final syncBadge = _buildEpisodeBadgeContent(
      context,
      chapterProgress,
      maxWidth,
    );
    if (history == null ||
        comic.sourceKey == 'local' ||
        (chapterProgress.currentTitle != null &&
            chapterProgress.latestTitle != null) ||
        ComicSource.find(comic.sourceKey)?.loadComicInfo == null) {
      return syncBadge;
    }
    return FutureBuilder(
      future: _loadChapterProgress(chapterProgress, history),
      builder: (context, snapshot) {
        final asyncProgress = snapshot.data;
        if (asyncProgress == null || !asyncProgress.hasAny) {
          return syncBadge;
        }
        return _buildEpisodeBadgeContent(context, asyncProgress, maxWidth);
      },
    );
  }

  Future<ComicChapterProgressInfo> _loadChapterProgress(
    ComicChapterProgressInfo initialProgress,
    History history,
  ) {
    final key = [
      comic.sourceKey,
      comic.id,
      history.group ?? 0,
      history.ep,
      history.time.millisecondsSinceEpoch,
    ].join('\u0001');
    final cached = _chapterProgressLoads[key];
    if (cached != null) {
      return cached;
    }
    final future = _fetchChapterProgress(initialProgress, history);
    _chapterProgressLoads[key] = future;
    if (_chapterProgressLoads.length > 96) {
      _chapterProgressLoads.remove(_chapterProgressLoads.keys.first);
    }
    return future;
  }

  Future<ComicChapterProgressInfo> _fetchChapterProgress(
    ComicChapterProgressInfo initialProgress,
    History history,
  ) async {
    final source = ComicSource.find(comic.sourceKey);
    final loadComicInfo = source?.loadComicInfo;
    if (loadComicInfo == null) {
      return initialProgress;
    }
    try {
      final res = await loadComicInfo(comic.id);
      final details = res.dataOrNull;
      if (details == null) {
        return initialProgress;
      }
      const repository = ComicStateRepository();
      repository.mirrorComicDetails(details);
      final progress = repository.chapterProgressFromDetails(details, history);
      return progress.hasAny ? progress : initialProgress;
    } catch (e, s) {
      Log.error('Comic tile chapter progress', e, s);
      return initialProgress;
    }
  }

  Widget _buildEpisodeBadgeContent(
    BuildContext context,
    ComicChapterProgressInfo chapterProgress,
    double maxWidth,
  ) {
    if (!chapterProgress.hasAny) {
      return const SizedBox();
    }
    final fontSize = maxWidth < 80
        ? 8.0
        : maxWidth < 150
        ? 10.0
        : 12.0;
    final lines = [
      if (chapterProgress.currentTitle != null)
        '${'Current'.tl}: ${chapterProgress.currentTitle}',
      if (chapterProgress.latestTitle != null)
        '${'Latest'.tl}: ${chapterProgress.latestTitle}',
    ];
    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      margin: const EdgeInsets.fromLTRB(2, 0, 2, 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.blue.toOpacity(0.72),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Text(
              line,
              style: TextStyle(
                color: Colors.white,
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget buildImage(BuildContext context) {
    // A collection's cover comes from the store, which fills in asynchronously
    // the first time its members load. Listening here is what turns a blank
    // cover into the real one without the user leaving the page.
    if (_isCollection) {
      return ListenableBuilder(
        listenable: ComicCollectionStore.changes,
        builder: (context, _) => _buildImageNow(context),
      );
    }
    return _buildImageNow(context);
  }

  Widget _buildImageNow(BuildContext context) {
    var image = findImageProvider(comic);
    if (image == null) {
      return const SizedBox();
    }
    return AnimatedImage(
      image: image,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
    );
  }

  Widget _buildDetailedMode(
    BuildContext context,
    History? history,
    History? tileHistory,
    ComicChapterProgressInfo chapterProgress,
  ) {
    return LayoutBuilder(
      builder: (context, constrains) {
        final height = math.max(0.0, constrains.maxHeight - 28);
        final coverWidth = height * 0.68;
        final displayInfo = const ComicStateRepository().displayInfoFor(
          comic,
          badge: _effectiveBadge,
        );

        Widget image = Container(
          width: coverWidth,
          height: double.infinity,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: context.colorScheme.outlineVariant,
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Positioned.fill(child: buildImage(context)),
              Positioned(
                left: 2,
                bottom: 2,
                child: _buildEpisodeBadge(
                  context,
                  tileHistory == null
                      ? const ComicChapterProgressInfo()
                      : chapterProgress,
                  coverWidth - 4,
                  tileHistory,
                ),
              ),
              // Top-RIGHT: the tile's outer Stack overlays the favourite /
              // read-later / history badges at the top-left, which would cover
              // this marker on exactly the collections most likely to be
              // favourited.
              if (_isCollection)
                Positioned(
                  right: 3,
                  top: 3,
                  child: _buildCollectionMarker(context),
                )
              else if (_showCollectionStatus)
                Positioned(
                  right: 3,
                  top: 3,
                  child: _buildCollectionStatusMarker(),
                ),
            ],
          ),
        );

        if (heroID != null) {
          image = Hero(tag: "cover$heroID", child: image);
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: _onTap,
              onLongPress: enableLongPressed
                  ? () => _onLongPressed(context)
                  : null,
              onSecondaryTapDown: (detail) => onSecondaryTap(detail, context),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 14, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    image,
                    const SizedBox(width: 14),
                    Expanded(
                      child: ComicDescription(
                        title: displayInfo.title.replaceAll("\n", ""),
                        subtitle: displayInfo.author ?? '',
                        description: displayInfo.description ?? '',
                        badge: displayInfo.sourceName ?? comic.language,
                        tags: displayInfo.tags,
                        maxLines: 2,
                        enableTranslate:
                            ComicSource.find(
                              comic.sourceKey,
                            )?.enableTagsTranslate ??
                            false,
                        rating: displayInfo.rating,
                        updateText: displayInfo.updateTime,
                        statusText: displayInfo.status,
                        progressText: chapterProgress.currentTitle,
                        pagesText: _showPageCount
                            ? displayInfo.pagesText
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBriefMode(
    BuildContext context,
    History? history,
    ComicChapterProgressInfo chapterProgress,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        Widget image = Container(
          decoration: BoxDecoration(
            color: context.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.toOpacity(0.2),
                blurRadius: 2,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: buildImage(context),
        );

        if (heroID != null) {
          image = Hero(tag: "cover$heroID", child: image);
        }

        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _onTap,
          onLongPress: enableLongPressed ? () => _onLongPressed(context) : null,
          onSecondaryTapDown: (detail) => onSecondaryTap(detail, context),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: image),
                    // Top-right for the same reason as detailed mode: the outer
                    // Stack's status badges own the top-left corner.
                    if (_isCollection)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: _buildCollectionMarker(
                          context,
                          size: constraints.maxWidth < 80 ? 10 : 13,
                        ),
                      )
                    else if (_showCollectionStatus)
                      Positioned(
                        right: 4,
                        top: 4,
                        child: _buildCollectionStatusMarker(
                          size: constraints.maxWidth < 80 ? 10 : 13,
                        ),
                      ),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: (() {
                        final subtitle = comic.subtitle
                            ?.replaceAll('\n', '')
                            .trim();
                        final text = comic.description.isNotEmpty
                            ? comic.description.split('|').join('\n')
                            : (subtitle?.isNotEmpty == true ? subtitle : null);
                        final fortSize = constraints.maxWidth < 80
                            ? 8.0
                            : constraints.maxWidth < 150
                            ? 10.0
                            : 12.0;

                        var lines = text == null
                            ? <String>[]
                            : text.split('\n');
                        lines.removeWhere((e) => e.trim().isEmpty);
                        if (lines.length > 3) {
                          lines = lines.sublist(0, 3);
                        }
                        final pageCount = _showPageCount
                            ? const ComicStateRepository().quickPageCountFor(
                                comic,
                              )
                            : null;
                        // Prepended after the description was already trimmed to
                        // its 3 lines, so the count adds a line instead of
                        // costing one. Sources that already spell the count into
                        // the description would otherwise say it twice.
                        if (pageCount != null &&
                            !lines.any((e) => e.containsNumber(pageCount))) {
                          lines.insert(0, '${pageCount}P');
                        }

                        if (lines.isEmpty) {
                          return const SizedBox();
                        }

                        var children = <Widget>[];
                        for (var line in lines) {
                          children.add(
                            Container(
                              margin: const EdgeInsets.fromLTRB(2, 0, 2, 2),
                              padding: constraints.maxWidth < 80
                                  ? const EdgeInsets.fromLTRB(3, 1, 3, 1)
                                  : constraints.maxWidth < 150
                                  ? const EdgeInsets.fromLTRB(4, 2, 4, 2)
                                  : const EdgeInsets.fromLTRB(5, 2, 5, 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.black.toOpacity(0.5),
                              ),
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth,
                              ),
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: fortSize,
                                  color: Colors.white,
                                ),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: children,
                        );
                      })(),
                    ),
                    Positioned(
                      left: 2,
                      bottom: 2,
                      child: _buildEpisodeBadge(
                        context,
                        history == null
                            ? const ComicChapterProgressInfo()
                            : chapterProgress,
                        constraints.maxWidth * 0.72,
                        history,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text(
                  comic.title.replaceAll('\n', ''),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ).paddingHorizontal(6).paddingVertical(8),
        );
      },
    );
  }

  void block(BuildContext comicTileContext) {
    // A list item usually carries only a title and a cover — most sources fill
    // in tags on the detail request. Pull whatever tags the app already knows
    // (favorites / local library / mirrored details) so the picker isn't
    // limited to title fragments; without this, blocking by tag was impossible
    // from a search result.
    var knownTags = const ComicStateRepository().displayInfoFor(comic).tags;
    showBlockDialog(
      title: comic.title,
      subtitle: comic.subtitle,
      tags: knownTags.isEmpty ? (comic.tags ?? const []) : knownTags,
      onBlocked: () {
        comicTileContext
            .findAncestorStateOfType<_SliverGridComicsState>()
            ?.update();
      },
    );
  }
}

class _ReadingHistoryPainter extends CustomPainter {
  final int page;
  final int? maxPage;

  const _ReadingHistoryPainter(this.page, this.maxPage);

  @override
  void paint(Canvas canvas, Size size) {
    if (maxPage == null) {
      // 在中央绘制page
      final textPainter = TextPainter(
        text: TextSpan(
          text: "$page",
          style: TextStyle(fontSize: size.width * 0.8, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    } else if (page == maxPage) {
      // 在中央绘制勾
      final paint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(size.width * 0.2, size.height * 0.5),
        Offset(size.width * 0.45, size.height * 0.75),
        paint,
      );
      canvas.drawLine(
        Offset(size.width * 0.45, size.height * 0.75),
        Offset(size.width * 0.85, size.height * 0.3),
        paint,
      );
    } else {
      // 在左上角绘制page, 在右下角绘制maxPage
      final textPainter = TextPainter(
        text: TextSpan(
          text: "$page",
          style: TextStyle(fontSize: size.width * 0.8, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, const Offset(0, 0));
      final textPainter2 = TextPainter(
        text: TextSpan(
          text: "/$maxPage",
          style: TextStyle(fontSize: size.width * 0.5, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter2.layout();
      textPainter2.paint(
        canvas,
        Offset(
          size.width - textPainter2.width,
          size.height - textPainter2.height,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ReadingHistoryPainter ||
        oldDelegate.page != page ||
        oldDelegate.maxPage != maxPage;
  }
}

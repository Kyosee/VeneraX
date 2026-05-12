part of 'components.dart';

ImageProvider? _findImageProvider(Comic comic) {
  ImageProvider image;
  if (comic is LocalComic) {
    image = LocalComicImageProvider(comic);
  } else if (comic is History) {
    image = HistoryImageProvider(comic);
  } else if (comic.sourceKey == 'local') {
    var localComic = LocalManager().find(comic.id, ComicType.local);
    if (localComic == null) {
      return null;
    }
    image = FileImage(localComic.coverFile);
  } else {
    image = CachedImageProvider(
      comic.cover,
      sourceKey: comic.sourceKey,
      cid: comic.id,
      fallbackToLocalCover: comic is FavoriteItem,
    );
  }
  return image;
}

class ComicTile extends StatelessWidget {
  const ComicTile({
    super.key,
    required this.comic,
    this.enableLongPressed = true,
    this.badge,
    this.menuOptions,
    this.onTap,
    this.onLongPressed,
    this.heroID,
  });

  final Comic comic;

  final bool enableLongPressed;

  final String? badge;

  final List<MenuEntry>? menuOptions;

  final VoidCallback? onTap;

  final VoidCallback? onLongPressed;

  final int? heroID;

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
      MenuEntry(
        icon: Icons.hub_outlined,
        text: 'Related Sources'.tl,
        onClick: () => _showRelatedSourcesDialog(context),
      ),
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

  void _showRelatedSourcesDialog(BuildContext context) {
    final sourceKeyController = TextEditingController();
    final comicIdController = TextEditingController();
    final searchController = TextEditingController(text: comic.title);
    const repository = ComicStateRepository();
    final currentIdentity = repository.identityFor(comic.sourceKey, comic.id);
    final searchableSources = ComicSource.all()
        .where(
          (source) =>
              source.searchPageData?.loadPage != null ||
              source.searchPageData?.loadNext != null,
        )
        .toList();
    final selectedSourceKeys = <String>{};
    final firstOtherSource = searchableSources.firstWhereOrNull(
      (source) => source.key != comic.sourceKey,
    );
    if (firstOtherSource != null) {
      selectedSourceKeys.add(firstOtherSource.key);
    } else if (searchableSources.isNotEmpty) {
      selectedSourceKeys.add(searchableSources.first.key);
    }
    var searchGroups = <String, _RelatedSearchGroup>{};
    var isSearching = false;

    void openDetail(
      String sourceKey,
      String id, {
      String? cover,
      String? title,
    }) {
      App.mainNavigatorKey?.currentContext?.to(
        () =>
            ComicPage(id: id, sourceKey: sourceKey, cover: cover, title: title),
      );
    }

    void showLinkPreview(
      DomainComicSourceLink link, {
      VoidCallback? onAccept,
      VoidCallback? onReject,
      VoidCallback? onUnlink,
    }) {
      final sourceKey = _sourceKeyFromPlatformId(link.platformId);
      _showRelatedComicPreview(
        context: context,
        title: link.comicTitle,
        cover: link.comicCoverUri,
        sourceKey: sourceKey,
        sourceName: _sourceNameForKey(sourceKey, link.sourceName),
        id: link.sourceComicId,
        author: link.comicAuthor,
        status: link.comicStatus,
        actions: [
          if (onAccept != null)
            Button.filled(onPressed: onAccept, child: Text('Accept'.tl)),
          if (onReject != null)
            Button.text(onPressed: onReject, child: Text('Reject'.tl)),
          if (onUnlink != null)
            Button.text(onPressed: onUnlink, child: Text('Unlink'.tl)),
          Button.outlined(
            onPressed: () => openDetail(
              sourceKey,
              link.sourceComicId,
              cover: link.comicCoverUri,
              title: link.comicTitle,
            ),
            child: Text('Jump to Detail'.tl),
          ),
        ],
      );
    }

    void showResultPreview(Comic result, VoidCallback onLink) {
      _showRelatedComicPreview(
        context: context,
        title: result.title,
        cover: result.cover,
        sourceKey: result.sourceKey,
        sourceName: _sourceNameForKey(result.sourceKey, result.sourceKey),
        id: result.id,
        author: result.subtitle,
        status: _relatedStatusFromTags(result.tags),
        tags: result.tags,
        description: result.description,
        actions: [
          Button.filled(onPressed: onLink, child: Text('Link this comic'.tl)),
          Button.outlined(
            onPressed: () => openDetail(
              result.sourceKey,
              result.id,
              cover: result.cover,
              title: result.title,
            ),
            child: Text('Jump to Detail'.tl),
          ),
        ],
      );
    }

    void linkSearchResult(
      StateSetter setState,
      BuildContext context,
      Comic result,
    ) {
      try {
        repository.mirrorComic(result);
        repository.linkRelatedSource(
          comic: comic,
          targetSourceKey: result.sourceKey,
          targetComicId: result.id,
        );
        setState(() {
          searchGroups = {};
        });
        context.showMessage(message: 'Linked'.tl);
      } catch (e) {
        context.showMessage(message: e.toString().tl);
      }
    }

    Future<void> runSearch(StateSetter setState, BuildContext context) async {
      final keyword = searchController.text.trim();
      if (keyword.isEmpty || selectedSourceKeys.isEmpty) {
        context.showMessage(message: 'Invalid input'.tl);
        return;
      }
      setState(() {
        isSearching = true;
        searchGroups = {
          for (final sourceKey in selectedSourceKeys)
            sourceKey: _RelatedSearchGroup(
              sourceKey: sourceKey,
              sourceName: _sourceNameForKey(sourceKey, sourceKey),
              isLoading: true,
            ),
        };
      });
      for (final sourceKey in selectedSourceKeys.toList()) {
        final source = ComicSource.find(sourceKey);
        final searchData = source?.searchPageData;
        if (source == null || searchData == null) {
          setState(() {
            searchGroups[sourceKey] = _RelatedSearchGroup(
              sourceKey: sourceKey,
              sourceName: _sourceNameForKey(sourceKey, sourceKey),
              error: 'No searchable sources'.tl,
            );
          });
          continue;
        }
        final options =
            searchData.searchOptions
                ?.map((option) => option.defaultValue)
                .toList() ??
            const <String>[];
        try {
          final res = searchData.loadPage != null
              ? await searchData.loadPage!(keyword, 1, options)
              : await searchData.loadNext!(keyword, null, options);
          setState(() {
            searchGroups[sourceKey] = _RelatedSearchGroup(
              sourceKey: sourceKey,
              sourceName: source.name,
              results: res.dataOrNull ?? const <Comic>[],
              error: res.errorMessage,
            );
          });
        } catch (e) {
          setState(() {
            searchGroups[sourceKey] = _RelatedSearchGroup(
              sourceKey: sourceKey,
              sourceName: source.name,
              error: e.toString(),
            );
          });
        }
      }
      setState(() {
        isSearching = false;
      });
    }

    Widget buildSourceSelector(StateSetter setState) {
      if (searchableSources.isEmpty) {
        return Text(
          'No searchable sources'.tl,
          style: TextStyle(color: context.colorScheme.onSurfaceVariant),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Select Source'.tl, style: ts.s16),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() {
                    selectedSourceKeys
                      ..clear()
                      ..addAll(searchableSources.map((source) => source.key));
                  });
                },
                child: Text('Select All'.tl),
              ),
              TextButton(
                onPressed: () => setState(selectedSourceKeys.clear),
                child: Text('Deselect'.tl),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 116),
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final source in searchableSources)
                    FilterChip(
                      label: Text(source.name),
                      selected: selectedSourceKeys.contains(source.key),
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            selectedSourceKeys.add(source.key);
                          } else {
                            selectedSourceKeys.remove(source.key);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    Widget buildLinkList(StateSetter setState) {
      if (!repository.isDomainReady) {
        return Center(
          child: Text(
            'Related source database unavailable'.tl,
            style: TextStyle(color: context.colorScheme.onSurfaceVariant),
          ),
        );
      }
      final links = repository.relatedSourcesFor(comic);
      if (links.isEmpty) {
        return Center(
          child: Text(
            'No related sources'.tl,
            style: TextStyle(color: context.colorScheme.onSurfaceVariant),
          ),
        );
      }
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          for (final link in links)
            _RelatedSourceRow(
              link: link,
              isCurrent: link.comicId == currentIdentity.comicId,
              onTap: () => showLinkPreview(
                link,
                onAccept: link.status == 'candidate'
                    ? () {
                        repository.acceptRelatedSource(link);
                        setState(() {});
                        App.rootContext.pop();
                      }
                    : null,
                onReject: link.status == 'candidate'
                    ? () {
                        repository.rejectRelatedSource(link);
                        setState(() {});
                        App.rootContext.pop();
                      }
                    : null,
                onUnlink:
                    link.status == 'accepted' &&
                        link.comicId != currentIdentity.comicId
                    ? () {
                        repository.unlinkRelatedSource(link);
                        setState(() {});
                        App.rootContext.pop();
                      }
                    : null,
              ),
              onAccept: link.status == 'candidate'
                  ? () {
                      repository.acceptRelatedSource(link);
                      setState(() {});
                    }
                  : null,
              onReject: link.status == 'candidate'
                  ? () {
                      repository.rejectRelatedSource(link);
                      setState(() {});
                    }
                  : null,
              onUnlink:
                  link.status == 'accepted' &&
                      link.comicId != currentIdentity.comicId
                  ? () {
                      repository.unlinkRelatedSource(link);
                      setState(() {});
                    }
                  : null,
            ),
        ],
      );
    }

    Widget buildSearchList(StateSetter setState, BuildContext context) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          buildSourceSelector(setState),
          const SizedBox(height: 12),
          TextField(
            controller: searchController,
            decoration: InputDecoration(
              labelText: 'Search by title'.tl,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: isSearching
                    ? null
                    : () => runSearch(setState, context),
              ),
            ),
            onSubmitted: (_) => runSearch(setState, context),
          ),
          const SizedBox(height: 10),
          Button.filled(
            isLoading: isSearching,
            onPressed: () => runSearch(setState, context),
            child: Text('Search related comic'.tl),
          ),
          const SizedBox(height: 12),
          if (searchGroups.isEmpty)
            Text(
              'Search Results'.tl,
              style: TextStyle(color: context.colorScheme.onSurfaceVariant),
            )
          else
            for (final group in searchGroups.values)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                initiallyExpanded: true,
                title: Text(group.sourceName),
                subtitle: group.isLoading
                    ? Text('Running'.tl)
                    : Text(
                        group.error ??
                            'Found @count comics'.tlParams({
                              'count': group.results.length,
                            }),
                      ),
                children: [
                  if (group.isLoading)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: LinearProgressIndicator(),
                    )
                  else if (group.error != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        group.error!,
                        style: TextStyle(color: context.colorScheme.error),
                      ),
                    )
                  else if (group.results.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No related sources'.tl,
                        style: TextStyle(
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    for (final result in group.results.take(12))
                      _RelatedSearchResultRow(
                        comic: result,
                        onTap: () => showResultPreview(
                          result,
                          () => linkSearchResult(setState, context, result),
                        ),
                        onLink: () =>
                            linkSearchResult(setState, context, result),
                      ),
                ],
              ),
          const SizedBox(height: 12),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text('Advanced precise link'.tl),
            children: [
              TextField(
                controller: sourceKeyController,
                decoration: InputDecoration(
                  labelText: 'Source identifier'.tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: comicIdController,
                decoration: InputDecoration(
                  labelText: 'Comic identifier or URL'.tl,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: Button.outlined(
                  onPressed: () {
                    final sourceKey = sourceKeyController.text.trim();
                    final targetComicId = comicIdController.text.trim();
                    if (sourceKey.isEmpty || targetComicId.isEmpty) {
                      context.showMessage(message: 'Invalid input'.tl);
                      return;
                    }
                    try {
                      repository.linkRelatedSource(
                        comic: comic,
                        targetSourceKey: sourceKey,
                        targetComicId: targetComicId,
                      );
                      sourceKeyController.clear();
                      comicIdController.clear();
                      setState(() {});
                      context.showMessage(message: 'Linked'.tl);
                    } catch (e) {
                      context.showMessage(message: e.toString().tl);
                    }
                  },
                  child: Text('Link'.tl),
                ),
              ),
            ],
          ),
        ],
      );
    }

    showDialog(
      context: App.rootContext,
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
                width: math.min(600, math.max(280, context.width - 64)),
                height: math.min(640, math.max(360, context.height - 96)),
                child: Column(
                  children: [
                    Appbar(
                      leading: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: context.pop,
                      ),
                      title: Text('Related Sources'.tl),
                      backgroundColor: Colors.transparent,
                    ),
                    Expanded(
                      child: DefaultTabController(
                        length: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${'Current'.tl}: ${comic.title.replaceAll('\n', ' ')}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: context.colorScheme.onSurfaceVariant,
                              ),
                            ).paddingHorizontal(16),
                            const SizedBox(height: 8),
                            Material(
                              color: Colors.transparent,
                              child: AppTabBar(
                                tabs: [
                                  Tab(text: 'Linked / Candidates'.tl),
                                  Tab(text: 'Search'.tl),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: TabBarView(
                                children: [
                                  buildLinkList(setState).paddingHorizontal(16),
                                  buildSearchList(
                                    setState,
                                    context,
                                  ).paddingHorizontal(16),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Button.text(
                          onPressed: () => context.pop(),
                          child: Text('Cancel'.tl),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ).whenComplete(() {
      sourceKeyController.dispose();
      comicIdController.dispose();
      searchController.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicDisplayMode'];

    final comicType = ComicType.fromKey(comic.sourceKey);
    var isFavorite = appdata.settings['showFavoriteStatusOnTile']
        ? LocalFavoritesManager().isExist(comic.id, comicType)
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

    if (!isFavorite && tileHistory == null) {
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
    var image = _findImageProvider(comic);
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
          badge: badge,
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
                ),
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
                        pagesText: displayInfo.pagesText,
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

                        if (text == null) {
                          return const SizedBox();
                        }

                        var children = <Widget>[];
                        var lines = text.split('\n');
                        lines.removeWhere((e) => e.trim().isEmpty);
                        if (lines.length > 3) {
                          lines = lines.sublist(0, 3);
                        }
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

  List<String> _splitText(String text) {
    // split text by comma, brackets
    var words = <String>[];
    var buffer = StringBuffer();
    var inBracket = false;
    String? prevBracket;
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c == '[' || c == '(') {
        if (inBracket) {
          buffer.write(c);
        } else {
          if (buffer.isNotEmpty) {
            words.add(buffer.toString().trim());
            buffer.clear();
          }
          inBracket = true;
          prevBracket = c;
        }
      } else if (c == ']' || c == ')') {
        if (prevBracket == '[' && c == ']' || prevBracket == '(' && c == ')') {
          if (buffer.isNotEmpty) {
            words.add(buffer.toString().trim());
            buffer.clear();
          }
          inBracket = false;
        } else {
          buffer.write(c);
        }
      } else if (c == ',') {
        if (inBracket) {
          buffer.write(c);
        } else {
          words.add(buffer.toString().trim());
          buffer.clear();
        }
      } else {
        buffer.write(c);
      }
    }
    if (buffer.isNotEmpty) {
      words.add(buffer.toString().trim());
    }
    words.removeWhere((element) => element == "");
    words = words.toSet().toList();
    return words;
  }

  void block(BuildContext comicTileContext) {
    showDialog(
      context: App.rootContext,
      builder: (context) {
        var words = <String>[];
        var all = <String>[];
        all.addAll(_splitText(comic.title));
        if (comic.subtitle != null && comic.subtitle != "") {
          all.add(comic.subtitle!);
        }
        all.addAll(comic.tags ?? []);
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: 'Block'.tl,
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(400, context.height - 136),
                ),
                child: SingleChildScrollView(
                  child: Wrap(
                    runSpacing: 8,
                    spacing: 8,
                    children: [
                      for (var word in all)
                        OptionChip(
                          text: (comic.tags?.contains(word) ?? false)
                              ? word.translateTagIfNeed
                              : word,
                          isSelected: words.contains(word),
                          onTap: () {
                            setState(() {
                              if (!words.contains(word)) {
                                words.add(word);
                              } else {
                                words.remove(word);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ).paddingHorizontal(16),
              ),
              actions: [
                Button.filled(
                  onPressed: () {
                    context.pop();
                    for (var word in words) {
                      appdata.settings['blockedWords'].add(word);
                    }
                    appdata.saveData();
                    context.showMessage(message: 'Blocked'.tl);
                    comicTileContext
                        .findAncestorStateOfType<_SliverGridComicsState>()!
                        .update();
                  },
                  child: Text('Block'.tl),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _RelatedSearchGroup {
  const _RelatedSearchGroup({
    required this.sourceKey,
    required this.sourceName,
    this.results = const <Comic>[],
    this.error,
    this.isLoading = false,
  });

  final String sourceKey;
  final String sourceName;
  final List<Comic> results;
  final String? error;
  final bool isLoading;
}

String _sourceKeyFromPlatformId(String platformId) {
  const remotePrefix = 'remote:';
  if (platformId.startsWith(remotePrefix)) {
    return platformId.substring(remotePrefix.length);
  }
  return platformId;
}

String _sourceNameForKey(String sourceKey, String fallback) {
  if (sourceKey == 'local') {
    return 'Local'.tl;
  }
  return ComicSource.find(sourceKey)?.name ?? fallback;
}

String? _relatedStatusFromTags(List<String>? tags) {
  if (tags == null) {
    return null;
  }
  const names = {'status', '状态', '狀態', '連載狀態', '连载状态'};
  for (final tag in tags) {
    final parts = tag.split(RegExp(r'[:：]'));
    if (parts.length < 2) {
      continue;
    }
    if (names.contains(parts.first.trim().toLowerCase())) {
      final value = parts.sublist(1).join(':').trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
  }
  return null;
}

void _showRelatedComicPreview({
  required BuildContext context,
  required String title,
  required String? cover,
  required String sourceKey,
  required String sourceName,
  required String id,
  String? author,
  String? status,
  String? description,
  List<String>? tags,
  List<Widget> actions = const [],
}) {
  showDialog(
    context: context,
    builder: (context) {
      final cleanAuthor = author?.replaceAll('\n', ' ').trim();
      final cleanStatus = status?.replaceAll('\n', ' ').trim();
      final cleanDescription = description?.replaceAll('\n', ' ').trim();
      return ContentDialog(
        title: 'Details'.tl,
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: math.min(460, context.height - 152),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 86,
                    height: 116,
                    child: cover == null || cover.isEmpty
                        ? ColoredBox(
                            color: context.colorScheme.surfaceContainerHigh,
                          )
                        : AnimatedImage(
                            image: CachedImageProvider(
                              cover,
                              sourceKey: sourceKey,
                              cid: id,
                            ),
                            fit: BoxFit.cover,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.replaceAll('\n', ' '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s18.bold,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        [
                          sourceName,
                          if (cleanAuthor != null && cleanAuthor.isNotEmpty)
                            cleanAuthor,
                          if (cleanStatus != null && cleanStatus.isNotEmpty)
                            cleanStatus,
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 13,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (tags != null && tags.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final tag in tags.take(8))
                              Chip(
                                label: Text(tag),
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ],
                      if (cleanDescription != null &&
                          cleanDescription.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          cleanDescription,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          ...actions,
          Button.text(onPressed: () => context.pop(), child: Text('Close'.tl)),
        ],
      );
    },
  );
}

class _RelatedSourceRow extends StatelessWidget {
  const _RelatedSourceRow({
    required this.link,
    required this.isCurrent,
    this.onTap,
    this.onAccept,
    this.onReject,
    this.onUnlink,
  });

  final DomainComicSourceLink link;
  final bool isCurrent;
  final VoidCallback? onTap;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onUnlink;

  @override
  Widget build(BuildContext context) {
    final statusText = link.status == 'candidate'
        ? 'Candidate'.tl
        : 'Linked'.tl;
    final sourceText = link.linkSource == 'auto' ? 'Auto'.tl : 'Manual'.tl;
    final confidence = link.confidence == null
        ? ''
        : ' ${(link.confidence! * 100).round()}%';
    final author = link.comicAuthor?.replaceAll('\n', ' ').trim();
    final comicStatus = link.comicStatus?.replaceAll('\n', ' ').trim();
    final sourceKey = _sourceKeyFromPlatformId(link.platformId);
    final sourceName = _sourceNameForKey(sourceKey, link.sourceName);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 38,
                height: 52,
                child: link.comicCoverUri == null || link.comicCoverUri!.isEmpty
                    ? ColoredBox(
                        color: context.colorScheme.surfaceContainerHigh,
                      )
                    : AnimatedImage(
                        image: CachedImageProvider(
                          link.comicCoverUri!,
                          sourceKey: sourceKey,
                          cid: link.sourceComicId,
                        ),
                        fit: BoxFit.cover,
                      ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    link.comicTitle.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      sourceName,
                      if (author != null && author.isNotEmpty) author,
                      if (comicStatus != null && comicStatus.isNotEmpty)
                        comicStatus,
                      statusText,
                      sourceText,
                      if (confidence.isNotEmpty) confidence.trim(),
                      if (isCurrent) 'Current'.tl,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onAccept != null)
              Button.icon(
                icon: const Icon(Icons.check, size: 18),
                tooltip: 'Accept'.tl,
                onPressed: onAccept!,
              ),
            if (onReject != null)
              Button.icon(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Reject'.tl,
                onPressed: onReject!,
              ),
            if (onUnlink != null)
              Button.icon(
                icon: const Icon(Icons.link_off, size: 18),
                tooltip: 'Unlink'.tl,
                onPressed: onUnlink!,
              ),
          ],
        ),
      ),
    );
  }
}

class _RelatedSearchResultRow extends StatelessWidget {
  const _RelatedSearchResultRow({
    required this.comic,
    required this.onLink,
    this.onTap,
  });

  final Comic comic;
  final VoidCallback onLink;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final sourceName = _sourceNameForKey(comic.sourceKey, comic.sourceKey);
    final subtitle = comic.subtitle?.replaceAll('\n', ' ').trim();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: 38,
                height: 52,
                child: AnimatedImage(
                  image: CachedImageProvider(
                    comic.cover,
                    sourceKey: comic.sourceKey,
                    cid: comic.id,
                  ),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    comic.title.replaceAll('\n', ' '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      sourceName,
                      if (subtitle != null && subtitle.isNotEmpty) subtitle,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Button.icon(
              icon: const Icon(Icons.link, size: 18),
              tooltip: 'Link this comic'.tl,
              onPressed: onLink,
            ),
          ],
        ),
      ),
    );
  }
}

class ComicDescription extends StatelessWidget {
  const ComicDescription({
    super.key,
    required this.title,
    required this.subtitle,
    required this.description,
    required this.enableTranslate,
    this.badge,
    this.maxLines = 2,
    this.tags,
    this.rating,
    this.updateText,
    this.statusText,
    this.progressText,
    this.pagesText,
    this.showTitle = true,
    this.onTapAuthor,
    this.onTapTag,
  });

  final String title;
  final String subtitle;
  final String description;
  final String? badge;
  final List<String>? tags;
  final int maxLines;
  final bool enableTranslate;
  final double? rating;
  final String? updateText;
  final String? statusText;
  final String? progressText;
  final String? pagesText;
  final bool showTitle;
  final void Function(String author, String? namespace)? onTapAuthor;
  final void Function(String tag, String namespace)? onTapTag;

  @override
  Widget build(BuildContext context) {
    final descriptionParts = _descriptionParts();
    final source = _clean(badge) ?? _derivedSource(descriptionParts);
    final update = _clean(updateText) ?? _updateTextFromTags();
    final progress = _clean(progressText);
    final pages = _clean(pagesText) ?? _pagesTextFromTags();
    final authorItems = _authorItems();
    final authors = authorItems.isEmpty
        ? null
        : authorItems.map((e) => e.label).join(", ");
    final tagItems = _tagItems();
    final tagText = _tagText(tagItems);
    final status = _clean(statusText) ?? _statusText();
    final fallbackDescription = _fallbackDescription(
      update,
      progress,
      source,
      descriptionParts,
    );
    final rows = <Widget>[
      if (authors != null && onTapAuthor != null)
        _actionRow(
          context,
          "Authors".tl,
          authorItems
              .map(
                (item) => _InfoAction(
                  text: item.label,
                  onTap: () => onTapAuthor!(item.value, item.namespace),
                ),
              )
              .toList(),
          Colors.lightBlue,
        )
      else if (authors != null)
        _infoRow(context, "Authors".tl, authors, Colors.lightBlue),
      if (update != null) _infoRow(context, "Update".tl, update, Colors.cyan),
      if (source != null) _infoRow(context, "Source".tl, source, Colors.cyan),
      if (tagItems.isNotEmpty && onTapTag != null)
        _actionRow(
          context,
          "Tags".tl,
          tagItems
              .map(
                (item) => _InfoAction(
                  text: item.label,
                  onTap: () => onTapTag!(item.value, item.namespace ?? ''),
                ),
              )
              .toList(),
          Colors.pinkAccent,
        )
      else if (tagText != null)
        _infoRow(context, "Tags".tl, tagText, Colors.pinkAccent),
      if (status != null) _infoRow(context, "Status".tl, status, Colors.purple),
      if (progress != null)
        _infoRow(context, "Progress".tl, progress, Colors.green),
      if (pages != null)
        _infoRow(context, "Pages".tl, pages, Colors.deepOrange),
      if (fallbackDescription != null)
        _infoRow(context, "Description".tl, fallbackDescription, Colors.orange),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleRows = _visibleRowCount(
          constraints.maxHeight,
          rating != null,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            if (showTitle) ...[
              Text(
                title.trim(),
                style: const TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
                maxLines: rows.isEmpty ? maxLines : 1,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
              ),
              const SizedBox(height: 4),
            ],
            if (rating != null) ...[
              StarRating(value: rating!, size: 15),
              const SizedBox(height: 2),
            ],
            if (rows.isNotEmpty)
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: rows.take(visibleRows).toList(),
                ),
              ),
          ],
        );
      },
    );
  }

  int _visibleRowCount(double maxHeight, bool hasRating) {
    if (maxHeight.isInfinite) {
      return hasRating ? 4 : 5;
    }
    final reservedHeight = (showTitle ? 24 : 0) + (hasRating ? 20 : 0);
    final count = ((maxHeight - reservedHeight) / 21).floor();
    return math.max(1, math.min(5, count));
  }

  Widget _infoRow(
    BuildContext context,
    String label,
    String value,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: color.toOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow(
    BuildContext context,
    String label,
    List<_InfoAction> actions,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            height: 18,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: color.toOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.colorScheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < actions.length; i++) ...[
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: actions[i].onTap,
                      child: Text(
                        actions[i].text,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.colorScheme.primary,
                        ),
                      ).paddingHorizontal(2),
                    ),
                    if (i != actions.length - 1)
                      Text(
                        " / ",
                        style: TextStyle(
                          fontSize: 12,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String? _clean(String? value) {
    final result = value?.replaceAll("\n", " ").trim();
    return result == null ||
            result.isEmpty ||
            result == "Unknown" ||
            result.startsWith("Unknown:")
        ? null
        : result;
  }

  String? _tagText(List<_DescriptionTag> rawTags) {
    if (rawTags.isEmpty) {
      return null;
    }
    return rawTags.map((tag) => tag.label).join(" / ");
  }

  List<_DescriptionTag> _tagItems() {
    final rawTags = tags
        ?.map((e) => e.replaceAll("\n", " ").trim())
        .where(
          (e) =>
              e.removeAllBlank != "" &&
              !_isMetadataTag(e) &&
              _clean(e.split(':').last) != null,
        )
        .toList();
    if (rawTags == null || rawTags.isEmpty) {
      return const [];
    }
    final enableTranslate =
        App.locale.languageCode == 'zh' && this.enableTranslate;
    return rawTags.map((tag) {
      final index = tag.indexOf(':');
      final namespace = index == -1 ? null : tag.substring(0, index);
      final value = index == -1 ? tag : tag.substring(index + 1);
      return _DescriptionTag(
        namespace: namespace,
        value: value,
        label: enableTranslate
            ? TagsTranslation.translateTag(tag)
            : tag.split(':').last,
      );
    }).toList();
  }

  List<_DescriptionTag> _authorItems() {
    final author = _clean(subtitle);
    if (author != null) {
      return author
          .split(RegExp(r"[|,]"))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .map(
            (e) => _DescriptionTag(
              namespace: _namespaceForValue(e, _authorNamespaces),
              value: e,
              label: e,
            ),
          )
          .toList();
    }
    return _tagItemsWithNamespace(_authorNamespaces);
  }

  String? _statusText() {
    return _tagsWithNamespace(_statusNamespaces).firstOrNull;
  }

  String? _updateTextFromTags() {
    return _tagsWithNamespace(
      _updateNamespaces,
    ).where(_looksLikeDate).firstOrNull;
  }

  String? _pagesTextFromTags() {
    return _tagsWithNamespace(
      _pagesNamespaces,
    ).where((e) => int.tryParse(e) != null).firstOrNull;
  }

  List<String> _tagsWithNamespace(Set<String> namespaces) {
    return _tagItemsWithNamespace(namespaces).map((e) => e.label).toList();
  }

  List<_DescriptionTag> _tagItemsWithNamespace(Set<String> namespaces) {
    return tags
            ?.map((e) => e.replaceAll("\n", " ").trim())
            .where((e) => e.contains(':'))
            .map((e) {
              final index = e.indexOf(':');
              final namespace = _normalizeNamespace(e.substring(0, index));
              final value = _clean(e.substring(index + 1));
              if (value == null || !namespaces.contains(namespace)) {
                return null;
              }
              return _DescriptionTag(
                namespace: e.substring(0, index),
                value: value,
                label: enableTranslate && App.locale.languageCode == 'zh'
                    ? TagsTranslation.translateTag(e)
                    : value,
              );
            })
            .whereType<_DescriptionTag>()
            .toList() ??
        const [];
  }

  String? _namespaceForValue(String value, Set<String> namespaces) {
    for (final tag in tags ?? const <String>[]) {
      final index = tag.indexOf(':');
      if (index == -1) {
        continue;
      }
      final namespace = tag.substring(0, index);
      final tagValue = _clean(tag.substring(index + 1));
      if (tagValue == value &&
          namespaces.contains(_normalizeNamespace(namespace))) {
        return namespace;
      }
    }
    return null;
  }

  bool _isMetadataTag(String tag) {
    if (!tag.contains(':')) {
      final value = _clean(tag);
      return value == null || _looksLikeDate(value) || _looksLikeStatus(value);
    }
    final index = tag.indexOf(':');
    final namespace = _normalizeNamespace(tag.substring(0, index));
    final value = _clean(tag.substring(index + 1));
    return _metadataNamespaces.contains(namespace) ||
        value == null ||
        _looksLikeDate(value) ||
        _looksLikeStatus(value);
  }

  String _normalizeNamespace(String value) {
    return value.trim().toLowerCase().replaceAll(' ', '');
  }

  static const _authorNamespaces = {
    'author',
    'artist',
    'authors',
    'artists',
    'creator',
    '原作',
    '作者',
    '作家',
    '作画',
    '作畫',
    '漫畫',
    '漫画',
    '著者',
    '绘师',
    '繪師',
  };

  static const _statusNamespaces = {
    'status',
    'state',
    'serialization',
    '連載',
    '连载',
    '狀態',
    '状态',
  };

  static const _updateNamespaces = {
    'date',
    'lastupdate',
    'time',
    'update',
    'updated',
    '更新',
    '最後更新',
    '最后更新',
    '時間',
    '时间',
    '日期',
  };

  static const _pagesNamespaces = {'page', 'pages', '頁數', '页数'};

  static const _metadataNamespaces = {
    ..._authorNamespaces,
    ..._statusNamespaces,
    ..._updateNamespaces,
    ..._pagesNamespaces,
    'language',
    'source',
    'uploader',
    '語言',
    '语言',
    '來源',
    '来源',
    '上傳者',
    '上传者',
  };

  String? _derivedSource(List<String> parts) {
    if (parts.length != 2 || !_looksLikeDate(parts.first)) {
      return null;
    }
    return _clean(parts.last);
  }

  String? _fallbackDescription(
    String? update,
    String? progress,
    String? source,
    List<String> parts,
  ) {
    final value = _clean(description);
    if (value == null || value == update || value == progress) {
      return null;
    }
    if (_isMetadataDescription(parts, source)) {
      return null;
    }
    return value.replaceAll("|", " / ");
  }

  List<String> _descriptionParts() {
    return description
        .split("|")
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  bool _looksLikeDate(String value) {
    return RegExp(r"^\d{4}[-/]\d{1,2}[-/]\d{1,2}").hasMatch(value) ||
        RegExp(r"^\d{4}").hasMatch(value);
  }

  bool _looksLikeStatus(String value) {
    final normalized = value.trim().toLowerCase();
    return const {
      'completed',
      'complete',
      'ongoing',
      'serializing',
      '連載',
      '連載中',
      '连载',
      '连载中',
      '完結',
      '完结',
      '已完結',
      '已完结',
      '休載',
      '休载',
    }.contains(normalized);
  }

  bool _isMetadataDescription(List<String> parts, String? source) {
    if (parts.length != 2 || !_looksLikeDate(parts.first)) {
      return false;
    }
    final descriptionSource = _clean(parts.last);
    return source == null ||
        descriptionSource == null ||
        descriptionSource == source;
  }
}

class _DescriptionTag {
  const _DescriptionTag({
    required this.value,
    required this.label,
    this.namespace,
  });

  final String? namespace;
  final String value;
  final String label;
}

class _InfoAction {
  const _InfoAction({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;
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

class SliverGridComics extends StatefulWidget {
  const SliverGridComics({
    super.key,
    required this.comics,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onTapWithIndex,
    this.onLongPressed,
    this.onLongPressedWithIndex,
    this.selections,
  });

  final List<Comic> comics;

  final Map<Comic, bool>? selections;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID, int index)? onTapWithIndex;

  final void Function(Comic, int heroID)? onLongPressed;

  final void Function(Comic, int heroID, int index)? onLongPressedWithIndex;

  @override
  State<SliverGridComics> createState() => _SliverGridComicsState();
}

class _SliverGridComicsState extends State<SliverGridComics> {
  List<Comic> comics = [];
  List<int> heroIDs = [];

  static int _nextHeroID = 0;

  void generateHeroID() {
    heroIDs.clear();
    for (var i = 0; i < comics.length; i++) {
      heroIDs.add(_nextHeroID++);
    }
  }

  @override
  void didUpdateWidget(covariant SliverGridComics oldWidget) {
    if (!comics.isEqualTo(widget.comics)) {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
      generateHeroID();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    for (var comic in widget.comics) {
      if (isBlocked(comic) == null) {
        comics.add(comic);
      }
    }
    generateHeroID();
    HistoryManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(update);
    super.dispose();
  }

  void update() {
    setState(() {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _SliverGridComics(
      comics: comics,
      heroIDs: heroIDs,
      selection: widget.selections,
      onLastItemBuild: widget.onLastItemBuild,
      badgeBuilder: widget.badgeBuilder,
      menuBuilder: widget.menuBuilder,
      onTap: widget.onTap,
      onTapWithIndex: widget.onTapWithIndex,
      onLongPressed: widget.onLongPressed,
      onLongPressedWithIndex: widget.onLongPressedWithIndex,
    );
  }
}

class _SliverGridComics extends StatelessWidget {
  const _SliverGridComics({
    required this.comics,
    required this.heroIDs,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.onTap,
    this.onTapWithIndex,
    this.onLongPressed,
    this.onLongPressedWithIndex,
    this.selection,
  });

  final List<Comic> comics;

  final List<int> heroIDs;

  final Map<Comic, bool>? selection;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID, int index)? onTapWithIndex;

  final void Function(Comic, int heroID)? onLongPressed;

  final void Function(Comic, int heroID, int index)? onLongPressedWithIndex;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index == comics.length - 1) {
          onLastItemBuild?.call();
        }
        var badge = badgeBuilder?.call(comics[index]);
        var isSelected = selection == null
            ? false
            : selection![comics[index]] ?? false;
        var comic = ComicTile(
          comic: comics[index],
          badge: badge,
          menuOptions: menuBuilder?.call(comics[index]),
          onTap: onTapWithIndex != null
              ? () => onTapWithIndex!(comics[index], heroIDs[index], index)
              : onTap != null
              ? () => onTap!(comics[index], heroIDs[index])
              : null,
          onLongPressed: onLongPressedWithIndex != null
              ? () => onLongPressedWithIndex!(
                  comics[index],
                  heroIDs[index],
                  index,
                )
              : onLongPressed != null
              ? () => onLongPressed!(comics[index], heroIDs[index])
              : null,
          heroID: heroIDs[index],
        );
        if (selection == null) {
          return comic;
        }
        return AnimatedContainer(
          key: ValueKey(comics[index].id),
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: isSelected
                ? Theme.of(
                    context,
                  ).colorScheme.secondaryContainer.toOpacity(0.72)
                : null,
            borderRadius: BorderRadius.circular(12),
          ),
          margin: const EdgeInsets.all(4),
          child: comic,
        );
      }, childCount: comics.length),
      gridDelegate: SliverGridDelegateWithComics(),
    );
  }
}

/// return the first blocked keyword, or null if not blocked
String? isBlocked(Comic item) {
  for (var word in appdata.settings['blockedWords']) {
    if (item.title.contains(word)) {
      return word;
    }
    if (item.subtitle?.contains(word) ?? false) {
      return word;
    }
    if (item.description.contains(word)) {
      return word;
    }
    for (var tag in item.tags ?? <String>[]) {
      if (tag == word) {
        return word;
      }
      if (tag.contains(':')) {
        tag = tag.split(':')[1];
        if (tag == word) {
          return word;
        }
      }
    }
  }
  return null;
}

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
    this.enablePageStorage = false,
  });

  final Future<Res<List<Comic>>> Function(int page)? loadPage;

  final Future<Res<List<Comic>>> Function(String? next)? loadNext;

  final Widget? leadingSliver;

  final Widget? trailingSliver;

  final Widget? errorLeading;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final ScrollController? controller;

  final void Function(VoidCallback c)? refreshHandlerCallback;

  final bool enablePageStorage;

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

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicListDisplayMode'];
    return type == 'paging' ? buildPagingMode() : buildContinuousMode();
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
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        if (_maxPage != 1) _buildSliverPageSelector(),
        SliverGridComics(
          comics: _data[_page] ?? const [],
          menuBuilder: widget.menuBuilder,
        ),
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
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        SliverGridComics(
          comics: _data.values.expand((element) => element).toList(),
          menuBuilder: widget.menuBuilder,
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

class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.value,
    this.onTap,
    this.size = 20,
  });

  final double value; // 0-5

  final VoidCallback? onTap;

  final double size;

  @override
  Widget build(BuildContext context) {
    var interval = size * 0.1;
    var value = this.value;
    if (value.isNaN) {
      value = 0;
    }
    var child = SizedBox(
      height: size,
      width: size * 5 + interval * 4,
      child: Row(
        children: [
          for (var i = 0; i < 5; i++)
            _Star(
              value: (value - i).clamp(0.0, 1.0),
              size: size,
            ).paddingRight(i == 4 ? 0 : interval),
        ],
      ),
    );
    return onTap == null ? child : GestureDetector(onTap: onTap, child: child);
  }
}

class _Star extends StatelessWidget {
  const _Star({required this.value, required this.size});

  final double value; // 0-1

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Icon(
            Icons.star_outline,
            size: size,
            color: context.colorScheme.secondary,
          ),
          ClipRect(
            clipper: _StarClipper(value),
            child: Icon(
              Icons.star,
              size: size,
              color: context.colorScheme.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _StarClipper extends CustomClipper<Rect> {
  final double value;

  _StarClipper(this.value);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * value, size.height);
  }

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) {
    return oldClipper is! _StarClipper || oldClipper.value != value;
  }
}

class RatingWidget extends StatefulWidget {
  /// star number
  final int count;

  /// Max score
  final double maxRating;

  /// Current score value
  final double value;

  /// Star size
  final double size;

  /// Space between the stars
  final double padding;

  /// Whether the score can be modified by sliding
  final bool selectable;

  /// Callbacks when ratings change
  final ValueChanged<double> onRatingUpdate;

  const RatingWidget({
    super.key,
    this.maxRating = 10.0,
    this.count = 5,
    this.value = 10.0,
    this.size = 20,
    required this.padding,
    this.selectable = false,
    required this.onRatingUpdate,
  });

  @override
  State<RatingWidget> createState() => _RatingWidgetState();
}

class _RatingWidgetState extends State<RatingWidget> {
  double value = 10;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (PointerDownEvent event) {
        double x = event.localPosition.dx;
        if (x < 0) x = 0;
        pointValue(x);
      },
      onPointerMove: (PointerMoveEvent event) {
        double x = event.localPosition.dx;
        if (x < 0) x = 0;
        pointValue(x);
      },
      onPointerUp: (_) {},
      behavior: HitTestBehavior.deferToChild,
      child: buildRowRating(),
    );
  }

  pointValue(double dx) {
    if (!widget.selectable) {
      return;
    }
    if (dx >=
        widget.size * widget.count + widget.padding * (widget.count - 1)) {
      value = widget.maxRating;
    } else {
      for (double i = 1; i < widget.count + 1; i++) {
        if (dx > widget.size * i + widget.padding * (i - 1) &&
            dx < widget.size * i + widget.padding * i) {
          value = i * (widget.maxRating / widget.count);
          break;
        } else if (dx > widget.size * (i - 1) + widget.padding * (i - 1) &&
            dx < widget.size * i + widget.padding * i) {
          value =
              (dx - widget.padding * (i - 1)) /
              (widget.size * widget.count) *
              widget.maxRating;
          break;
        }
      }
    }
    if (value % 1 >= 0.5) {
      value = value ~/ 1 + 1;
    } else {
      value = (value ~/ 1).toDouble();
    }
    if (value < 0) {
      value = 0;
    } else if (value > 10) {
      value = 10;
    }
    setState(() {
      widget.onRatingUpdate(value);
    });
  }

  int fullStars() {
    return (value / (widget.maxRating / widget.count)).floor();
  }

  double star() {
    if (widget.count / fullStars() == widget.maxRating / value) {
      return 0;
    }
    return (value % (widget.maxRating / widget.count)) /
        (widget.maxRating / widget.count);
  }

  List<Widget> buildRow() {
    int full = fullStars();
    List<Widget> children = [];
    for (int i = 0; i < full; i++) {
      children.add(
        Icon(
          Icons.star,
          size: widget.size,
          color: context.colorScheme.secondary,
        ),
      );
      if (i < widget.count - 1) {
        children.add(SizedBox(width: widget.padding));
      }
    }
    if (full < widget.count) {
      children.add(
        ClipRect(
          clipper: _SMClipper(rating: star() * widget.size),
          child: Icon(
            Icons.star,
            size: widget.size,
            color: context.colorScheme.secondary,
          ),
        ),
      );
    }

    return children;
  }

  List<Widget> buildNormalRow() {
    List<Widget> children = [];
    for (int i = 0; i < widget.count; i++) {
      children.add(
        Icon(
          Icons.star_border,
          size: widget.size,
          color: context.colorScheme.secondary,
        ),
      );
      if (i < widget.count - 1) {
        children.add(SizedBox(width: widget.padding));
      }
    }
    return children;
  }

  Widget buildRowRating() {
    return Stack(
      children: <Widget>[
        Row(children: buildNormalRow()),
        Row(children: buildRow()),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    value = widget.value;
  }
}

class _SMClipper extends CustomClipper<Rect> {
  final double rating;

  _SMClipper({required this.rating});

  @override
  Rect getClip(Size size) {
    return Rect.fromLTRB(0.0, 0.0, rating, size.height);
  }

  @override
  bool shouldReclip(_SMClipper oldClipper) {
    return rating != oldClipper.rating;
  }
}

class SimpleComicTile extends StatelessWidget {
  const SimpleComicTile({
    super.key,
    required this.comic,
    this.onTap,
    this.withTitle = false,
    this.heroID,
  });

  final Comic comic;

  final void Function()? onTap;

  final bool withTitle;

  final int? heroID;

  @override
  Widget build(BuildContext context) {
    var image = _findImageProvider(comic);

    Widget child = image == null
        ? const SizedBox()
        : AnimatedImage(
            image: image,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
          );

    child = Container(
      width: 98,
      height: 136,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.secondaryContainer,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    if (heroID != null) {
      child = Hero(tag: "cover$heroID", child: child);
    }

    child = AnimatedTapRegion(
      borderRadius: 8,
      onTap:
          onTap ??
          () {
            context.to(
              () => ComicPage(
                id: comic.id,
                sourceKey: comic.sourceKey,
                cover: comic.cover,
                title: comic.title,
                heroID: heroID,
              ),
            );
          },
      child: child,
    );

    if (withTitle) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 4),
          SizedBox(
            width: 92,
            child: Center(
              child: Text(
                comic.title.replaceAll('\n', ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      );
    }

    return child;
  }
}

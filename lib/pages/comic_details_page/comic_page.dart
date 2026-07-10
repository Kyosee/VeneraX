import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:shimmer_animation/shimmer_animation.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/related_sources_dialog.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/favorites_meta.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'dart:math' as math;

part 'comments_page.dart';

part 'chapters.dart';

part 'thumbnails.dart';

part 'favorite.dart';

part 'comments_preview.dart';

part 'actions.dart';

part 'cover_viewer.dart';

/// Chooses the cover image provider for the comic detail header / viewer.
///
/// A pure local import ([ComicType.local]) stores a relative cover path such as
/// "cover.jpg" and has no network source able to turn it into a URL, so routing
/// it through the cached/network loader fails with "relative URL without a
/// base" (issue #38). Such covers load straight from the comic's own files —
/// the same way the local library grid does. Downloaded comics keep a
/// resolvable network source, so they continue using the cached/network path.
ImageProvider comicDetailCoverProvider({
  required String sourceKey,
  required String id,
  required String cover,
  required LocalComic? localComic,
}) {
  if (localComic != null && localComic.comicType == ComicType.local) {
    return LocalComicImageProvider(localComic);
  }
  return CachedImageProvider(cover, sourceKey: sourceKey, cid: id);
}

class ComicPage extends StatefulWidget {
  const ComicPage({
    super.key,
    required this.id,
    required this.sourceKey,
    this.cover,
    this.title,
    this.heroID,
  });

  final String id;

  final String sourceKey;

  final String? cover;

  final String? title;

  final int? heroID;

  @override
  State<ComicPage> createState() => _ComicPageState();
}

class _ComicPageState extends LoadingState<ComicPage, ComicDetails>
    with _ComicPageActions {
  @override
  History? history;

  bool showAppbarTitle = false;

  var scrollController = ScrollController();

  bool isDownloaded = false;

  bool showFAB = false;

  String? detailsLoadError;

  bool _networkFetching = false;

  /// The backing local-library comic for this page, when there is one. Lets the
  /// cover load directly from disk for pure local imports (issue #38).
  LocalComic? _localComic;

  bool descriptionExpanded = false;

  final ComicStateRepository _comicStateRepository =
      const ComicStateRepository();

  @override
  void onReadEnd() {
    history ??= _comicStateRepository.load(widget.sourceKey, widget.id).history;
    update();
  }

  @override
  Widget buildLoading() {
    return _ComicPageLoadingPlaceHolder(
      cover: widget.cover,
      title: widget.title,
      sourceKey: widget.sourceKey,
      cid: widget.id,
      heroID: widget.heroID,
    );
  }

  @override
  Widget buildError() {
    final isDownloaded = LocalManager().isDownloaded(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );

    // 构建基本的操作按钮
    final actions = <Widget>[];

    // 如果已下载，显示阅读按钮
    if (isDownloaded) {
      actions.add(FilledButton.tonal(
        child: Text("Read".tl),
        onPressed: () {
          final localComic = _comicStateRepository
              .load(widget.sourceKey, widget.id)
              .localComic;
          if (localComic == null) {
            context.showMessage(message: "Local comic not found".tl);
            return;
          }
          localComic.read();
        },
      ));
    }

    // 查询已关联的源
    List<DomainComicSourceLink> relatedLinks = [];
    if (_comicStateRepository.isDomainReady) {
      try {
        // 构建一个临时的 Comic 对象用于查询
        final tempComic = Comic(
          widget.title ?? '',
          widget.cover ?? '',
          widget.id,
          null,
          null,
          '',
          widget.sourceKey,
          null,
          null,
        );
        relatedLinks = _comicStateRepository
            .relatedSourcesFor(tempComic)
            .where((link) => link.status == 'accepted')
            .toList();
      } catch (e) {
        // 忽略错误，继续显示基本错误页面
      }
    }

    return NetworkError(
      message: error!,
      retry: retry,
      action: actions.isEmpty ? null : Row(
        mainAxisSize: MainAxisSize.min,
        children: actions.map((action) => Padding(
          padding: const EdgeInsets.only(left: 8),
          child: action,
        )).toList(),
      ),
      relatedLinks: relatedLinks,
      comic: widget.title != null || widget.cover != null
          ? Comic(
              widget.title ?? widget.id,
              widget.cover ?? '',
              widget.id,
              null,
              null,
              '',
              widget.sourceKey,
              null,
              null,
            )
          : null,
    );
  }

  @override
  void initState() {
    scrollController.addListener(onScroll);
    super.initState();
  }

  @override
  void dispose() {
    scrollController.removeListener(onScroll);
    super.dispose();
  }

  @override
  void update() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  ComicDetails get comic => data!;

  void onScroll() {
    var offset =
        scrollController.position.pixels -
        scrollController.position.minScrollExtent;
    var showFAB = offset > 0;
    if (showFAB != this.showFAB) {
      setState(() {
        this.showFAB = showFAB;
      });
    }
    if (offset > 100) {
      if (!showAppbarTitle) {
        setState(() {
          showAppbarTitle = true;
        });
      }
    } else {
      if (showAppbarTitle) {
        setState(() {
          showAppbarTitle = false;
        });
      }
    }
  }

  @override
  Widget buildContent(BuildContext context, ComicDetails data) {
    return Scaffold(
      floatingActionButton: showFAB
          ? FloatingActionButton(
              onPressed: () {
                scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.ease,
                );
              },
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: SmoothCustomScrollView(
        controller: scrollController,
        // Draggable fast-scroll thumb (#91): comic detail pages can be long —
        // some sources show a full preview here — so reuse the same scrollbar
        // the list pages have. The SliverAppbar scrolls with the content, so
        // inset the thumb by the top bar height to clear it.
        scrollbar: true,
        scrollbarTopPadding: context.padding.top + 56,
        slivers: [
          ...buildTitle(),
          buildActions(),
          buildDescription(),
          buildChapters(),
          buildComments(),
          buildThumbnails(),
          buildRecommend(),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: context.padding.bottom + 80,
            ), // Add additional padding for FAB
          ),
        ],
      ),
    );
  }

  @override
  Future<Res<ComicDetails>> loadData() async {
    var state = _comicStateRepository.load(widget.sourceKey, widget.id);
    var localComic = state.localComic;

    // Local-first: if the comic is already in the local library (whether a
    // purely local import or downloaded from a source), show its details
    // immediately so it opens instantly and can be read offline. The network
    // fetch (if a source is available) still runs in the background to enrich
    // comments/recommendations.
    if (localComic != null) {
      _comicStateRepository.mirrorLocalComic(localComic);
      _localComic = localComic;
      isAddToLocalFav = state.isLocalFavorite;
      history = state.history;
      isDownloaded = true;
      detailsLoadError = null;
      var comicSource = ComicSource.find(widget.sourceKey);
      if (comicSource != null && comicSource.loadComicInfo != null) {
        _networkFetching = true;
        scheduleMicrotask(() => _fetchNetworkDetails(comicSource));
      }
      return Res(_localDetails(localComic, state));
    }

    if (widget.sourceKey == 'local') {
      return const Res.error('Local comic not found');
    }

    isAddToLocalFav = state.isLocalFavorite;
    history = state.history;
    detailsLoadError = null;
    var comicSource = ComicSource.find(widget.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      detailsLoadError = 'Comic source not found';
      return Res(_fallbackDetails(state));
    }
    // Return local data immediately, fetch network data in background
    _networkFetching = true;
    scheduleMicrotask(() => _fetchNetworkDetails(comicSource));
    return Res(_fallbackDetails(state));
  }

  ComicDetails _localDetails(LocalComic localComic, ComicState state) {
    var tagsMap = <String, List<String>>{};
    for (var tag in localComic.tags) {
      var parts = tag.split(':');
      var key = parts.length > 1 ? parts.first : 'Tags';
      var value = parts.length > 1 ? parts.sublist(1).join(':') : tag;
      tagsMap.putIfAbsent(key, () => []).add(value);
    }
    return ComicDetails.fromJson({
      'title': localComic.title,
      'subtitle': localComic.subtitle,
      'cover': localComic.cover,
      'description': localComic.description,
      'tags': tagsMap,
      'chapters': localComic.chapters?.toJson(),
      'sourceKey': widget.sourceKey,
      'comicId': widget.id,
      'thumbnails': null,
      'recommend': null,
      'isFavorite': state.isLocalFavorite,
      'subId': null,
      'likesCount': null,
      'isLiked': null,
      'commentCount': null,
      'uploader': null,
      'uploadTime': null,
      'updateTime': null,
      'url': null,
      'stars': null,
      'maxPage': null,
      'comments': null,
    });
  }

  /// Re-attempt the background network fetch after it failed (issue #105).
  /// Useful when the user switched networks and wants to reload chapters
  /// without leaving and re-entering the page.
  void retryLoadDetails() {
    if (_networkFetching) return;
    var source = ComicSource.find(widget.sourceKey);
    if (source == null || source.loadComicInfo == null) return;
    setState(() {
      detailsLoadError = null;
      _networkFetching = true;
    });
    scheduleMicrotask(() => _fetchNetworkDetails(source));
  }

  Future<void> _fetchNetworkDetails(ComicSource source) async {
    int retryCount = 0;
    while (retryCount < 3) {
      try {
        final res = await source.loadComicInfo!(widget.id);
        if (!mounted) return;
        if (res.success) {
          detailsLoadError = null;
          _networkFetching = false;
          setState(() {
            data = res.data;
          });
          await onDataLoaded();
          return;
        }
        retryCount++;
        if (retryCount < 3) await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        if (!mounted) return;
        retryCount++;
        if (retryCount >= 3) {
          _networkFetching = false;
          detailsLoadError = e.toString();
          setState(() {});
          return;
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    if (!mounted) return;
    _networkFetching = false;
    detailsLoadError = 'Load failed';
    setState(() {});
  }

  ComicDetails _fallbackDetails(ComicState state) {
    return ComicDetails.fromJson({
      'title': state.title ?? widget.title ?? widget.id,
      'subtitle': null,
      'cover': state.cover ?? widget.cover ?? '',
      'description': null,
      'tags': <String, List<String>>{},
      'chapters': null,
      'sourceKey': widget.sourceKey,
      'comicId': widget.id,
      'thumbnails': null,
      'recommend': null,
      'isFavorite': state.isLocalFavorite,
      'subId': null,
      'likesCount': null,
      'isLiked': null,
      'commentCount': null,
      'uploader': null,
      'uploadTime': null,
      'updateTime': null,
      'url': null,
      'stars': null,
      'maxPage': null,
      'comments': null,
    });
  }

  @override
  Future<void> onDataLoaded() async {
    _comicStateRepository.mirrorComicDetails(comic);
    isLiked = comic.isLiked ?? false;
    isFavorite = comic.isFavorite ?? false;
    // For sources with multi-folder favorites, prefer querying folders to get accurate favorite status
    // Some sources may not set isFavorite reliably when multi-folder is enabled
    final source = ComicSource.find(comic.sourceKey);
    if (source?.favoriteData?.loadFolders != null && source!.isLogged) {
      var res = await source.favoriteData!.loadFolders!(comic.id);
      if (!res.error) {
        if (res.subData is List) {
          var list = List<String>.from(res.subData);
          isFavorite = list.isNotEmpty;
          update();
        }
      }
    }
    if (comic.chapters == null) {
      isDownloaded = LocalManager().isDownloaded(comic.id, comic.comicType, 0);
    }
  }

  Iterable<Widget> buildTitle() sync* {
    yield SliverAppbar(
      title: AnimatedOpacity(
        opacity: showAppbarTitle ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Text(comic.title),
      ),
      actions: [
        if (!isDownloaded)
          IconButton(
            onPressed: download,
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Download'.tl,
          ),
        IconButton(
          onPressed: share,
          icon: const Icon(Icons.share),
          tooltip: 'Share'.tl,
        ),
        IconButton(
          onPressed: showMoreActions,
          icon: const Icon(Icons.more_horiz),
        ),
      ],
    );

    yield const SliverPadding(padding: EdgeInsets.only(top: 8));

    yield SliverLazyToBoxAdapter(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 16),
          GestureDetector(
            onTap: () => _viewCover(context),
            onLongPress: () => _saveCover(context),
            child: Hero(
              tag: "cover${widget.heroID}",
              child: Container(
                decoration: BoxDecoration(
                  color: context.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: context.colorScheme.outlineVariant,
                      blurRadius: 1,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                height: 144,
                width: 144 * 0.72,
                clipBehavior: Clip.antiAlias,
                child: AnimatedImage(
                  image: comicDetailCoverProvider(
                    sourceKey: comic.sourceKey,
                    id: comic.id,
                    cover: widget.cover ?? comic.cover,
                    localComic: _localComic,
                  ),
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(comic.title, style: ts.s18),
                if (comic.subTitle != null)
                  SelectableText(
                    comic.subTitle!,
                    style: ts.s14,
                  ).paddingVertical(4),
                const SizedBox(height: 6),
                () {
                    final chapterProgress = _comicStateRepository
                        .chapterProgressFromDetails(comic, history);
                    return ComicDescription(
                      title: comic.title,
                      subtitle:
                          comic.findAuthor() ??
                          comic.subTitle ??
                          comic.uploader ??
                          '',
                      description: comic.description ?? '',
                      badge: ComicSource.find(comic.sourceKey)?.name,
                      tags: comic.plainTags,
                      maxLines: 3,
                      enableTranslate:
                          ComicSource.find(
                            comic.sourceKey,
                          )?.enableTagsTranslate ??
                          false,
                      rating: comic.stars,
                      updateText: comic.findUpdateTime() ?? comic.updateTime,
                      progressText:
                          chapterProgress.currentTitle ?? history?.description,
                      pagesText: comic.maxPage?.toString(),
                      showTitle: false,
                      onTapAuthor: (author, namespace) {
                        onTapTag(author, namespace ?? 'author');
                      },
                      onTapTag: onTapTag,
                      enableLongPressCopy: true,
                    );
                  }(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildActions() {
    bool isMobile = context.width < changePoint;
    bool hasHistory = history != null && (history!.ep > 1 || history!.page > 1);
    final source = ComicSource.find(comic.sourceKey);
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (hasHistory && !isMobile)
                _ActionButton(
                  icon: const Icon(Icons.menu_book),
                  text: 'Continue'.tl,
                  onPressed: continueRead,
                  iconColor: context.useTextColor(Colors.yellow),
                ),
              if (!isMobile || hasHistory)
                _ActionButton(
                  icon: const Icon(Icons.play_circle_outline),
                  text: 'Start'.tl,
                  onPressed: read,
                  iconColor: context.useTextColor(Colors.orange),
                ),
              if (data!.isLiked != null)
                _ActionButton(
                  icon: const Icon(Icons.favorite_border),
                  activeIcon: const Icon(Icons.favorite),
                  isActive: isLiked,
                  text:
                      ((data!.likesCount != null)
                              ? (data!.likesCount! + (isLiked ? 1 : 0))
                              : (isLiked ? 'Liked'.tl : 'Like'.tl))
                          .toString(),
                  isLoading: isLiking,
                  onPressed: likeOrUnlike,
                  iconColor: context.useTextColor(Colors.red),
                ),
              _ActionButton(
                icon: const Icon(Icons.bookmark_outline_outlined),
                activeIcon: const Icon(Icons.bookmark),
                isActive: isFavorite || isAddToLocalFav,
                text: 'Favorite'.tl,
                onPressed: openFavPanel,
                onLongPressed: quickFavorite,
                iconColor: context.useTextColor(Colors.purple),
              ),
              _ActionButton(
                icon: const Icon(Icons.watch_later_outlined),
                activeIcon: const Icon(Icons.watch_later),
                isActive: isInReadLater,
                text: 'Read Later'.tl,
                onPressed: toggleReadLater,
                iconColor: context.useTextColor(Colors.teal),
              ),
              if (source?.commentsLoader != null)
                _ActionButton(
                  icon: const Icon(Icons.comment),
                  text: (comic.commentCount ?? 'Comments'.tl).toString(),
                  onPressed: showComments,
                  iconColor: context.useTextColor(Colors.green),
                ),
            ],
          ).fixHeight(48),
          if (isMobile)
            Row(
              children: [
                Expanded(
                  child: hasHistory
                      ? FilledButton(
                          onPressed: continueRead,
                          child: Text("Continue".tl),
                        )
                      : FilledButton(onPressed: read, child: Text("Read".tl)),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          if (history != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: context.colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.history, color: context.useTextColor(Colors.teal)),
                  const SizedBox(width: 8),
                  Builder(
                    builder: (context) {
                      bool haveChapter = comic.chapters != null;
                      var page = history!.page;
                      var ep = history!.ep;
                      var group = history!.group;
                      String text;
                      if (haveChapter) {
                        final groupName = group == null
                            ? null
                            : comic.chapters!.groupTitleAt(group);
                        final chapterTitle = comic.chapters!.titleAt(
                          ep,
                          group: group,
                        );
                        final epName =
                            (chapterTitle != null && chapterTitle.isNotEmpty)
                            ? chapterTitle
                            : "E$ep";
                        text = groupName == null
                            ? "${"Last Reading".tl}: $epName P$page"
                            : "${"Last Reading".tl}: $groupName $epName P$page";
                      } else {
                        text = "${"Last Reading".tl}: P$page";
                      }
                      return Text(text);
                    },
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
          const Divider(),
        ],
      ).paddingTop(16),
    );
  }

  Widget buildDescription() {
    if (comic.description == null || comic.description!.trim().isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListTile(
            title: Text("Description".tl),
            trailing: TextButton.icon(
              icon: Icon(
                descriptionExpanded
                    ? Icons.keyboard_arrow_up
                    : Icons.keyboard_arrow_down,
              ),
              onPressed: () {
                setState(() {
                  descriptionExpanded = !descriptionExpanded;
                });
              },
              label: Text(descriptionExpanded ? 'Collapse'.tl : 'Expand'.tl),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(
              comic.description!,
              maxLines: descriptionExpanded ? null : 1,
            ).fixWidth(double.infinity),
          ),
          const SizedBox(height: 16),
          const Divider(),
        ],
      ),
    );
  }

  Widget buildInfo() {
    if (comic.tags.isEmpty &&
        comic.uploader == null &&
        comic.uploadTime == null &&
        comic.uploadTime == null &&
        comic.maxPage == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }

    int i = 0;

    Widget buildTag({
      required String text,
      VoidCallback? onTap,
      bool isTitle = false,
    }) {
      Color color;
      if (isTitle) {
        const colors = [
          Colors.blue,
          Colors.cyan,
          Colors.red,
          Colors.pink,
          Colors.purple,
          Colors.indigo,
          Colors.teal,
          Colors.green,
          Colors.lime,
          Colors.yellow,
        ];
        color = context.useBackgroundColor(colors[(i++) % (colors.length)]);
      } else {
        color = context.colorScheme.surfaceContainerLow;
      }

      final borderRadius = BorderRadius.circular(12);

      const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 6);

      if (onTap != null) {
        return Material(
          color: color,
          borderRadius: borderRadius,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: onTap,
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: text));
              context.showMessage(message: "Copied".tl);
            },
            onSecondaryTapDown: (details) {
              showMenuX(context, details.globalPosition, [
                MenuEntry(
                  icon: Icons.remove_red_eye,
                  text: "View".tl,
                  onClick: onTap,
                ),
                MenuEntry(
                  icon: Icons.copy,
                  text: "Copy".tl,
                  onClick: () {
                    Clipboard.setData(ClipboardData(text: text));
                    context.showMessage(message: "Copied".tl);
                  },
                ),
              ]);
            },
            child: Text(text).padding(padding),
          ),
        );
      } else {
        Widget tag = Container(
          decoration: BoxDecoration(color: color, borderRadius: borderRadius),
          child: Text(text).padding(padding),
        );
        // Namespace headers (isTitle) are just labels — only the actual values
        // are worth copying.
        if (!isTitle) {
          tag = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: text));
              context.showMessage(message: "Copied".tl);
            },
            child: tag,
          );
        }
        return tag;
      }
    }

    String formatTime(String time) {
      if (int.tryParse(time) != null) {
        var t = int.tryParse(time);
        if (t! > 1000000000000) {
          return DateTime.fromMillisecondsSinceEpoch(
            t,
          ).toString().substring(0, 19);
        } else {
          return DateTime.fromMillisecondsSinceEpoch(
            t * 1000,
          ).toString().substring(0, 19);
        }
      }
      if (time.contains('T') || time.contains('Z')) {
        var t = DateTime.parse(time);
        return t.toString().substring(0, 19);
      }
      return time;
    }

    Widget buildWrap({required List<Widget> children}) {
      return Wrap(
        runSpacing: 8,
        spacing: 8,
        children: children,
      ).paddingHorizontal(16).paddingBottom(8);
    }

    final source = comicSource;
    bool enableTranslation =
        App.locale.languageCode == 'zh' && source?.enableTagsTranslate == true;

    return SliverLazyToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text("Information".tl)),
          if (comic.stars != null)
            Row(
              children: [
                StarRating(value: comic.stars!, size: 24, onTap: starRating),
                const SizedBox(width: 8),
                Text(comic.stars!.toStringAsFixed(2)),
              ],
            ).paddingLeft(16).paddingVertical(8),
          for (var e in comic.tags.entries)
            buildWrap(
              children: [
                if (e.value.isNotEmpty)
                  buildTag(
                    text: source == null ? e.key : e.key.ts(source.key),
                    isTitle: true,
                  ),
                for (var tag in e.value)
                  buildTag(
                    text: enableTranslation
                        ? TagsTranslation.translationTagWithNamespace(
                            tag,
                            e.key.toLowerCase(),
                          )
                        : tag,
                    onTap: () => onTapTag(tag, e.key),
                  ),
              ],
            ),
          if (comic.uploader != null)
            buildWrap(
              children: [
                buildTag(text: 'Uploader'.tl, isTitle: true),
                buildTag(text: comic.uploader!),
              ],
            ),
          if (comic.uploadTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Upload Time'.tl, isTitle: true),
                buildTag(text: formatTime(comic.uploadTime!)),
              ],
            ),
          if (comic.updateTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Update Time'.tl, isTitle: true),
                buildTag(text: formatTime(comic.updateTime!)),
              ],
            ),
          if (comic.maxPage != null)
            buildWrap(
              children: [
                buildTag(text: 'Pages'.tl, isTitle: true),
                buildTag(text: comic.maxPage.toString()),
              ],
            ),
          const SizedBox(height: 12),
          const Divider(),
        ],
      ),
    );
  }

  Widget buildChapters() {
    if (comic.chapters == null) {
      if (detailsLoadError != null) {
        return SliverLazyToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(title: Text("Chapters".tl)),
              Container(
                width: double.infinity,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Chapter load failed: @message".tlParams({
                        "message": detailsLoadError!,
                      }),
                      style: TextStyle(
                        color: context.colorScheme.onErrorContainer,
                      ),
                    ),
                    if (comicSource?.loadComicInfo != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonal(
                          onPressed: retryLoadDetails,
                          child: Text("Retry".tl),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
            ],
          ),
        );
      }
      if (_networkFetching) {
        return SliverLazyToBoxAdapter(
          child: Column(
            children: [
              ListTile(title: Text("Chapters".tl)),
              const Center(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
            ],
          ),
        );
      }
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _ComicChapters(
      history: history,
      groupedMode: comic.chapters!.isGrouped,
    );
  }

  Widget buildThumbnails() {
    final source = comicSource;
    if (comic.thumbnails == null &&
        (source == null || source.loadComicThumbnail == null)) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return const _ComicThumbnails();
  }

  Widget buildRecommend() {
    if (comic.recommend == null || comic.recommend!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: ListTile(title: Text("Related".tl))),
        SliverGridComics(comics: comic.recommend!),
      ],
    );
  }

  Widget buildComments() {
    if (comic.comments == null || comic.comments!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _CommentsPart(comments: comic.comments!, showMore: showComments);
  }

  void _viewCover(BuildContext context) {
    final imageProvider = comicDetailCoverProvider(
      sourceKey: comic.sourceKey,
      id: comic.id,
      cover: widget.cover ?? comic.cover,
      localComic: _localComic,
    );

    context.to(
      () => _CoverViewer(
        imageProvider: imageProvider,
        title: comic.title,
        heroTag: "cover${widget.heroID}",
      ),
    );
  }

  void _saveCover(BuildContext context) async {
    try {
      final imageProvider = comicDetailCoverProvider(
        sourceKey: comic.sourceKey,
        id: comic.id,
        cover: widget.cover ?? comic.cover,
        localComic: _localComic,
      );

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<Uint8List>();

      imageStream.addListener(
        ImageStreamListener((ImageInfo info, bool _) async {
          final byteData = await info.image.toByteData(
            format: ImageByteFormat.png,
          );
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          }
        }),
      );

      final data = await completer.future;
      final fileType = detectFileType(data);
      await saveFile(filename: "cover${fileType.ext}", data: data);
    } catch (e) {
      if (context.mounted) {
        context.showMessage(message: "Error".tl);
      }
    }
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    this.onLongPressed,
    this.activeIcon,
    this.isActive,
    this.isLoading,
    this.iconColor,
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool? isActive;

  final String text;

  final void Function() onPressed;

  final bool? isLoading;

  final Color? iconColor;

  final void Function()? onLongPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (!(isLoading ?? false)) {
            onPressed();
          }
        },
        onLongPress: onLongPressed,
        borderRadius: BorderRadius.circular(18),
        child: IconTheme.merge(
          data: IconThemeData(size: 20, color: iconColor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading ?? false)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              else
                (isActive ?? false) ? (activeIcon ?? icon) : icon,
              const SizedBox(width: 8),
              Text(text),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(this.eps, this.finishSelect, this.downloadedEps);

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.eps.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      var res = <int>[];
                      for (int i = 0; i < widget.eps.length; i++) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(selected);
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _ComicPageLoadingPlaceHolder extends StatelessWidget {
  const _ComicPageLoadingPlaceHolder({
    this.cover,
    this.title,
    required this.sourceKey,
    required this.cid,
    this.heroID,
  });

  final String? cover;

  final String? title;

  final String sourceKey;

  final String cid;

  final int? heroID;

  @override
  Widget build(BuildContext context) {
    Widget buildContainer(
      double? width,
      double? height, {
      Color? color,
      double? radius,
    }) {
      return Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: color ?? context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(radius ?? 4),
        ),
      );
    }

    return Shimmer(
      color: context.isDarkMode ? Colors.grey.shade700 : Colors.white,
      child: Column(
        children: [
          Appbar(title: Text(""), backgroundColor: context.colorScheme.surface),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 16),
              buildImage(context),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Text(title ?? "", style: ts.s18)
                    else
                      buildContainer(200, 25),
                    const SizedBox(height: 8),
                    buildContainer(80, 20),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (context.width < changePoint)
            Row(
              children: [
                Expanded(child: buildContainer(null, 36, radius: 18)),
                const SizedBox(width: 16),
                Expanded(child: buildContainer(null, 36, radius: 18)),
              ],
            ).paddingHorizontal(16),
          const Divider(),
          const SizedBox(height: 8),
          Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
            ).fixHeight(24).fixWidth(24),
          ),
        ],
      ),
    );
  }

  Widget buildImage(BuildContext context) {
    Widget child;
    if (cover != null) {
      child = AnimatedImage(
        image: comicDetailCoverProvider(
          sourceKey: sourceKey,
          id: cid,
          cover: cover!,
          localComic: LocalManager().find(cid, ComicType.local),
        ),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      );
    } else {
      child = const SizedBox();
    }

    return Hero(
      tag: "cover$heroID",
      child: Container(
        decoration: BoxDecoration(
          color: context.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: context.colorScheme.outlineVariant,
              blurRadius: 1,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        height: 144,
        width: 144 * 0.72,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

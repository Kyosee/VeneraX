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
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/favorites_meta.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/pages/comic_details_page/glossary_editor.dart';
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

const double _comicDetailsWideBreakpoint = 760;

double _comicDetailsPageInset(BuildContext context) {
  // 主区域自适应窗口宽度：只保留基础边距，不再把内容夹在固定最大宽度内，
  // 避免宽屏/大分辨率下两侧留出大片空白。
  return context.width < 700 ? 12.0 : 24.0;
}

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
      actions.add(
        FilledButton.tonal(
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
        ),
      );
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
      action: actions.isEmpty
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: actions
                  .map(
                    (action) => Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: action,
                    ),
                  )
                  .toList(),
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
    PreTranslationTaskManager.instance.addListener(update);
    // The per-comic translation toggle lives in the service; listen so the
    // pre-translate button appears/disappears the moment it changes.
    ImageTranslationService.instance.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    scrollController.removeListener(onScroll);
    PreTranslationTaskManager.instance.removeListener(update);
    ImageTranslationService.instance.removeListener(update);
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
    final horizontalInset = _comicDetailsPageInset(context);

    Widget inset(Widget sliver) {
      return SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: horizontalInset),
        sliver: sliver,
      );
    }

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
          ...buildTitle(horizontalInset),
          inset(buildActions()),
          inset(buildDescription()),
          inset(buildChapters()),
          inset(buildComments()),
          inset(buildThumbnails()),
          inset(buildRecommend()),
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
        if (retryCount < 3) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
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

  Iterable<Widget> buildTitle(double horizontalInset) sync* {
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

    yield SliverPadding(
      padding: EdgeInsets.fromLTRB(horizontalInset, 12, horizontalInset, 0),
      sliver: SliverLazyToBoxAdapter(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= _comicDetailsWideBreakpoint;
            // 宽屏/大分辨率下封面缩小 10%（180 → 162）。
            final coverWidth = isWide
                ? 162.0
                : constraints.maxWidth < 400
                ? 96.0
                : 112.0;
            final coverHeight = coverWidth / 0.72;
            final cover = _buildDetailsCover(coverWidth);
            final summary = _buildComicSummary(isWide);
            // 宽屏时把阅读按钮的高度对齐封面高度，多按钮竖排时均分该高度。
            final readingActions = _buildReadingActions(
              isWide: isWide,
              maxHeight: coverHeight,
            );

            return isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      cover,
                      const SizedBox(width: 24),
                      Expanded(child: summary),
                      const SizedBox(width: 24),
                      SizedBox(width: 220, child: readingActions),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          cover,
                          const SizedBox(width: 16),
                          Expanded(child: summary),
                        ],
                      ),
                      const SizedBox(height: 18),
                      readingActions,
                    ],
                  );
          },
        ),
      ),
    );
  }

  Widget _buildDetailsCover(double width) {
    return GestureDetector(
      onTap: () => _viewCover(context),
      onLongPress: () => _saveCover(context),
      child: Hero(
        tag: "cover${widget.heroID}",
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: width,
            height: width / 0.72,
            child: AnimatedImage(
              image: comicDetailCoverProvider(
                sourceKey: comic.sourceKey,
                id: comic.id,
                cover: widget.cover ?? comic.cover,
                localComic: _localComic,
              ),
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildComicSummary(bool isWide) {
    final chapterProgress = _comicStateRepository.chapterProgressFromDetails(
      comic,
      history,
    );
    final titleStyle =
        (isWide
                ? Theme.of(context).textTheme.titleLarge
                : Theme.of(context).textTheme.titleMedium)
            ?.copyWith(height: 1.2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(comic.title, style: titleStyle),
        if (comic.subTitle?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 6),
          SelectableText(
            comic.subTitle!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: 12),
        ComicDescription(
          title: comic.title,
          subtitle:
              comic.findAuthor() ?? comic.subTitle ?? comic.uploader ?? '',
          description: comic.description ?? '',
          badge: ComicSource.find(comic.sourceKey)?.name,
          tags: comic.plainTags,
          maxLines: isWide ? 5 : 4,
          enableTranslate:
              ComicSource.find(comic.sourceKey)?.enableTagsTranslate ?? false,
          rating: comic.stars,
          updateText: comic.findUpdateTime() ?? comic.updateTime,
          progressText: chapterProgress.currentTitle ?? history?.description,
          pagesText: comic.maxPage?.toString(),
          showTitle: false,
          onTapAuthor: (author, namespace) {
            onTapTag(author, namespace ?? 'author');
          },
          onTapTag: onTapTag,
          enableLongPressCopy: true,
        ),
      ],
    );
  }

  Widget _buildReadingActions({bool isWide = false, double? maxHeight}) {
    // 按钮拉高后 M3 默认 StadiumBorder 会变成椭圆/胶囊，统一用矩形圆角。
    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
    );
    // 宽屏按钮被拉到封面高度，默认 14/19 的字号图标偏小、比例失衡；
    // 宽屏统一放大一档（16/24），窄屏保持原样。
    final double labelSize = isWide ? 16 : 14;
    final double iconSize = isWide ? 24 : 19;
    final filledStyle = FilledButton.styleFrom(
      shape: buttonShape,
      textStyle: TextStyle(fontSize: labelSize, fontWeight: FontWeight.w600),
      iconSize: iconSize,
    );
    final outlinedStyle = OutlinedButton.styleFrom(
      shape: buttonShape,
      textStyle: TextStyle(fontSize: labelSize, fontWeight: FontWeight.w600),
      iconSize: iconSize,
    );
    // Any recorded progress counts — a comic left at chapter 1 page 1 still
    // has a history entry, and the user expects a Continue button whenever
    // the history list shows one (issue #135).
    final hasHistory =
        history != null && (history!.ep > 0 || history!.page > 0);
    if (!hasHistory) {
      // 单按钮：宽屏下独占整个封面高度（100%），窄屏保持固定高度。
      return SizedBox(
        height: isWide && maxHeight != null ? maxHeight : 52,
        child: FilledButton.icon(
          onPressed: read,
          style: filledStyle,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text("Read".tl),
        ),
      );
    }
    // With reading history: "Start" (from the beginning) sits on top and
    // "Continue" (resume progress) below it. Continue keeps the filled/primary
    // emphasis despite being the lower button.
    final startButton = OutlinedButton.icon(
      onPressed: read,
      style: outlinedStyle,
      icon: const Icon(Icons.restart_alt_rounded),
      label: Text("Start".tl),
    );
    final continueButton = FilledButton.icon(
      onPressed: continueRead,
      style: filledStyle,
      icon: const Icon(Icons.menu_book_rounded),
      label: Text("Continue".tl),
    );
    // 宽屏且多按钮竖排：把封面高度均分给两个按钮，填满整列。
    if (isWide && maxHeight != null) {
      return SizedBox(
        height: maxHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: startButton),
            const SizedBox(height: 10),
            Expanded(child: continueButton),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: 52, child: startButton),
        const SizedBox(height: 10),
        SizedBox(height: 52, child: continueButton),
      ],
    );
  }

  Widget buildActions() {
    final source = ComicSource.find(comic.sourceKey);
    return SliverLazyToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (data!.isLiked != null)
                  _ActionButton(
                    icon: const Icon(Icons.favorite_border_rounded),
                    activeIcon: const Icon(Icons.favorite_rounded),
                    isActive: isLiked,
                    text:
                        ((data!.likesCount != null)
                                ? (data!.likesCount! + (isLiked ? 1 : 0))
                                : (isLiked ? 'Liked'.tl : 'Like'.tl))
                            .toString(),
                    isLoading: isLiking,
                    onPressed: likeOrUnlike,
                  ),
                _ActionButton(
                  icon: const Icon(Icons.bookmark_border_rounded),
                  activeIcon: const Icon(Icons.bookmark_rounded),
                  isActive: isFavorite || isAddToLocalFav,
                  text: 'Favorite'.tl,
                  onPressed: openFavPanel,
                  onLongPressed: quickFavorite,
                ),
                _ActionButton(
                  icon: const Icon(Icons.schedule_rounded),
                  activeIcon: const Icon(Icons.watch_later_rounded),
                  isActive: isInReadLater,
                  text: 'Read Later'.tl,
                  onPressed: toggleReadLater,
                ),
                if (source?.commentsLoader != null)
                  _ActionButton(
                    icon: const Icon(Icons.chat_bubble_outline_rounded),
                    text: (comic.commentCount ?? 'Comments'.tl).toString(),
                    onPressed: showComments,
                  ),
                if (ImageTranslationService.isReady &&
                    ImageTranslationService.isEnabledForComic(
                      comic.id,
                      comic.sourceKey,
                    ))
                  Builder(
                    builder: (context) {
                      var task = PreTranslationTaskManager.instance
                          .runningTaskFor(comic.id, comic.sourceKey);
                      if (task != null) {
                        var pct = task.total == 0
                            ? null
                            : (task.progress * 100)
                                  .clamp(0, 100)
                                  .toStringAsFixed(0);
                        return _ActionButton(
                          icon: const Icon(Icons.translate_rounded),
                          activeIcon: const Icon(Icons.translate_rounded),
                          isActive: true,
                          text: pct == null
                              ? 'Translating'.tl
                              : '${'Translating'.tl} $pct%',
                          onPressed: preTranslate,
                          onLongPressed: showTranslationMenu,
                        );
                      }
                      return _ActionButton(
                        icon: const Icon(Icons.translate_rounded),
                        text: 'Pre-translate'.tl,
                        onPressed: preTranslate,
                        onLongPressed: showTranslationMenu,
                      );
                    },
                  ),
              ],
            ),
            if (history != null) ...[
              const SizedBox(height: 12),
              _buildHistorySummary(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySummary() {
    final page = history!.page;
    final ep = history!.ep;
    final group = history!.group;
    String text;
    if (comic.chapters != null) {
      final groupName = group == null
          ? null
          : comic.chapters!.groupTitleAt(group);
      final chapterTitle = comic.chapters!.titleAt(ep, group: group);
      final epName = chapterTitle?.isNotEmpty == true ? chapterTitle! : "E$ep";
      text = groupName == null
          ? "${"Last Reading".tl}: $epName P$page"
          : "${"Last Reading".tl}: $groupName $epName P$page";
    } else {
      text = "${"Last Reading".tl}: P$page";
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.history_rounded,
            size: 18,
            color: context.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildDescription() {
    final description = comic.description?.trim() ?? '';
    if (description.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    final textStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(
      height: 1.55,
      color: context.colorScheme.onSurfaceVariant,
    );
    // Horizontal padding around the description text (see the Padding below);
    // subtracted from the card width when measuring whether it overflows.
    const textHPadding = 0.0;
    return SliverLazyToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Only surface the expand/collapse toggle when the text actually
            // spills past a single line. Previously the toggle was always shown
            // yet did nothing for short descriptions: SelectableText ignores
            // maxLines' ellipsis, so a "collapsed" description still rendered in
            // full. Measure the real line count up front and drive both the
            // toggle's visibility and the collapsed rendering from it.
            final painter = TextPainter(
              text: TextSpan(text: description, style: textStyle),
              maxLines: 1,
              textDirection: Directionality.of(context),
            )..layout(maxWidth: constraints.maxWidth - textHPadding);
            final overflows = painter.didExceedMaxLines;
            final collapsed = overflows && !descriptionExpanded;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ComicSectionHeader(
                  icon: Icons.notes_rounded,
                  title: "Description".tl,
                  horizontalPadding: 0,
                  trailing: overflows
                      ? TextButton.icon(
                          onPressed: () {
                            setState(() {
                              descriptionExpanded = !descriptionExpanded;
                            });
                          },
                          icon: Icon(
                            descriptionExpanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                          ),
                          label: Text(
                            descriptionExpanded ? 'Collapse'.tl : 'Expand'.tl,
                          ),
                        )
                      : null,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 2, 0, 12),
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 180),
                    alignment: Alignment.topCenter,
                    child: collapsed
                        // Truncated preview: a plain Text renders the ellipsis
                        // SelectableText can't. Selection isn't useful on
                        // clipped text anyway — the full text below is
                        // selectable once expanded.
                        ? Text(
                            description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: textStyle,
                          )
                        : SelectableText(
                            description,
                            style: textStyle,
                          ).fixWidth(double.infinity),
                  ),
                ),
              ],
            );
          },
        ),
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
          child: Container(
            margin: const EdgeInsets.only(top: 16, bottom: 8),
            decoration: BoxDecoration(
              color: context.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ComicSectionHeader(
                  icon: Icons.view_list_rounded,
                  title: "Chapters".tl,
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: context.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(14),
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
                        const SizedBox(height: 10),
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
              ],
            ),
          ),
        );
      }
      if (_networkFetching) {
        return SliverLazyToBoxAdapter(
          child: Container(
            margin: const EdgeInsets.only(top: 16, bottom: 8),
            decoration: BoxDecoration(
              color: context.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                _ComicSectionHeader(
                  icon: Icons.view_list_rounded,
                  title: "Chapters".tl,
                ),
                const Center(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(0, 12, 0, 28),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ],
            ),
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
        SliverToBoxAdapter(
          child: _ComicSectionHeader(
            icon: Icons.auto_awesome_mosaic_outlined,
            title: "Related".tl,
          ).paddingTop(20),
        ),
        SliverGridComics(comics: comic.recommend!),
        const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
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

class _ComicSectionHeader extends StatelessWidget {
  const _ComicSectionHeader({
    required this.icon,
    required this.title,
    this.trailing,
    this.horizontalPadding,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;

  /// Overrides the header's left/right padding when provided. Defaults keep the
  /// original asymmetric inset (12 / 8) used by the thumbnail & comment panels.
  final double? horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        horizontalPadding ?? 12,
        10,
        horizontalPadding ?? 8,
        6,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: context.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              icon,
              size: 19,
              color: context.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
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
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool? isActive;

  final String text;

  final void Function() onPressed;

  final bool? isLoading;

  final void Function()? onLongPressed;

  @override
  Widget build(BuildContext context) {
    final active = isActive ?? false;
    final foreground = active
        ? context.colorScheme.primary
        : context.colorScheme.onSurfaceVariant;
    return Material(
      color: active
          ? context.colorScheme.primaryContainer
          : context.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () {
          if (!(isLoading ?? false)) {
            onPressed();
          }
        },
        onLongPress: onLongPressed,
        borderRadius: BorderRadius.circular(12),
        child: IconTheme.merge(
          data: IconThemeData(size: 19, color: foreground),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isLoading ?? false)
                    SizedBox(
                      width: 19,
                      height: 19,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: foreground,
                      ),
                    )
                  else
                    active ? (activeIcon ?? icon) : icon,
                  const SizedBox(width: 8),
                  Text(
                    text,
                    style: TextStyle(
                      color: active
                          ? context.colorScheme.onPrimaryContainer
                          : context.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
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

/// Chapter multi-select for background pre-translation. Mirrors
/// [_SelectDownloadChapter] but has no "already done" disabled rows — a
/// chapter can always be re-queued (cached pages are skipped at run time).
class _SelectPreTranslateChapter extends StatefulWidget {
  const _SelectPreTranslateChapter({
    required this.cid,
    required this.sourceKey,
    required this.comicType,
    required this.entries,
    required this.finishSelect,
  });

  final String cid;
  final String sourceKey;
  final ComicType comicType;

  /// Ordered list of chapter entries (eid, display title).
  final List<(String, String)> entries;
  final void Function(List<int>) finishSelect;

  @override
  State<_SelectPreTranslateChapter> createState() =>
      _SelectPreTranslateChapterState();
}

class _SelectPreTranslateChapterState
    extends State<_SelectPreTranslateChapter> {
  List<int> selected = [];

  @override
  void initState() {
    super.initState();
    PreTranslationTaskManager.instance.addListener(_onTaskUpdate);
  }

  @override
  void dispose() {
    PreTranslationTaskManager.instance.removeListener(_onTaskUpdate);
    super.dispose();
  }

  void _onTaskUpdate() {
    if (mounted) setState(() {});
  }

  /// The trailing status widget for chapter [index]: nothing when idle, a
  /// "waiting" chip when queued but not started, a live progress bar while
  /// translating, or a "translated" tick when done. Distinguishes an active
  /// (running-job) chapter from one merely finished in history.
  Widget? _buildChapterStatus(int index) {
    var eid = widget.entries[index].$1;
    var manager = PreTranslationTaskManager.instance;
    var chapter = manager.chapterProgressFor(widget.cid, widget.sourceKey, eid);
    if (chapter == null) return null;
    var active = manager.isChapterActive(widget.cid, widget.sourceKey, eid);
    var processed = chapter.done + chapter.failed;
    var isCompleted = chapter.total > 0 && processed >= chapter.total;

    if (isCompleted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 16,
            color: context.colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            "Translated".tl,
            style: ts.s12.withColor(context.colorScheme.primary),
          ),
        ],
      );
    }

    if (!active) return null;

    // Active but nothing processed yet (page count unknown or not started):
    // show a "waiting" state so the user knows it is queued.
    if (chapter.total == 0 || processed == 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 6),
          Text(
            "Waiting".tl,
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
        ],
      );
    }

    var pct = (processed / chapter.total).clamp(0.0, 1.0);
    return SizedBox(
      width: 120,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${chapter.done}/${chapter.total}',
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          LinearProgressIndicator(value: pct),
        ],
      ),
    );
  }

  /// Confirms before starting: pre-translation sends roughly one LLM request
  /// per page, so a multi-chapter run against a paid endpoint can be costly.
  /// Small selections start straight away; larger ones ask first.
  void _confirmAndStart() {
    selected.sort();
    void start() {
      widget.finishSelect(selected);
      context.pop();
    }

    // A single chapter is cheap enough to skip the prompt.
    if (selected.length < 2) {
      start();
      return;
    }
    showConfirmDialog(
      context: context,
      title: "Start pre-translation?".tl,
      content: "About to translate @count chapters. Each page is roughly one "
              "LLM request; on a paid endpoint this may cost money."
          .tlParams({'count': selected.length}),
      onConfirm: start,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Pre-translate".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.entries.length,
              itemBuilder: (context, i) {
                var title = widget.entries[i].$2;
                var progress = _buildChapterStatus(i);
                return CheckboxListTile(
                  title: Row(
                    children: [
                      Expanded(child: Text(title)),
                      if (progress != null) ...[
                        const SizedBox(width: 8),
                        progress,
                      ],
                    ],
                  ),
                  value: selected.contains(i),
                  onChanged: (v) {
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
                      widget.finishSelect(
                        [for (int i = 0; i < widget.entries.length; i++) i],
                      );
                      context.pop();
                    },
                    child: Text("Select All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty ? null : _confirmAndStart,
                    child: Text("Start".tl),
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
          borderRadius: BorderRadius.circular(radius ?? 10),
        ),
      );
    }

    return Shimmer(
      color: context.isDarkMode ? Colors.grey.shade700 : Colors.white,
      child: Column(
        children: [
          Appbar(title: Text(""), backgroundColor: context.colorScheme.surface),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: _comicDetailsPageInset(context)),
              buildImage(context, context.width >= 840 ? 162 : 112),
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
              if (context.width >= 840) ...[
                const SizedBox(width: 24),
                SizedBox(
                  width: 220,
                  child: Column(
                    children: [
                      buildContainer(null, 52, radius: 14),
                      const SizedBox(height: 10),
                      buildContainer(null, 52, radius: 14),
                    ],
                  ),
                ),
              ],
              SizedBox(width: _comicDetailsPageInset(context)),
            ],
          ),
          const SizedBox(height: 8),
          if (context.width < 840)
            Column(
              children: [
                buildContainer(null, 52, radius: 14),
                const SizedBox(height: 10),
                buildContainer(null, 52, radius: 14),
              ],
            ).paddingHorizontal(_comicDetailsPageInset(context)),
          const SizedBox(height: 20),
          Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
            ).fixHeight(24).fixWidth(24),
          ),
        ],
      ),
    );
  }

  Widget buildImage(BuildContext context, double width) {
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
          borderRadius: BorderRadius.circular(14),
        ),
        height: width / 0.72,
        width: width,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

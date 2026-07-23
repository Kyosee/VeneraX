part of 'reader.dart';

const _readerChromeAnimationDuration = Duration(milliseconds: 140);

class _ReaderScaffold extends StatefulWidget {
  const _ReaderScaffold({required this.child});

  final Widget child;

  @override
  State<_ReaderScaffold> createState() => _ReaderScaffoldState();
}

class _ReaderScaffoldState extends State<_ReaderScaffold> {
  bool _isOpen = false;

  static const kTopBarHeight = 56.0;

  static const kBottomBarHeight = 105.0;

  bool get isOpen => _isOpen;

  bool get isReversed =>
      context.reader.mode == ReaderMode.galleryRightToLeft ||
      context.reader.mode == ReaderMode.continuousRightToLeft;

  int showFloatingButtonValue = 0;

  var lastValue = 0;

  _ReaderGestureDetectorState? _gestureDetectorState;

  void setFloatingButton(int value) {
    lastValue = showFloatingButtonValue;
    if (value == 0) {
      if (showFloatingButtonValue != 0) {
        showFloatingButtonValue = 0;
        update();
      }
    }
    if (value == 1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = 1;
      update();
    } else if (value == -1 && showFloatingButtonValue == 0) {
      showFloatingButtonValue = -1;
      update();
    }
  }

  _DragListener? _imageFavoriteDragListener;

  void addDragListener() async {
    if (!mounted) return;

    // 横向阅读的时候, 如果纵向滑就触发收藏, 纵向阅读的时候, 如果横向滑动就触发收藏
    if (appdata.settings['quickCollectImage'] == 'Swipe') {
      if (_imageFavoriteDragListener == null) {
        double crossAxisDistance = 0;
        double mainAxisDistance = 0;
        bool startedAtEdge = false;
        // 系统返回手势（iOS 滑动返回、安卓手势导航）从屏幕左右边缘起始；
        // 该区域起始的拖动不参与滑动收藏判定，否则返回手势会被误认成收藏。
        const edgeExclusion = 44.0;
        _imageFavoriteDragListener = _DragListener(
          onStart: (point) {
            crossAxisDistance = 0;
            mainAxisDistance = 0;
            var width = context.reader.size.width;
            startedAtEdge =
                point.dx < edgeExclusion || point.dx > width - edgeExclusion;
          },
          onMove: (offset) {
            // 每次读取当前阅读模式：监听器只注册一次，若捕获创建时的模式，
            // 阅读中途切换方向后收藏手势的轴向判断会一直沿用旧模式。
            switch (context.reader.mode) {
              case ReaderMode.continuousTopToBottom:
              case ReaderMode.galleryTopToBottom:
                crossAxisDistance += offset.dx;
                mainAxisDistance += offset.dy;
              case ReaderMode.continuousLeftToRight:
              case ReaderMode.galleryLeftToRight:
              case ReaderMode.galleryRightToLeft:
              case ReaderMode.continuousRightToLeft:
                crossAxisDistance += offset.dy;
                mainAxisDistance += offset.dx;
            }
          },
          onEnd: () {
            // 除跨轴位移达标外，还要求整段手势明显以跨轴为主：长距离翻页/滚动
            // 里的斜向漂移（主轴位移远大于跨轴）不应触发收藏。
            if (!startedAtEdge &&
                crossAxisDistance.abs() > 150 &&
                crossAxisDistance.abs() > mainAxisDistance.abs() * 2) {
              addImageFavorite();
            }
            crossAxisDistance = 0;
            mainAxisDistance = 0;
          },
        );
      }
      _gestureDetectorState!.addDragListener(_imageFavoriteDragListener!);
    } else if (_imageFavoriteDragListener != null) {
      _gestureDetectorState!.removeDragListener(_imageFavoriteDragListener!);
    }
  }

  @override
  void initState() {
    sliderFocus.canRequestFocus = false;
    sliderFocus.addListener(() {
      if (sliderFocus.hasFocus) {
        sliderFocus.nextFocus();
      }
    });
    if (rotation != null) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    super.initState();
    Future.delayed(const Duration(milliseconds: 200), addDragListener);
  }

  @override
  void dispose() {
    sliderFocus.dispose();
    super.dispose();
  }

  void openOrClose() {
    if (!_isOpen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } else {
      if (!appdata.settings['showSystemStatusBar']) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
    setState(() {
      _isOpen = !_isOpen;
    });
  }

  bool? rotation;

  void update() {
    setState(() {});
  }

  /// Night mode overlay tint, selected by `readerNightModeColor` setting.
  Color _nightModeColor() {
    switch (appdata.settings['readerNightModeColor']) {
      case 'black':
        return const Color(0xFF000000);
      case 'red':
        return const Color(0xFF3A0000);
      case 'warm':
      default:
        return const Color(0xFF2A1800);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOnChapterCommentsPage = context.reader.isOnChapterCommentsPage;
    return Stack(
      children: [
        Positioned.fill(
          child: AbsorbPointer(
            absorbing: context.reader.isPageAnimating,
            child: widget.child,
          ),
        ),
        if (appdata.settings['readerNightMode'] == true)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: _nightModeColor().toOpacity(
                  ((appdata.settings['readerNightModeIntensity'] as num?)
                              ?.toDouble() ??
                          0.45)
                      .clamp(0.1, 0.85),
                ),
              ),
            ),
          ),
        if (appdata.settings['showPageNumberInReader'] == true &&
            !isOnChapterCommentsPage)
          buildPageInfoText(),
        if (!isOnChapterCommentsPage) buildStatusInfo(),
        Positioned(
          right: 16,
          bottom: 36,
          child: IgnorePointer(
            ignoring: showFloatingButtonValue == 0,
            child: AnimatedSlide(
              duration: _readerChromeAnimationDuration,
              curve: Curves.easeOutCubic,
              offset: showFloatingButtonValue == 0
                  ? const Offset(0, 2)
                  : Offset.zero,
              child: buildEpChangeButton(),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: kTopBarHeight + context.padding.top,
          child: AnimatedSlide(
            duration: _readerChromeAnimationDuration,
            curve: Curves.easeOutCubic,
            offset: _isOpen ? Offset.zero : const Offset(0, -1),
            child: RepaintBoundary(child: buildTop()),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: AnimatedSlide(
            duration: _readerChromeAnimationDuration,
            curve: Curves.easeOutCubic,
            offset: _isOpen ? Offset.zero : const Offset(0, 1),
            child: RepaintBoundary(child: buildBottom()),
          ),
        ),
      ],
    );
  }

  Widget buildTop() {
    final epName = context.reader.widget.chapters?.titles.elementAtOrNull(
      context.reader.chapter - 1,
    );

    return BlurEffect(
      child: Container(
        padding: EdgeInsets.only(top: context.padding.top),
        decoration: BoxDecoration(
          color: context.colorScheme.surface.toOpacity(0.92),
          border: Border(
            bottom: BorderSide(color: Colors.grey.toOpacity(0.5), width: 0.5),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: context.padding.left,
            right: context.padding.right,
          ),
          child: Row(
            children: [
              const SizedBox(width: 8),
              const BackButton(),
              const SizedBox(width: 8),
              Expanded(
                child: epName == null
                    ? Text(
                        context.reader.widget.name,
                        style: ts.s18,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            context.reader.widget.name,
                            style: ts.s16,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            epName,
                            style: ts.s12,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              if (shouldShowChapterComments())
                Tooltip(
                  message: "Chapter Comments".tl,
                  child: IconButton(
                    icon: const Icon(Icons.comment),
                    onPressed: openChapterComments,
                  ),
                ),
              if (canDownloadFromReader())
                Tooltip(
                  message: "Download".tl,
                  child: IconButton(
                    icon: const Icon(Icons.download_outlined),
                    onPressed: downloadFromReader,
                  ),
                ),
              ...buildTranslationControls(),
              Tooltip(
                message: "Settings".tl,
                child: IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: openSetting,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Cache key of the currently visible page's translated variant, or null when
  /// translation is not enabled for this comic or the page can't be resolved.
  String? _currentTranslationKey() {
    final reader = context.reader;
    if (!ImageTranslationService.enabledFor(reader.cid, reader.type.sourceKey)) {
      return null;
    }
    final images = reader.images;
    if (images == null || images.isEmpty) return null;
    var index = (reader.page - 1).clamp(0, images.length - 1);
    return ImageTranslationService.cacheKeyFor(
      images[index],
      reader.type.comicSource?.key,
      reader.cid,
      reader.eid,
    );
  }

  /// The top-bar translation affordances: a status badge (translating / failed
  /// with retry) and a toggle to peek at the original art. Empty when
  /// translation is off for this comic.
  List<Widget> buildTranslationControls() {
    final reader = context.reader;
    if (!ImageTranslationService.enabledFor(reader.cid, reader.type.sourceKey)) {
      return const [];
    }
    final service = ImageTranslationService.instance;
    final cacheKey = _currentTranslationKey();
    final widgets = <Widget>[];

    // Show-original toggle: lets the reader compare against the source art
    // without disabling translation in settings.
    widgets.add(
      Tooltip(
        message: reader.showOriginalPages
            ? "Show translated".tl
            : "Show original".tl,
        child: IconButton(
          icon: Icon(
            reader.showOriginalPages
                ? Icons.translate
                : Icons.image_outlined,
          ),
          onPressed: reader.toggleShowOriginalPages,
        ),
      ),
    );

    if (cacheKey != null && !reader.showOriginalPages) {
      switch (service.statusOf(cacheKey)) {
        case PageTranslationStatus.translating:
          widgets.add(
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        case PageTranslationStatus.failed:
          widgets.add(
            Tooltip(
              message: service.errorOf(cacheKey) ?? "Translation failed".tl,
              child: IconButton(
                icon: Icon(
                  Icons.error_outline,
                  color: context.colorScheme.error,
                ),
                onPressed: () => _retryTranslation(cacheKey),
              ),
            ),
          );
        case PageTranslationStatus.translated:
        case PageTranslationStatus.noContent:
        case PageTranslationStatus.idle:
          break;
      }
    }
    return widgets;
  }

  void _retryTranslation(String cacheKey) {
    final service = ImageTranslationService.instance;
    var error = service.errorOf(cacheKey);
    service.clearFailure(cacheKey);
    // Dropping the cached image entry makes the provider reload and re-schedule
    // the page; the failure back-off was just cleared so it runs immediately.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (mounted) setState(() {});
    if (error != null) {
      context.showMessage(message: error);
    }
  }

  bool isLiked() {
    return ImageFavoriteManager().has(
      context.reader.cid,
      context.reader.type.sourceKey,
      context.reader.eid,
      context.reader.page,
      context.reader.chapter,
    );
  }

  /// Whether the in-reader download button should show: only for online source
  /// comics (not local ones, whose images are file:// paths) that aren't already
  /// fully downloaded, and whose source can actually download (#16).
  bool canDownloadFromReader() {
    final reader = context.reader;
    if (reader.type == ComicType.local) return false;
    final source = ComicSource.find(reader.type.sourceKey);
    if (source == null || source.loadComicPages == null) return false;
    final images = reader.images;
    if (images != null && images.isNotEmpty && images[0].contains('file://')) {
      return false;
    }
    return true;
  }

  /// Queue a download from inside the reader. For a multi-chapter comic this
  /// downloads the chapter currently open; for a single-chapter comic it
  /// downloads the whole thing. Mirrors the dedup checks the detail page uses
  /// so tapping it twice is harmless (#16).
  void downloadFromReader() async {
    final reader = context.reader;
    final source = ComicSource.find(reader.type.sourceKey);
    if (source == null) return;
    final chapters = reader.widget.chapters;

    if (chapters == null) {
      // Single-chapter comic: download the whole comic if not already done.
      if (LocalManager().isDownloading(reader.cid, reader.type) ||
          LocalManager().isDownloaded(reader.cid, reader.type, 0)) {
        showToast(message: "Already downloaded".tl, context: context);
        return;
      }
      if (!await ensureDownloadStorageWritable()) return;
      LocalManager().addTask(
        ImagesDownloadTask(
          source: source,
          comicId: reader.cid,
          comicTitle: reader.widget.name,
        ),
      );
      if (!mounted) return;
      showToast(message: "Download started".tl, context: context);
      return;
    }

    // Multi-chapter: download just the chapter currently being read.
    final eid = reader.eid;
    final local = LocalManager().find(reader.cid, reader.type);
    if (local != null && local.downloadedChapters.contains(eid)) {
      showToast(message: "Already downloaded".tl, context: context);
      return;
    }
    if (LocalManager().isDownloading(reader.cid, reader.type)) {
      // A task already exists; appending a single chapter to a running task is
      // out of scope here, so point the user at the queue instead of silently
      // doing nothing.
      showToast(message: "The comic is downloading".tl, context: context);
      return;
    }
    if (!await ensureDownloadStorageWritable()) return;
    LocalManager().addTask(
      ImagesDownloadTask(
        source: source,
        comicId: reader.cid,
        comicTitle: reader.widget.name,
        chapters: [eid],
      ),
    );
    if (!mounted) return;
    showToast(message: "Download started".tl, context: context);
  }

  void addImageFavorite() async {
    // 章节评论页不是图片页：滑动收藏 / 双击收藏手势在此会被误触发，
    // 既没有可收藏的图片，按页码换算出的索引还会越过图片列表导致崩溃，直接忽略。
    if (context.reader.isOnChapterCommentsPage) {
      return;
    }
    try {
      if (context.reader.images![0].contains('file://')) {
        showToast(
          message: "Local comic collection is not supported at present".tl,
          context: context,
        );
        return;
      }
      String id = context.reader.cid;
      int ep = context.reader.chapter;
      String eid = context.reader.eid;
      String title = context.reader.history!.title;
      String subTitle = context.reader.history!.subtitle;
      int maxPage = context.reader.images!.length;
      int? page = await selectImage();
      if (page == null) return;
      page += 1;
      String sourceKey = context.reader.type.sourceKey;
      String imageKey = context.reader.images![page - 1];
      List<String> tags = context.reader.widget.tags;
      String author = context.reader.widget.author;

      var epName =
          context.reader.widget.chapters?.titles.elementAtOrNull(
            context.reader.chapter - 1,
          ) ??
          "E${context.reader.chapter}";
      var translatedTags = tags.map((e) => e.translateTagsToCN).toList();

      if (isLiked()) {
        ImageFavoriteManager().deleteImageFavorite([
          ImageFavorite(page, imageKey, null, eid, id, ep, sourceKey, epName),
        ]);
        showToast(
          message: "Uncollected the image".tl,
          context: context,
          seconds: 1,
        );
      } else {
        var imageFavoritesComic =
            ImageFavoriteManager().find(id, sourceKey) ??
            ImageFavoritesComic(
              id,
              [],
              title,
              sourceKey,
              tags,
              translatedTags,
              DateTime.now(),
              author,
              {},
              subTitle,
              maxPage,
            );
        ImageFavorite imageFavorite = ImageFavorite(
          page,
          imageKey,
          null,
          eid,
          id,
          ep,
          sourceKey,
          epName,
        );
        ImageFavoritesEp? imageFavoritesEp = imageFavoritesComic
            .imageFavoritesEp
            .firstWhereOrNull((e) {
              return e.ep == ep;
            });
        if (imageFavoritesEp == null) {
          if (page != firstPage &&
              appdata.settings['autoFavoriteCover'] == true) {
            var copy = imageFavorite.copyWith(
              page: firstPage,
              isAutoFavorite: true,
              imageKey: context.reader.images![0],
            );
            // 不是第一页且开启了自动收藏封面, 自动塞一个封面进去
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [copy, imageFavorite],
              epName,
              maxPage,
            );
          } else {
            imageFavoritesEp = ImageFavoritesEp(
              eid,
              ep,
              [imageFavorite],
              epName,
              maxPage,
            );
          }
          imageFavoritesComic.imageFavoritesEp.add(imageFavoritesEp);
        } else {
          if (imageFavoritesEp.eid != eid) {
            // 空字符串说明是从pica导入的, 那我们就手动刷一遍保证一致
            if (imageFavoritesEp.eid == "") {
              imageFavoritesEp.eid == eid;
            } else {
              // 避免多章节漫画源的章节顺序发生变化, 如果情况比较多, 做一个以eid为准更新ep的功能
              showToast(
                message:
                    "The chapter order of the comic may have changed, temporarily not supported for collection"
                        .tl,
                context: context,
              );
              return;
            }
          }
          imageFavoritesEp.imageFavorites.add(imageFavorite);
        }

        ImageFavoriteManager().addOrUpdateOrDelete(imageFavoritesComic);
        showToast(
          message: "Successfully collected".tl,
          context: context,
          seconds: 1,
        );
      }
      update();
    } catch (e, stackTrace) {
      Log.error("Image Favorite", e, stackTrace);
      showToast(message: e.toString(), context: context, seconds: 1);
    }
  }

  Widget buildBottom() {
    // Use maxPage for display (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    var text = "E${context.reader.chapter} : P$displayPage";
    if (context.reader.widget.chapters == null) {
      text = "P$displayPage";
    }

    final buttons = [
      Tooltip(
        message: "Night mode".tl,
        child: IconButton(
          icon: Icon(
            appdata.settings['readerNightMode'] == true
                ? Icons.nightlight_round
                : Icons.nightlight_outlined,
          ),
          onPressed: () {
            // Manual toggle takes over: stop following the system theme so the
            // user's explicit choice isn't immediately overridden.
            if (appdata.settings['readerNightModeFollowSystem'] == true) {
              appdata.settings['readerNightModeFollowSystem'] = false;
            }
            appdata.settings['readerNightMode'] =
                !(appdata.settings['readerNightMode'] == true);
            appdata.saveData();
            context.reader.update();
            update();
          },
        ),
      ),
      Tooltip(
        message: "Collect the image".tl,
        child: IconButton(
          icon: Icon(isLiked() ? Icons.favorite : Icons.favorite_border),
          onPressed: addImageFavorite,
        ),
      ),
      if (App.isDesktop)
        Tooltip(
          message: "${"Full Screen".tl}(F12)",
          child: IconButton(
            icon: const Icon(Icons.fullscreen),
            onPressed: () {
              context.reader.fullscreen();
            },
          ),
        ),
      if (App.isAndroid)
        Tooltip(
          message: "Screen Rotation".tl,
          child: IconButton(
            icon: () {
              if (rotation == null) {
                return const Icon(Icons.screen_rotation);
              } else if (rotation == false) {
                return const Icon(Icons.screen_lock_portrait);
              } else {
                return const Icon(Icons.screen_lock_landscape);
              }
            }.call(),
            onPressed: () {
              if (rotation == null) {
                setState(() {
                  rotation = false;
                });
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.portraitUp,
                  DeviceOrientation.portraitDown,
                ]);
              } else if (rotation == false) {
                setState(() {
                  rotation = true;
                });
                SystemChrome.setPreferredOrientations([
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]);
              } else {
                setState(() {
                  rotation = null;
                });
                SystemChrome.setPreferredOrientations(DeviceOrientation.values);
              }
            },
          ),
        ),
      Tooltip(
        message: "Auto Page Turning".tl,
        child: IconButton(
          icon: context.reader.autoPageTurningTimer != null
              ? const Icon(Icons.timer)
              : const Icon(Icons.timer_sharp),
          onPressed: () {
            context.reader.autoPageTurning(
              context.reader.cid,
              context.reader.type,
            );
            update();
          },
        ),
      ),
      if (context.reader.widget.chapters != null)
        Tooltip(
          message: "Chapters".tl,
          child: IconButton(
            icon: const Icon(Icons.library_books),
            onPressed: openChapterDrawer,
          ),
        ),
      Tooltip(
        message: "Save Image".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: saveCurrentImage,
        ),
      ),
      Tooltip(
        message: "Share".tl,
        child: IconButton(icon: const Icon(Icons.share), onPressed: share),
      ),
    ];

    Widget child = SizedBox(
      height: kBottomBarHeight,
      child: Column(
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const SizedBox(width: 8),
              IconButton.filledTonal(
                onPressed: () => !isReversed
                    ? context.reader.chapter > 1
                          ? context.reader.toPrevChapter()
                          : context.reader.toPage(1)
                    : context.reader.chapter < context.reader.maxChapter
                    ? context.reader.toNextChapter()
                    : context.reader.toPage(context.reader.maxPage),
                icon: const Icon(Icons.first_page),
              ),
              Expanded(child: buildSlider()),
              IconButton.filledTonal(
                onPressed: () => !isReversed
                    ? context.reader.chapter < context.reader.maxChapter
                          ? context.reader.toNextChapter()
                          : context.reader.toPage(context.reader.maxPage)
                    : context.reader.chapter > 1
                    ? context.reader.toPrevChapter()
                    : context.reader.toPage(1),
                icon: const Icon(Icons.last_page),
              ),
              const SizedBox(width: 8),
            ],
          ),
          LayoutBuilder(
            builder: (context, constrains) {
              final small = (constrains.maxWidth - buttons.length * 50) < 120;
              return Row(
                children: [
                  if (!small)
                    Container(
                      height: 24,
                      padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.tertiaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(child: Text(text)),
                    ).paddingLeft(16),
                  const Spacer(),
                  for (var button in buttons)
                    if (!small)
                      button.paddingHorizontal(4)
                    else ...[
                      button,
                      const Spacer(),
                    ],
                  if (!small) const SizedBox(width: 4),
                ],
              );
            },
          ),
        ],
      ),
    );

    return BlurEffect(
      child: Container(
        decoration: BoxDecoration(
          color: context.colorScheme.surface.toOpacity(0.92),
          border: isOpen
              ? Border(
                  top: BorderSide(
                    color: Colors.grey.toOpacity(0.5),
                    width: 0.5,
                  ),
                )
              : null,
        ),
        padding: EdgeInsets.only(bottom: context.padding.bottom),
        child: Padding(
          padding: EdgeInsets.only(
            left: context.padding.left,
            right: context.padding.right,
          ),
          child: child,
        ),
      ),
    );
  }

  var sliderFocus = FocusNode();

  Widget buildSlider() {
    // Clamp page to maxPage (excluding chapter comments page)
    final displayPage = context.reader.page.clamp(1, context.reader.maxPage);
    return CustomSlider(
      focusNode: sliderFocus,
      value: displayPage.toDouble(),
      min: 1,
      max: context.reader.maxPage.clamp(displayPage, 1 << 16).toDouble(),
      reversed: isReversed,
      divisions: (context.reader.maxPage - 1).clamp(2, 1 << 16),
      onChanged: (i) {
        context.reader.toPage(i.toInt());
      },
    );
  }

  Widget buildPageInfoText() {
    var epName =
        context.reader.widget.chapters?.titles.elementAtOrNull(
          context.reader.chapter - 1,
        ) ??
        "E${context.reader.chapter}";
    if (epName.length > 8) {
      epName = "${epName.substring(0, 8)}...";
    }
    var pageText = "${context.reader.page}/${context.reader.maxPage}";
    var text = context.reader.widget.chapters != null
        ? "$epName : $pageText"
        : pageText;

    return Positioned(
      bottom: 13,
      left: 25,
      child: Stack(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 14,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4
                ..color = context.colorScheme.onInverseSurface,
            ),
          ),
          Text(text),
        ],
      ),
    );
  }

  Widget buildStatusInfo() {
    if (appdata.settings['enableClockAndBatteryInfoInReader']) {
      return Positioned(
        bottom: 13,
        right: 25,
        child: Row(
          children: [
            _ClockWidget(),
            const SizedBox(width: 10),
            _BatteryWidget(),
          ],
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
  }

  void openChapterDrawer() {
    _openSideBar(
      context.reader.widget.chapters!.isGrouped
          ? _GroupedChaptersView(context.reader)
          : _ChaptersView(context.reader),
      width: 400,
    );
  }

  void saveCurrentImage() async {
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    // Save file name: ComicName_EP{chapter}_P{page}.{ext} to avoid conflict.
    // The chapter index of different group is continuous, so we use chapter number is enough.
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    saveFile(data: data, filename: filename);
  }

  void share() async {
    var result = await selectImageToData();
    if (result == null) {
      return;
    }
    var (imageIndex, data) = result;
    var fileType = detectFileType(data);
    var filename =
        "${context.reader.widget.name}_EP${context.reader.chapter}_P${imageIndex + 1}${fileType.ext}";
    Share.shareFile(data: data, filename: filename, mime: fileType.mime);
  }

  void openSetting() {
    _openSideBar(
      ReaderSettings(
        comicId: context.reader.cid,
        comicSource: context.reader.type.sourceKey,
        onChanged: (key) {
          if (key == "readerMode") {
            context.reader.mode = ReaderMode.fromKey(
              appdata.settings.getReaderSetting(
                context.reader.cid,
                context.reader.type.sourceKey,
                key,
              ),
            );
          }
          if (key == "enableTurnPageByVolumeKey") {
            if (appdata.settings.getReaderSetting(
              context.reader.cid,
              context.reader.type.sourceKey,
              key,
            )) {
              context.reader.handleVolumeEvent();
            } else {
              context.reader.stopVolumeEvent();
            }
          }
          if (key == "quickCollectImage") {
            addDragListener();
          }
          if (key == "showChapterComments" ||
              key == "showChapterCommentsAtEnd") {
            update();
          }
          context.reader.update();
        },
      ),
      width: 400,
    );
  }

  void _openSideBar(Widget widget, {double width = 400}) {
    _gestureDetectorState?.ignoreNextTap();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showSideBar(
        context,
        widget,
        width: width,
        dismissible: true,
      ).whenComplete(() {
        _gestureDetectorState?.clearIgnoreNextTap();
      });
    });
  }

  bool shouldShowChapterComments() {
    // Check if chapters exist
    if (context.reader.widget.chapters == null) return false;

    // Check if setting is enabled
    var showChapterComments = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      'showChapterComments',
    );
    if (showChapterComments != true) return false;

    // Check if comic source supports chapter comments
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null || source.chapterCommentsLoader == null) return false;

    return true;
  }

  void openChapterComments() {
    var source = ComicSource.find(context.reader.type.sourceKey);
    if (source == null) return;

    var chapters = context.reader.widget.chapters;
    if (chapters == null) return;

    var chapterIndex = context.reader.chapter - 1;
    var epId = chapters.ids.elementAt(chapterIndex);
    var chapterTitle = chapters.titles.elementAt(chapterIndex);

    showSideBar(
      context,
      ChapterCommentsPage(
        comicId: context.reader.cid,
        epId: epId,
        source: source,
        comicTitle: context.reader.widget.name,
        chapterTitle: chapterTitle,
      ),
    );
  }

  Widget buildEpChangeButton() {
    final extraWidth = context.padding.left + context.padding.right;
    if (context.reader.widget.chapters == null) return const SizedBox();
    switch (showFloatingButtonValue) {
      case 0:
        return Container(
          width: 58 + extraWidth,
          height: 58,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Icon(
            lastValue == 1
                ? Icons.arrow_forward_ios
                : Icons.arrow_back_ios_outlined,
            size: 24,
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        );
      case -1:
      case 1:
        return SizedBox(
          width: 58 + extraWidth,
          height: 58,
          child: Material(
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(16),
            elevation: 2,
            child: InkWell(
              onTap: () {
                if (showFloatingButtonValue == 1) {
                  context.reader.toNextChapter();
                } else if (showFloatingButtonValue == -1) {
                  context.reader.toPrevChapter();
                }
                setFloatingButton(0);
              },
              borderRadius: BorderRadius.circular(16),
              child: Center(
                child: Icon(
                  _getArrowIcon(isReversed, showFloatingButtonValue),
                  size: 24,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        );
    }
    return const SizedBox();
  }

  IconData _getArrowIcon(bool reversed, int value) {
    if (reversed) {
      return value == 1
          ? Icons.arrow_back_ios_outlined
          : Icons.arrow_forward_ios;
    } else {
      return value == 1
          ? Icons.arrow_forward_ios
          : Icons.arrow_back_ios_outlined;
    }
  }

  /// If there is only one image on screen, return it.
  ///
  /// If there are multiple images on screen,
  /// show an overlay to let the user select an image.
  ///
  /// The return value is the index of the selected image.
  Future<int?> selectImage() async {
    var reader = context.reader;
    var imageViewController = context.reader._imageViewController;

    bool needsSelection = false;
    int? singleImageIndex;

    if (imageViewController is _GalleryModeState) {
      var range = imageViewController.getCurrentPageImageRange();
      if (range != null) {
        var (startIndex, endIndex) = range;
        int actualImageCount = endIndex - startIndex;
        if (actualImageCount == 1) {
          needsSelection = false;
          singleImageIndex = startIndex;
        } else {
          needsSelection = true;
        }
      }
    } else if (imageViewController is _ContinuousModeState) {
      needsSelection = false;
      singleImageIndex = reader.page - 1;
    }

    if (!needsSelection && singleImageIndex != null) {
      return singleImageIndex;
    } else {
      var location = await _showSelectImageOverlay();
      if (location == null) {
        return null;
      }
      var imageKey = imageViewController!.getImageKeyByOffset(location);
      if (imageKey == null) {
        return null;
      }
      return reader.images!.indexOf(imageKey);
    }
  }

  /// Same as [selectImage], but return the image data with its index.
  /// Returns (imageIndex, imageData) or null if cancelled.
  Future<(int, Uint8List)?> selectImageToData() async {
    var i = await selectImage();
    if (i == null) {
      return null;
    }
    var imageKey = context.reader.images![i];
    Uint8List data;
    if (imageKey.startsWith("file://")) {
      data = await File(imageKey.substring(7)).readAsBytes();
    } else {
      final cache = await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      );
      if (cache == null) {
        return null;
      }
      data = await cache.readAsBytes();
    }
    return (i, data);
  }

  Future<Offset?> _showSelectImageOverlay() {
    if (_isOpen) {
      openOrClose();
    }

    var completer = Completer<Offset?>();

    var overlay = Overlay.of(context);
    OverlayEntry? entry;
    entry = OverlayEntry(
      builder: (context) {
        return Positioned.fill(
          child: _SelectImageOverlayContent(
            onTap: (offset) {
              completer.complete(offset);
              entry!.remove();
            },
            onDispose: () {
              if (!completer.isCompleted) {
                completer.complete(null);
              }
            },
          ),
        );
      },
    );
    overlay.insert(entry);

    return completer.future;
  }
}

class _BatteryWidget extends StatefulWidget {
  @override
  _BatteryWidgetState createState() => _BatteryWidgetState();
}

class _BatteryWidgetState extends State<_BatteryWidget> {
  late Battery _battery;
  late int _batteryLevel = 100;
  Timer? _timer;
  bool _hasBattery = false;
  BatteryState state = BatteryState.unknown;

  @override
  void initState() {
    super.initState();
    _battery = Battery();
    _checkBatteryAvailability();
  }

  void _checkBatteryAvailability() async {
    try {
      _batteryLevel = await _battery.batteryLevel;
      if (!mounted) return;
      state = await _battery.batteryState;
      if (!mounted) return;
      if (_batteryLevel > 0 && state != BatteryState.unknown) {
        setState(() {
          _hasBattery = true;
        });
        _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
          _battery.batteryLevel.then((level) {
            if (!mounted) return;
            if (_batteryLevel != level) {
              setState(() {
                _batteryLevel = level;
              });
            }
          });
        });
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBattery) {
      return const SizedBox.shrink(); //Empty Widget
    }
    return _batteryInfo(_batteryLevel);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Widget _batteryInfo(int batteryLevel) {
    IconData batteryIcon;
    Color batteryColor = context.colorScheme.onSurface;

    if (state == BatteryState.charging) {
      batteryIcon = Icons.battery_charging_full;
    } else if (batteryLevel >= 96) {
      batteryIcon = Icons.battery_full_sharp;
    } else if (batteryLevel >= 84) {
      batteryIcon = Icons.battery_6_bar_sharp;
    } else if (batteryLevel >= 72) {
      batteryIcon = Icons.battery_5_bar_sharp;
    } else if (batteryLevel >= 60) {
      batteryIcon = Icons.battery_4_bar_sharp;
    } else if (batteryLevel >= 48) {
      batteryIcon = Icons.battery_3_bar_sharp;
    } else if (batteryLevel >= 36) {
      batteryIcon = Icons.battery_2_bar_sharp;
    } else if (batteryLevel >= 24) {
      batteryIcon = Icons.battery_1_bar_sharp;
    } else if (batteryLevel >= 12) {
      batteryIcon = Icons.battery_0_bar_sharp;
    } else {
      batteryIcon = Icons.battery_alert_sharp;
      batteryColor = Colors.red;
    }

    return Row(
      children: [
        Icon(
          batteryIcon,
          size: 16,
          color: batteryColor,
          // Stroke
          shadows: List.generate(9, (index) {
            if (index == 4) {
              return null;
            }
            double offsetX = (index % 3 - 1) * 0.8;
            double offsetY = ((index / 3).floor() - 1) * 0.8;
            return Shadow(
              color: context.colorScheme.onInverseSurface,
              offset: Offset(offsetX, offsetY),
            );
          }).whereType<Shadow>().toList(),
        ),
        Stack(
          children: [
            Text(
              '$batteryLevel%',
              style: TextStyle(
                fontSize: 14,
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = 1.4
                  ..color = context.colorScheme.onInverseSurface,
              ),
            ),
            Text('$batteryLevel%'),
          ],
        ),
      ],
    );
  }
}

class _ClockWidget extends StatefulWidget {
  @override
  _ClockWidgetState createState() => _ClockWidgetState();
}

class _ClockWidgetState extends State<_ClockWidget> {
  late String _currentTime;
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _currentTime = _getCurrentTime();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final time = _getCurrentTime();
      if (!mounted) return;
      if (_currentTime != time) {
        setState(() {
          _currentTime = time;
        });
      }
    });
  }

  String _getCurrentTime() {
    final now = DateTime.now();
    return "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Text(
          _currentTime,
          style: TextStyle(
            fontSize: 14,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.4
              ..color = context.colorScheme.onInverseSurface,
          ),
        ),
        Text(_currentTime),
      ],
    );
  }
}

class _SelectImageOverlayContent extends StatefulWidget {
  const _SelectImageOverlayContent({
    required this.onTap,
    required this.onDispose,
  });

  final void Function(Offset) onTap;

  final void Function() onDispose;

  @override
  State<_SelectImageOverlayContent> createState() =>
      _SelectImageOverlayContentState();
}

class _SelectImageOverlayContentState
    extends State<_SelectImageOverlayContent> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        widget.onTap(details.globalPosition);
      },
      child: Container(
        color: Colors.black.withAlpha(50),
        child: Align(
          alignment: Alignment(0, -0.8),
          child: Container(
            width: 232,
            height: 42,
            decoration: BoxDecoration(
              color: context.colorScheme.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.colorScheme.outlineVariant),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                const Icon(Icons.info_outline),
                const SizedBox(width: 16),
                Text(
                  "Click to select an image".tl,
                  style: TextStyle(
                    fontSize: 16,
                    color: context.colorScheme.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

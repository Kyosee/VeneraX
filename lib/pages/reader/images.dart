part of 'reader.dart';

class _ReaderImages extends StatefulWidget {
  const _ReaderImages({super.key});

  @override
  State<_ReaderImages> createState() => _ReaderImagesState();
}

class _ReaderImagesState extends State<_ReaderImages> {
  String? error;

  bool inProgress = false;

  late _ReaderState reader;

  @override
  void initState() {
    reader = context.reader;
    reader.isLoading = true;
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    ImageDownloader.cancelAllLoadingImages();
  }

  /// Handle jumping to last page when _jumpToLastPageOnLoad is true
  void _handleJumpToLastPage() {
    if (reader._jumpToLastPageOnLoad) {
      reader._page = reader.maxPage;
      reader._jumpToLastPageOnLoad = false;
    }
  }

  void load() async {
    if (inProgress) return;
    inProgress = true;
    if (reader.type == ComicType.local ||
        (LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          reader.chapter,
          reader.widget.chapters,
        ))) {
      try {
        var images = await LocalManager().getImages(
          reader.cid,
          reader.type,
          reader.chapter,
        );
        if (!mounted) return;
        setState(() {
          reader.images = images;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.updateHistory();
          });
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          error = e.toString();
          reader.isLoading = false;
          inProgress = false;
        });
      }
    } else {
      var cp = reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1);
      var res = await reader.type.comicSource!.loadComicPages!(
        reader.widget.cid,
        cp,
      );
      if (!mounted) return;
      if (res.error) {
        setState(() {
          error = res.errorMessage;
          reader.isLoading = false;
          inProgress = false;
        });
      } else {
        setState(() {
          reader.images = res.data;
          reader.isLoading = false;
          inProgress = false;
          _handleJumpToLastPage();
          Future.microtask(() {
            reader.updateHistory();
          });
        });
      }
    }
    if (!mounted) return;
    context.readerScaffold.update();
  }

  @override
  Widget build(BuildContext context) {
    if (reader.isLoading) {
      load();
      return const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      return GestureDetector(
        onTap: () {
          context.readerScaffold.openOrClose();
        },
        child: SizedBox.expand(
          child: NetworkError(
            message: error!,
            retry: () {
              setState(() {
                reader.isLoading = true;
                error = null;
              });
            },
          ),
        ),
      );
    } else {
      if (reader.mode.isGallery) {
        var showComments =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true;
        var showCommentsAtEnd =
            appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
        return _GalleryMode(
          key: Key(
            '${reader.mode.key}_${reader.imagesPerPage}_${showComments}_$showCommentsAtEnd',
          ),
        );
      } else {
        return _ContinuousMode(key: Key(reader.mode.key));
      }
    }
  }
}

class _GalleryMode extends StatefulWidget {
  const _GalleryMode({super.key});

  @override
  State<_GalleryMode> createState() => _GalleryModeState();
}

class _GalleryModeState extends State<_GalleryMode>
    implements _ImageViewController {
  late PageController controller;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  var photoViewControllers = <int, PhotoViewController>{};

  late _ReaderState reader;

  bool get showChapterCommentsAtEnd {
    if (reader.mode != ReaderMode.galleryLeftToRight &&
        reader.mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (reader.widget.chapters == null) return false;
    var source = ComicSource.find(reader.type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              reader.cid,
              reader.type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  int get totalImagePages {
    return !reader.showSingleImageOnFirstPage()
        ? (reader.images!.length / reader.imagesPerPage).ceil()
        : 1 + ((reader.images!.length - 1) / reader.imagesPerPage).ceil();
  }

  int get totalPages => reader.totalPages;

  bool isChapterCommentsPage(int pageIndex) {
    return showChapterCommentsAtEnd && pageIndex == totalImagePages + 1;
  }

  var imageStates = <State<ComicImage>>{};

  bool isLongPressing = false;

  int fingers = 0;

  @override
  void initState() {
    reader = context.reader;
    controller = PageController(initialPage: reader.page);
    reader._imageViewController = this;
    Future.microtask(() {
      if (!mounted) {
        return;
      }
      context.readerScaffold.setFloatingButton(0);
    });
    super.initState();
  }

  @override
  void dispose() {
    keyRepeatTimer?.cancel();
    controller.dispose();
    for (final controller in photoViewControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _increaseFingers() {
    fingers++;
  }

  void _decreaseFingers() {
    if (fingers > 0) {
      fingers--;
    } else {
      fingers = 0;
    }
  }

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) {
    var imagesPerPage = reader.imagesPerPage;
    if (reader.showSingleImageOnFirstPage()) {
      if (page == 1) {
        return (0, 1);
      } else {
        int startIndex = (page - 2) * imagesPerPage + 1;
        int endIndex = math.min(
          startIndex + imagesPerPage,
          reader.images!.length,
        );
        return (startIndex, endIndex);
      }
    } else {
      int startIndex = (page - 1) * imagesPerPage;
      int endIndex = math.min(
        startIndex + imagesPerPage,
        reader.images!.length,
      );
      return (startIndex, endIndex);
    }
  }

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null || reader.images!.isEmpty) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    return (startIndex, endIndex);
  }

  void cache(int startPage) {
    // 向前"解码"预取的页数（不含仅下载）。只有解码进内存的页在滑入视口时
    // 才是现成纹理、不会临场解码掉帧；但 gallery 图为支持 pinch-zoom 保留全
    // 分辨率，解码占内存较大，故解码窗口远小于下载窗口 [preCacheCount] 并封顶
    // 到 2。向后保留 1 页（返回上一页时同样流畅）。超出解码窗口的页仍只下载，
    // 由 [_cachePage] 走 _preDownloadImage。
    final decodeAhead = preCacheCount.clamp(1, 2);
    for (int i = startPage - 1; i <= startPage + preCacheCount; i++) {
      if (i == startPage ||
          i <= 0 ||
          i > totalPages ||
          isChapterCommentsPage(i)) {
        continue;
      }
      final shouldPreCache =
          i == startPage - 1 || (i > startPage && i <= startPage + decodeAhead);
      _cachePage(i, shouldPreCache);
    }
  }

  void _cachePage(int page, bool shouldPreCache) {
    if (isChapterCommentsPage(page)) return;
    var (startIndex, endIndex) = getPageImagesRange(page);
    for (int i = startIndex; i < endIndex; i++) {
      shouldPreCache
          ? _precacheImage(i + 1, context)
          : _preDownloadImage(i + 1, context);
    }
  }

  Widget _buildChapterCommentsPage() {
    var source = ComicSource.find(reader.type.sourceKey);
    var chapters = reader.widget.chapters;
    if (source == null || chapters == null) return const SizedBox();
    var chapterIndex = reader.chapter - 1;
    return _EmbeddedChapterCommentsPage(
      comicId: reader.cid,
      epId: chapters.ids.elementAt(chapterIndex),
      source: source,
      comicTitle: reader.widget.name,
      chapterTitle: chapters.titles.elementAt(chapterIndex),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        _increaseFingers();
      },
      onPointerUp: (event) {
        _decreaseFingers();
      },
      onPointerCancel: (event) {
        _decreaseFingers();
      },
      onPointerMove: (event) {
        if (isLongPressing) {
          var controller = photoViewControllers[reader.page]!;
          Offset value = event.delta;
          if (isLongPressing) {
            controller.updateMultiple(position: controller.position + value);
          }
        }
      },
      child: PhotoViewGallery.builder(
        backgroundDecoration: BoxDecoration(color: reader.readerBackgroundColor),
        reverse: reader.mode == ReaderMode.galleryRightToLeft,
        scrollDirection: reader.mode == ReaderMode.galleryTopToBottom
            ? Axis.vertical
            : Axis.horizontal,
        itemCount: totalPages + 2,
        builder: (BuildContext context, int index) {
          if (index == 0 || index == totalPages + 1) {
            return PhotoViewGalleryPageOptions.customChild(
              child: const SizedBox(),
            );
          } else if (isChapterCommentsPage(index)) {
            return PhotoViewGalleryPageOptions.customChild(
              child: _buildChapterCommentsPage(),
            );
          } else {
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = reader.images!.sublist(
              startIndex,
              endIndex,
            );

            cache(index);

            photoViewControllers[index] ??= PhotoViewController();

            if (reader.imagesPerPage == 1 || pageImages.length == 1) {
              final fillScreen =
                  appdata.settings['galleryFillScreen'] == true;
              return PhotoViewGalleryPageOptions(
                filterQuality: FilterQuality.medium,
                controller: photoViewControllers[index],
                imageProvider: _createImageProviderFromKey(
                  pageImages[0],
                  context,
                  startIndex + 1,
                ),
                initialScale: fillScreen
                    ? PhotoViewComputedScale.covered
                    : PhotoViewComputedScale.contained,
                minScale: fillScreen
                    ? PhotoViewComputedScale.contained * 1.0
                    : null,
                maxScale: PhotoViewComputedScale.covered * 10.0,
                errorBuilder: (_, error, s, retry) {
                  return NetworkError(message: error.toString(), retry: retry);
                },
              );
            }

            final viewportSize = MediaQuery.of(context).size;
            return PhotoViewGalleryPageOptions.customChild(
              childSize: viewportSize,
              controller: photoViewControllers[index],
              minScale: PhotoViewComputedScale.contained * 1.0,
              maxScale: PhotoViewComputedScale.covered * 10.0,
              child: buildPageImages(pageImages, startIndex),
            );
          }
        },
        pageController: controller,
        loadingBuilder: (context, event) {
          return PhotoView.customChild(
            childSize: MediaQuery.of(context).size,
            initialScale: PhotoViewComputedScale.contained,
            minScale: PhotoViewComputedScale.contained * 1.0,
            maxScale: PhotoViewComputedScale.covered * 10.0,
            backgroundDecoration: BoxDecoration(
              color: reader.readerBackgroundColor,
            ),
            child: Center(
              child: SizedBox(
                width: 20.0,
                height: 20.0,
                child: CircularProgressIndicator(
                  backgroundColor: context.colorScheme.surfaceContainerHigh,
                  value: event == null || event.expectedTotalBytes == null
                      ? null
                      : event.cumulativeBytesLoaded / event.expectedTotalBytes!,
                ),
              ),
            ),
          );
        },
        onPageChanged: (i) {
          if (i == 0) {
            if (reader.isFirstChapterOfGroup ||
                !reader.toPrevChapter(toLastPage: true)) {
              controller.jumpToPage(1);
            }
          } else if (i == totalPages + 1) {
            if (reader.isLastChapterOfGroup || !reader.toNextChapter()) {
              controller.jumpToPage(totalPages);
            }
          } else {
            reader.setPage(i);
            context.readerScaffold.update();
            // Auto close toolbar when entering chapter comments page
            if (isChapterCommentsPage(i) && context.readerScaffold.isOpen) {
              context.readerScaffold.openOrClose();
            }
          }
          // Remove other pages' controllers to reset their state.
          var keys = photoViewControllers.keys.toList();
          for (var key in keys) {
            if (key != i) {
              photoViewControllers.remove(key);
            }
          }
        },
      ),
    );
  }

  Widget buildPageImages(List<String> images, int startIndex) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;

    bool reverse = reader.mode == ReaderMode.galleryRightToLeft;
    if (reverse) {
      images = images.reversed.toList();
    }

    List<Widget> imageWidgets;

    if (images.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[0],
              context,
              startIndex + 1,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.bottomCenter
                : Alignment.centerRight,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              images[1],
              context,
              startIndex + 2,
            ),
            fit: BoxFit.contain,
            alignment: axis == Axis.vertical
                ? Alignment.topCenter
                : Alignment.centerLeft,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        ),
      ];
    } else {
      imageWidgets = images.map((imageKey) {
        startIndex++;
        ImageProvider imageProvider = _createImageProviderFromKey(
          imageKey,
          context,
          startIndex,
        );
        return Expanded(
          child: ComicImage(
            image: imageProvider,
            fit: BoxFit.contain,
            onInit: (state) => imageStates.add(state),
            onDispose: (state) => imageStates.remove(state),
          ),
        );
      }).toList();
    }

    return axis == Axis.vertical
        ? Column(children: imageWidgets)
        : Row(children: imageWidgets);
  }

  @override
  Future<void> animateToPage(int page) {
    if ((page - controller.page!.round()).abs() > 1) {
      controller.jumpToPage(page > controller.page! ? page - 1 : page + 1);
    }
    return controller.animateToPage(
      page,
      duration: const Duration(milliseconds: 200),
      curve: Curves.ease,
    );
  }

  @override
  void toPage(int page) {
    controller.jumpToPage(page);
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    var controller = photoViewControllers[reader.page]!;
    controller.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || fingers != 1) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || !isLongPressing) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page]!;
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    isLongPressing = false;
  }

  Timer? keyRepeatTimer;

  @override
  void handleKeyEvent(KeyEvent event) {
    bool? forward;
    if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.galleryTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.galleryRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (event is KeyDownEvent) {
      if (keyRepeatTimer != null) {
        keyRepeatTimer!.cancel();
        keyRepeatTimer = null;
      }
      if (forward == true) {
        reader.toPage(reader.page + 1);
      } else if (forward == false) {
        reader.toPage(reader.page - 1);
      }
    }
    if (event is KeyRepeatEvent && keyRepeatTimer == null) {
      keyRepeatTimer = Timer.periodic(
        reader.enablePageAnimation(reader.cid, reader.type)
            ? const Duration(milliseconds: 200)
            : const Duration(milliseconds: 50),
        (timer) {
          if (!mounted) {
            timer.cancel();
            return;
          } else if (forward == true) {
            reader.toPage(reader.page + 1);
          } else if (forward == false) {
            reader.toPage(reader.page - 1);
          }
        },
      );
    }
    if (event is KeyUpEvent && keyRepeatTimer != null) {
      keyRepeatTimer!.cancel();
      keyRepeatTimer = null;
    }
  }

  @override
  bool handleOnTap(Offset location) {
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    ReaderImageProvider? provider;
    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        provider = imageState.widget.image as ReaderImageProvider;
      }
    }
    if (provider == null) return null;
    if (provider.imageKey.startsWith("file://")) {
      return await File(provider.imageKey.substring(7)).readAsBytes();
    } else {
      final cache = await CacheManager().findCache(
        "${provider.imageKey}@${provider.sourceKey}@${provider.cid}@${provider.eid}",
      );
      return cache?.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    var range = getCurrentPageImageRange();
    if (range == null) return null;

    var (startIndex, endIndex) = range;
    int actualImageCount = endIndex - startIndex;

    if (actualImageCount == 1) {
      return reader.images![startIndex];
    }

    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        var imageKey =
            (imageState.widget.image as ReaderImageProvider).imageKey;
        int index = reader.images!.indexOf(imageKey);
        if (index >= startIndex && index < endIndex) {
          return imageKey;
        }
      }
    }

    return reader.images![startIndex];
  }
}

const Set<PointerDeviceKind> _kTouchLikeDeviceTypes = <PointerDeviceKind>{
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
  PointerDeviceKind.unknown,
};

const double _kChangeChapterOffset = 160;

class _ContinuousMode extends StatefulWidget {
  const _ContinuousMode({super.key});

  @override
  State<_ContinuousMode> createState() => _ContinuousModeState();
}

class _ContinuousReaderEntry {
  const _ContinuousReaderEntry.image({
    required this.chapter,
    required this.page,
    required this.imageKey,
  }) : nextChapter = null,
       hasNext = false,
       isLoading = false,
       error = null;

  const _ContinuousReaderEntry.separator({
    required this.chapter,
    required this.hasNext,
    this.nextChapter,
    this.isLoading = false,
    this.error,
  }) : page = 0,
       imageKey = null;

  final int chapter;
  final int page;
  final String? imageKey;
  final int? nextChapter;
  final bool hasNext;
  final bool isLoading;
  final String? error;

  bool get isImage => imageKey != null;
  bool get isSeparator => !isImage;
}

class _ContinuousModeState extends State<_ContinuousMode>
    implements _ImageViewController {
  late _ReaderState reader;

  /// The reader's scroll controller. Owned directly now that the list is a
  /// plain [CustomScrollView] (the previous [ScrollablePositionedList] supplied
  /// one through a callback).
  final ScrollController _scrollController = ScrollController();

  ScrollController get scrollController => _scrollController;

  var photoViewController = PhotoViewController();

  var isCTRLPressed = false;
  static var _isMouseScrolling = false;
  var fingers = 0;
  bool disableScroll = false;

  int get preCacheCount => appdata.settings["preloadImageCount"];

  /// Whether the user was scrolling the page.
  /// The gesture detector has a delay to detect tap event.
  /// To handle the tap event, we need to know if the user was scrolling before the delay.
  bool delayedIsScrolling = false;

  var imageStates = <State<ComicImage>>{};

  // ----- Sliding window of loaded chapters -----
  // Only a handful of chapters are ever held in memory at once. Images,
  // in-flight loads and errors are tracked per chapter.
  final _continuousChapterImages = <int, List<String>>{};
  final _continuousChapterLoads = <int, Future<void>>{};
  final _continuousChapterErrors = <int, String>{};
  final _continuousCachedImages = <String>{};

  /// Pages already pre-downloaded in non-seamless (single-chapter) mode.
  final _cachedPages = <int>{};

  /// The chapter the reader was opened on. This, together with [_anchorPage],
  /// is the *pivot* of the center-keyed [CustomScrollView]: the pivot entry is
  /// laid out at scroll offset 0 and everything before it grows upward in a
  /// reverse sliver. Because the pivot is identified by (chapter, page) rather
  /// than by a list index, prepending an earlier chapter extends the reverse
  /// sliver without moving the pivot — so the viewport never jumps. This is the
  /// core fix for the "jump away then back" seen when a previous chapter loaded.
  late int _anchorChapter;
  late int _anchorPage;

  /// Flat, natural-order list of entries across all currently-loaded chapters,
  /// rebuilt only when the set of loaded chapters / their images change.
  List<_ContinuousReaderEntry> _entries = const [];

  /// Index into [_entries] of the pivot entry (the one carrying [_centerKey]).
  int _anchorIndex = 0;

  /// Center key handed to the [CustomScrollView]; marks the pivot sliver.
  final _centerKey = GlobalKey();

  /// Per-image GlobalKeys ("chapter:page") used to read each visible item's
  /// render box during scroll so we can resolve the current reading position
  /// without [ScrollablePositionedList]'s itemPositions listener.
  final _itemKeys = <String, GlobalKey>{};

  GlobalKey _itemKeyFor(int chapter, int page) =>
      _itemKeys.putIfAbsent('$chapter:$page', () => GlobalKey());

  void _rebuildEntries() {
    if (seamlessChapterReading) {
      _entries = _continuousEntries();
    } else {
      // Single-chapter continuous mode: just this chapter's pages. Chapter
      // changes happen via the edge-swipe gesture, which rebuilds the whole
      // widget with the new chapter — no separators or cross-chapter joining.
      final imgs = reader.images ?? const <String>[];
      _entries = [
        for (var i = 0; i < imgs.length; i++)
          _ContinuousReaderEntry.image(
            chapter: reader.chapter,
            page: i + 1,
            imageKey: imgs[i],
          ),
      ];
    }
    _anchorIndex = _indexOfEntry(_anchorChapter, _anchorPage);
  }

  void delayedSetIsScrolling(bool value) {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) {
        return;
      }
      delayedIsScrolling = value;
    });
  }

  bool prepareToPrevChapter = false;
  bool prepareToNextChapter = false;
  bool jumpToNextChapter = false;
  bool jumpToPrevChapter = false;

  bool isZoomedIn = false;
  bool isLongPressing = false;

  @override
  void initState() {
    reader = context.reader;
    reader._imageViewController = this;
    _anchorChapter = reader.chapter;
    _anchorPage = reader.page;
    if (reader.images != null) {
      _continuousChapterImages[reader.chapter] = reader.images!;
    }
    _rebuildEntries();
    _scrollController.addListener(onScroll);
    // Warm up around the anchor once the first frame is laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      try {
        precacheImage(_createImageProvider(reader.page, context), context);
      } catch (_) {
        // Best-effort warm-up; never let it break reader startup.
      }
      _onScrollPositionSettled();
    });
    super.initState();
  }

  @override
  void dispose() {
    _scrollController.removeListener(onScroll);
    _scrollController.dispose();
    photoViewController.dispose();
    super.dispose();
  }

  void _increaseFingers() {
    fingers++;
  }

  void _decreaseFingers() {
    if (fingers > 0) {
      fingers--;
    } else {
      fingers = 0;
    }
  }

  bool get seamlessChapterReading =>
      reader.mode.isContinuous &&
      reader.widget.chapters != null &&
      reader.maxChapter > 1 &&
      appdata.settings.getReaderSetting(
            reader.cid,
            reader.type.sourceKey,
            'enableContinuousChapterReading',
          ) ==
          true;

  String _chapterTitle(int chapter) {
    return reader.widget.chapters?.titles.elementAtOrNull(chapter - 1) ??
        'Chapter @ep'.tlParams({'ep': chapter});
  }

  /// Builds the flat, natural-order entry list spanning every currently
  /// loaded chapter (earliest first). There is no leading spacer: index 0 is
  /// the first real entry. The pivot/center is chosen separately via
  /// [_indexOfEntry], so the list order is purely chapters in ascending order.
  List<_ContinuousReaderEntry> _continuousEntries() {
    if (reader.images != null &&
        !identical(_continuousChapterImages[reader.chapter], reader.images)) {
      _continuousChapterImages[reader.chapter] = reader.images!;
    }
    final entries = <_ContinuousReaderEntry>[];

    // Find the lowest consecutively loaded chapter at or below the anchor.
    int lowestChapter = _anchorChapter;
    for (var ch = _anchorChapter - 1; ch >= 1; ch--) {
      if (_continuousChapterImages.containsKey(ch)) {
        lowestChapter = ch;
      } else {
        break;
      }
    }

    // A "previous chapter" separator at the very top if earlier chapters exist.
    if (lowestChapter > 1) {
      final prevChapter = lowestChapter - 1;
      entries.add(
        _ContinuousReaderEntry.separator(
          chapter: 0,
          hasNext: true,
          nextChapter: prevChapter,
          isLoading: _continuousChapterLoads.containsKey(prevChapter),
          error: _continuousChapterErrors[prevChapter],
        ),
      );
    }

    // Images from lowestChapter up through all consecutively loaded chapters.
    for (var chapter = lowestChapter; chapter <= reader.maxChapter; chapter++) {
      final images = _continuousChapterImages[chapter];
      if (images == null) {
        break;
      }
      for (var i = 0; i < images.length; i++) {
        entries.add(
          _ContinuousReaderEntry.image(
            chapter: chapter,
            page: i + 1,
            imageKey: images[i],
          ),
        );
      }
      final hasNext = chapter < reader.maxChapter;
      entries.add(
        _ContinuousReaderEntry.separator(
          chapter: chapter,
          hasNext: hasNext,
          nextChapter: hasNext ? chapter + 1 : null,
          isLoading:
              hasNext && _continuousChapterLoads.containsKey(chapter + 1),
          error: hasNext ? _continuousChapterErrors[chapter + 1] : null,
        ),
      );
      if (!hasNext || !_continuousChapterImages.containsKey(chapter + 1)) {
        break;
      }
    }
    return entries;
  }

  /// Index into [_entries] of the image entry at (chapter, page), or the
  /// nearest valid index if not found.
  int _indexOfEntry(int chapter, int page) {
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.isImage && entry.chapter == chapter && entry.page == page) {
        return i;
      }
    }
    // Fall back to the first image of the requested chapter, else 0.
    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.isImage && entry.chapter == chapter) {
        return i;
      }
    }
    return _entries.isEmpty ? 0 : 0;
  }

  Future<void> _ensureContinuousChapterLoaded(int chapter) {
    if (chapter < 1 ||
        chapter > reader.maxChapter ||
        _continuousChapterImages.containsKey(chapter)) {
      return Future.value();
    }
    final existing = _continuousChapterLoads[chapter];
    if (existing != null) {
      return existing;
    }
    // With the center-keyed CustomScrollView, an earlier chapter is prepended
    // into the reverse sliver that grows *away* from the pivot, so inserting it
    // does not move the pivot or any currently-visible content. No scroll
    // position compensation (and no "has the user scrolled yet" gate) is needed
    // — this is exactly the jump that the rewrite removes.
    final future = _loadContinuousChapterImages(chapter)
        .then((images) {
          if (!mounted) {
            return;
          }
          setState(() {
            _continuousChapterImages[chapter] = images;
            _continuousChapterErrors.remove(chapter);
            _rebuildEntries();
          });
        })
        .catchError((e, s) {
          Log.error('Continuous chapter reading', e, s);
          if (!mounted) {
            return;
          }
          setState(() {
            _continuousChapterErrors[chapter] = e.toString();
            _rebuildEntries();
          });
        })
        .whenComplete(() {
          _continuousChapterLoads.remove(chapter);
          if (mounted) {
            setState(_rebuildEntries);
          }
        });
    _continuousChapterLoads[chapter] = future;
    _rebuildEntries();
    return future;
  }

  Future<List<String>> _loadContinuousChapterImages(int chapter) async {
    if (reader.type == ComicType.local ||
        LocalManager().isDownloaded(
          reader.cid,
          reader.type,
          chapter,
          reader.widget.chapters,
        )) {
      return LocalManager().getImages(reader.cid, reader.type, chapter);
    }
    final chapterId = reader.widget.chapters?.ids.elementAtOrNull(chapter - 1);
    final res = await reader.type.comicSource!.loadComicPages!(
      reader.widget.cid,
      chapterId,
    );
    if (res.error) {
      throw res.errorMessage ?? 'Failed to load next chapter';
    }
    return res.data;
  }

  void _syncReaderLocation(_ContinuousReaderEntry entry) {
    if (!entry.isImage) {
      return;
    }
    final images = _continuousChapterImages[entry.chapter];
    if (images == null) {
      return;
    }
    // Only rebuild the scaffold when the logical location actually changes.
    // The scroll listener fires at sub-frame frequency; calling
    // readerScaffold.update() (a full setState on the toolbar/battery/clock/
    // progress) on every tick was a steady source of dropped frames.
    if (reader.chapter != entry.chapter) {
      reader.chapter = entry.chapter;
      reader.images = images;
      reader.page = entry.page;
      context.readerScaffold.update();
    } else if (entry.page != reader.page) {
      reader.setPage(entry.page);
      context.readerScaffold.update();
    }
  }

  /// Whether the geometry walk is already scheduled for the next frame, so
  /// rapid scroll ticks coalesce into one resolution per frame.
  bool _positionResolveScheduled = false;

  void onScroll() {
    // Swipe-past-edge to change chapter only applies in non-seamless mode.
    if (!seamlessChapterReading) {
      _updateSwipeChangeChapter();
    }
    if (!_positionResolveScheduled) {
      _positionResolveScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _positionResolveScheduled = false;
        if (mounted) _onScrollPositionSettled();
      });
    }
  }

  /// Resolves the current reading position from render-box geometry (replacing
  /// ScrollablePositionedList's itemPositions listener). Drives the scaffold
  /// page indicator for both modes, and chapter-window loading for seamless.
  void _onScrollPositionSettled() {
    if (!_scrollController.hasClients) return;
    final box = context.findRenderObject();
    if (box is! RenderBox) return;
    final viewportLeadingGlobal = box.localToGlobal(Offset.zero);
    final vertical = reader.mode == ReaderMode.continuousTopToBottom;

    _ContinuousReaderEntry? current;
    // Find the image entry whose box straddles the viewport's leading edge.
    for (final entry in _entries) {
      if (!entry.isImage) continue;
      final key = _itemKeys['${entry.chapter}:${entry.page}'];
      final ctx = key?.currentContext;
      if (ctx == null) continue;
      final itemBox = ctx.findRenderObject();
      if (itemBox is! RenderBox || !itemBox.attached) continue;
      final topLeft = itemBox.localToGlobal(Offset.zero);
      final start = vertical
          ? topLeft.dy - viewportLeadingGlobal.dy
          : topLeft.dx - viewportLeadingGlobal.dx;
      final extent = vertical ? itemBox.size.height : itemBox.size.width;
      // The entry crossing the leading edge: starts at/above 0 and ends below.
      if (start <= 1 && start + extent > 1) {
        current = entry;
        break;
      }
      // First entry that begins after the leading edge: use it if none yet.
      if (start > 1) {
        current ??= entry;
        break;
      }
    }
    current ??= _entries.firstWhere(
      (e) => e.isImage,
      orElse: () => _entries.isEmpty
          ? const _ContinuousReaderEntry.separator(chapter: 0, hasNext: false)
          : _entries.first,
    );
    if (!current.isImage) return;
    _syncReaderLocation(current);
    if (seamlessChapterReading) {
      _maybeLoadAroundCurrent(current);
      _cacheAround(current);
    } else {
      cacheImages(current.page);
    }
  }

  /// Loads the previous/next chapter as the current reading position
  /// approaches a chapter boundary.
  void _maybeLoadAroundCurrent(_ContinuousReaderEntry current) {
    final chapterImages = _continuousChapterImages[current.chapter];
    if (chapterImages == null) return;
    const edge = 3; // pages from the boundary that trigger a window slide
    // Near the end -> ensure next chapter.
    if (current.page >= chapterImages.length - edge &&
        current.chapter < reader.maxChapter) {
      _ensureContinuousChapterLoaded(current.chapter + 1);
    }
    // Near the start -> ensure previous chapter.
    if (current.page <= edge + 1 && current.chapter > 1) {
      _ensureContinuousChapterLoaded(current.chapter - 1);
    }
  }

  double? _futurePosition;

  void smoothTo(double offset) {
    if (HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    var currentLocation = scrollController.position.pixels;
    var old = _futurePosition;
    _futurePosition ??= currentLocation;
    double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
    final customSpeed = appdata.settings.getReaderSetting(
      context.reader.cid,
      context.reader.type.sourceKey,
      "readerScrollSpeed",
    );
    if (customSpeed is num) {
      k *= customSpeed;
    }
    _futurePosition = _futurePosition! + offset * k;
    var beforeOffset = (_futurePosition! - currentLocation).abs();
    _futurePosition = _futurePosition!.clamp(
      scrollController.position.minScrollExtent,
      scrollController.position.maxScrollExtent,
    );
    var afterOffset = (_futurePosition! - currentLocation).abs();
    if (_futurePosition == old) return;
    var target = _futurePosition!;
    var duration = const Duration(milliseconds: 160);
    if (afterOffset < beforeOffset) {
      duration = duration * (afterOffset / beforeOffset);
      if (duration < Duration(milliseconds: 10)) {
        duration = Duration(milliseconds: 10);
      }
    }
    scrollController
        .animateTo(_futurePosition!, duration: duration, curve: Curves.linear)
        .then((_) {
          var current = scrollController.position.pixels;
          if (current == target && current == _futurePosition) {
            _futurePosition = null;
          }
        });
  }

  void onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!_isMouseScrolling) {
        setState(() {
          _isMouseScrolling = true;
        });
      }
      if (isCTRLPressed) {
        return;
      }
      smoothTo(event.scrollDelta.dy);
    }
  }

  /// Pre-download around the current entry in seamless mode (entry-based,
  /// spanning chapter boundaries).
  void _cacheAround(_ContinuousReaderEntry current) {
    final idx = _indexOfEntry(current.chapter, current.page);
    for (var i = idx + 1; i <= idx + preCacheCount && i < _entries.length; i++) {
      final entry = _entries[i];
      if (!entry.isImage) continue;
      final cacheKey = '${entry.chapter}:${entry.page}:${entry.imageKey}';
      if (_continuousCachedImages.add(cacheKey)) {
        _preDownloadImageEntry(entry, context);
      }
    }
    for (var i = idx - 1; i >= idx - preCacheCount && i >= 0; i--) {
      final entry = _entries[i];
      if (!entry.isImage) continue;
      final cacheKey = '${entry.chapter}:${entry.page}:${entry.imageKey}';
      if (_continuousCachedImages.add(cacheKey)) {
        _preDownloadImageEntry(entry, context);
      }
    }
  }

  /// Pre-download around [current] page in non-seamless (single-chapter) mode.
  void cacheImages(int current) {
    for (int i = current + 1; i <= current + preCacheCount; i++) {
      if (i >= 1 && i <= reader.maxPage && _cachedPages.add(i)) {
        _preDownloadImage(i, context);
      }
    }
  }

  void _updateSwipeChangeChapter() {
    if (prepareToPrevChapter) {
      jumpToNextChapter = false;
      jumpToPrevChapter =
          scrollController.offset <
          scrollController.position.minScrollExtent - _kChangeChapterOffset;
    } else if (prepareToNextChapter) {
      jumpToNextChapter =
          scrollController.offset >
          scrollController.position.maxScrollExtent + _kChangeChapterOffset;
      jumpToPrevChapter = false;
    }
  }

  bool onScaleUpdate([double? scale]) {
    if (prepareToNextChapter || prepareToPrevChapter) {
      setState(() {
        prepareToPrevChapter = false;
        prepareToNextChapter = false;
      });
      context.readerScaffold.setFloatingButton(0);
    }
    var isZoomedIn = (scale ?? photoViewController.scale) != 1.0;
    if (isZoomedIn != this.isZoomedIn) {
      setState(() {
        this.isZoomedIn = isZoomedIn;
      });
    }
    return false;
  }

  Widget _buildChapterJoinPage(
    BuildContext context,
    _ContinuousReaderEntry entry,
  ) {
    // chapter == 0 means this is a "previous chapter" separator at the top
    final isPrevChapterSeparator = entry.chapter == 0;
    final title = !entry.hasNext
        ? 'No next chapter'.tl
        : isPrevChapterSeparator
            ? 'Previous Chapter'.tl
            : 'Next Chapter'.tl;
    final subtitle = entry.hasNext && entry.nextChapter != null
        ? _chapterTitle(entry.nextChapter!)
        : reader.widget.name;
    final status = entry.error != null
        ? 'Tap to retry'.tl
        : entry.isLoading
        ? 'Loading'.tl
        : null;
    return ColoredBox(
      color: reader.readerBackgroundColor,
      child: SizedBox(
        width: reader.size.width,
        height: reader.size.height,
        child: Center(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: entry.hasNext && entry.nextChapter != null
                ? () {
                    setState(() {
                      _continuousChapterErrors.remove(entry.nextChapter);
                      _rebuildEntries();
                    });
                    _ensureContinuousChapterLoaded(entry.nextChapter!);
                  }
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    !entry.hasNext
                        ? Icons.done_all_rounded
                        : isPrevChapterSeparator
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                    size: 42,
                    color: context.colorScheme.primary,
                  ),
                  const SizedBox(height: 12),
                  Text(title, style: ts.s18.bold, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: ts.s14.withColor(context.colorScheme.outline),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (status != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      status,
                      style: ts.s12.withColor(
                        entry.error != null
                            ? context.colorScheme.error
                            : context.colorScheme.outline,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a single image entry widget, tagged with its position key so the
  /// scroll listener can read its render box.
  Widget _buildImageEntry(_ContinuousReaderEntry entry) {
    double? width, height;
    if (reader.mode == ReaderMode.continuousLeftToRight ||
        reader.mode == ReaderMode.continuousRightToLeft) {
      height = double.infinity;
    } else {
      width = double.infinity;
    }
    final image = _createImageProviderFromKey(
      entry.imageKey!,
      context,
      entry.page,
      chapter: entry.chapter,
    );
    return KeyedSubtree(
      key: _itemKeyFor(entry.chapter, entry.page),
      child: ColoredBox(
        color: reader.readerBackgroundColor,
        child: ComicImage(
          filterQuality: FilterQuality.medium,
          image: image,
          width: width,
          height: height,
          fit: BoxFit.contain,
          onInit: (state) => imageStates.add(state),
          onDispose: (state) => imageStates.remove(state),
        ),
      ),
    );
  }

  /// Builds the widget for a flat entry (image, chapter-join separator, or a
  /// non-seamless single page).
  Widget _buildEntry(_ContinuousReaderEntry entry) {
    if (entry.isSeparator) {
      if (entry.hasNext && entry.nextChapter != null) {
        Future.microtask(
          () => _ensureContinuousChapterLoaded(entry.nextChapter!),
        );
      }
      return _buildChapterJoinPage(context, entry);
    }
    return _buildImageEntry(entry);
  }

  ScrollPhysics get _physics => isCTRLPressed || _isMouseScrolling || disableScroll
      ? const NeverScrollableScrollPhysics()
      : isZoomedIn
      ? const ClampingScrollPhysics()
      : const BouncingScrollPhysics();

  ScrollBehavior get _scrollBehavior => const MaterialScrollBehavior().copyWith(
    scrollbars: false,
    dragDevices: _kTouchLikeDeviceTypes,
  );

  Axis get _axis => reader.mode == ReaderMode.continuousTopToBottom
      ? Axis.vertical
      : Axis.horizontal;

  bool get _reverse => reader.mode == ReaderMode.continuousRightToLeft;

  /// Center-keyed scroll view used by both seamless and single-chapter modes.
  ///
  /// The pivot entry ([_anchorIndex]) carries [_centerKey]. Entries *before*
  /// the pivot live in the first sliver, which (being before center) is laid
  /// out toward the leading edge; entries from the pivot onward live in the
  /// second sliver after the center. Two payoffs:
  ///  - Opening at a restored page lands exactly on it (the pivot sits at
  ///    offset 0) regardless of the variable image heights above it.
  ///  - Prepending an earlier chapter only grows the first sliver away from the
  ///    pivot, so the content the user is looking at stays pinned — no jump.
  Widget _buildScrollView() {
    final before = _anchorIndex; // entries strictly before the pivot
    final afterCount = _entries.length - _anchorIndex; // pivot + following
    // 连续滚动模式的卡顿主因：cacheExtent 决定 SliverList 在视口外提前多远
    // 构建并解码 item。原值仅 1.5 个视口，而漫画竖图常达 1~3 屏高，往往连下一
    // 张完整图都覆盖不到 —— 该图滚入视口时才在主 isolate 即时解码大图，导致掉帧
    // (issue #32 上下滚动卡顿)。按用户的预加载页数放大提前量(默认4→4屏)，
    // 并设 2 屏下限，使后续若干长图在进入视口前已解码就绪。continuous 模式
    // enableResize=true 已降采样，单张解码成本可控，放大提前量代价主要是内存，
    // 由 imageCache 的 LRU(按可用RAM 100~500MB)约束。
    final viewExtent =
        _axis == Axis.vertical ? reader.size.height : reader.size.width;
    final cacheExtent = viewExtent * preCacheCount.clamp(2, 6).toDouble();
    return CustomScrollView(
      controller: _scrollController,
      center: _centerKey,
      scrollDirection: _axis,
      reverse: _reverse,
      physics: _physics,
      scrollBehavior: _scrollBehavior,
      anchor: 0.0,
      cacheExtent: cacheExtent,
      slivers: [
        // Leading sliver: entries before the pivot, in reverse so element 0 of
        // the builder is the entry immediately above the pivot.
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, i) => _buildEntry(_entries[before - 1 - i]),
            childCount: before,
            addAutomaticKeepAlives: false,
            addSemanticIndexes: false,
          ),
        ),
        // Trailing sliver (the center): pivot entry and everything after it.
        SliverList(
          key: _centerKey,
          delegate: SliverChildBuilderDelegate(
            (context, i) => _buildEntry(_entries[before + i]),
            childCount: afterCount,
            addAutomaticKeepAlives: false,
            addSemanticIndexes: false,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget widget = _buildScrollView();

    widget = Stack(
      children: [
        Positioned.fill(child: buildBackground(context)),
        Positioned.fill(child: widget),
      ],
    );

    widget = Listener(
      onPointerDown: (event) {
        _increaseFingers();
        if (fingers > 1 && !disableScroll) {
          setState(() {
            disableScroll = true;
          });
        }
        _futurePosition = null;
        if (_isMouseScrolling) {
          setState(() {
            _isMouseScrolling = false;
          });
        }
      },
      onPointerUp: (event) {
        _decreaseFingers();
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
        if (!seamlessChapterReading && fingers == 0) {
          if (jumpToPrevChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toPrevChapter(toLastPage: true);
          } else if (jumpToNextChapter) {
            context.readerScaffold.setFloatingButton(0);
            reader.toNextChapter();
          }
        }
      },
      onPointerCancel: (event) {
        _decreaseFingers();
        if (fingers <= 1 && disableScroll) {
          setState(() {
            disableScroll = false;
          });
        }
      },
      onPointerPanZoomUpdate: (event) {
        if (event.scale == 1.0) {
          smoothTo(0 - event.panDelta.dy);
        }
      },
      onPointerMove: (event) {
        Offset value = event.delta;
        if (photoViewController.scale == 1 || fingers != 1) {
          return;
        }
        Offset offset;
        var sp = scrollController.position;
        if (sp.pixels <= sp.minScrollExtent ||
            sp.pixels >= sp.maxScrollExtent) {
          offset = Offset(value.dx, value.dy);
        } else {
          if (reader.mode == ReaderMode.continuousTopToBottom) {
            offset = Offset(value.dx, 0);
          } else {
            offset = Offset(0, value.dy);
          }
        }
        if (isLongPressing) {
          offset += value;
        }
        photoViewController.updateMultiple(
          position: photoViewController.position + offset,
        );
      },
      onPointerSignal: onPointerSignal,
      child: widget,
    );

    widget = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification) {
          delayedSetIsScrolling(true);
        } else if (notification is ScrollEndNotification) {
          delayedSetIsScrolling(false);
        }

        var scale = photoViewController.scale ?? 1.0;

        if (!seamlessChapterReading &&
            notification is ScrollUpdateNotification &&
            (scale - 1).abs() < 0.05) {
          if (!scrollController.hasClients) return false;
          if (scrollController.position.pixels <=
                  scrollController.position.minScrollExtent &&
              !reader.isFirstChapterOfGroup) {
            if (!prepareToPrevChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(-1);
              setState(() {
                prepareToPrevChapter = true;
              });
            }
          } else if (scrollController.position.pixels >=
                  scrollController.position.maxScrollExtent &&
              !reader.isLastChapterOfGroup) {
            if (!prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              context.readerScaffold.setFloatingButton(1);
              setState(() {
                prepareToNextChapter = true;
              });
            }
          } else {
            context.readerScaffold.setFloatingButton(0);
            if (prepareToPrevChapter || prepareToNextChapter) {
              jumpToPrevChapter = false;
              jumpToNextChapter = false;
              setState(() {
                prepareToPrevChapter = false;
                prepareToNextChapter = false;
              });
            }
          }
        }

        return true;
      },
      child: widget,
    );
    var width = reader.size.width;
    var height = reader.size.height;
    if (appdata.settings['limitImageWidth'] &&
        width / height > 0.7 &&
        reader.mode == ReaderMode.continuousTopToBottom) {
      width = height * 0.7;
    }

    return PhotoView.customChild(
      backgroundDecoration: BoxDecoration(color: reader.readerBackgroundColor),
      childSize: Size(width, height),
      minScale: 1.0,
      maxScale: 2.5,
      strictScale: true,
      controller: photoViewController,
      onScaleUpdate: onScaleUpdate,
      child: SizedBox(width: width, height: height, child: widget),
    );
  }

  Widget buildBackground(BuildContext context) {
    return Column(
      children: [
        SizedBox(height: context.padding.top + 16),
        if (prepareToPrevChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: true,
          ),
        const Spacer(),
        if (prepareToNextChapter)
          _SwipeChangeChapterProgress(
            controller: scrollController,
            isPrev: false,
          ),
        SizedBox(height: 36),
      ],
    );
  }

  /// Resolves the scroll-offset delta needed to bring (chapter,page)'s leading
  /// edge to the viewport's leading edge, or null if that item isn't currently
  /// laid out. The returned value is added to the current pixels.
  double? _offsetDeltaToEntry(int chapter, int page) {
    if (!_scrollController.hasClients) return null;
    final key = _itemKeys['$chapter:$page'];
    final ctx = key?.currentContext;
    final selfBox = context.findRenderObject();
    if (ctx == null || selfBox is! RenderBox) return null;
    final itemBox = ctx.findRenderObject();
    if (itemBox is! RenderBox || !itemBox.attached) return null;
    final vertical = reader.mode == ReaderMode.continuousTopToBottom;
    final viewportLeading = selfBox.localToGlobal(Offset.zero);
    final itemLeading = itemBox.localToGlobal(Offset.zero);
    return vertical
        ? itemLeading.dy - viewportLeading.dy
        : itemLeading.dx - viewportLeading.dx;
  }

  /// Scrolls (animated or instant) so that (chapter,page) sits at the leading
  /// edge.
  ///
  /// The target may be far outside the current cacheExtent and therefore not
  /// laid out, so we can't read its render box directly. We iterate: estimate a
  /// scroll offset, jump there, let the frame lay out, then read the real delta
  /// and correct. The estimate uses the *index distance* from a currently-laid-
  /// out reference item multiplied by an average item extent — robust to the
  /// center-keyed coordinate space (negative offsets above the pivot) which a
  /// naive idx/length * maxScrollExtent mapping got wrong (it ignored the
  /// negative region, so jumps to the first/middle pages missed).
  Future<void> _goToEntry(int chapter, int page, {required bool animate}) async {
    if (!_scrollController.hasClients) return;

    // Fast path: target already laid out — one precise move.
    final delta = _offsetDeltaToEntry(chapter, page);
    if (delta != null) {
      await _applyScroll(_scrollController.position.pixels + delta,
          animate: animate);
      return;
    }

    // Iterative approach for off-screen targets.
    final targetIdx = _indexOfEntry(chapter, page);
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!_scrollController.hasClients || !mounted) return;
      final pos = _scrollController.position;

      // Find any currently laid-out image entry to use as a reference point.
      final ref = _firstLaidOutEntry();
      if (ref == null) {
        // Nothing measurable; nudge toward an edge and retry.
        await _applyScroll(
          targetIdx <= _anchorIndex ? pos.minScrollExtent : pos.maxScrollExtent,
          animate: false,
        );
        await WidgetsBinding.instance.endOfFrame;
        continue;
      }

      final refDelta = _offsetDeltaToEntry(ref.chapter, ref.page) ?? 0;
      final refIdx = _indexOfEntry(ref.chapter, ref.page);
      if (refIdx == targetIdx) {
        await _applyScroll(pos.pixels + refDelta, animate: animate);
        return;
      }
      // Estimate per-entry extent from the reference item's own size.
      final unit = _entryExtent(ref) ?? (reader.size.height);
      final estimate =
          pos.pixels + refDelta + (targetIdx - refIdx) * unit;
      await _applyScroll(estimate, animate: false);
      await WidgetsBinding.instance.endOfFrame;

      // Did the target come into layout? If so, finish precisely.
      final d = _offsetDeltaToEntry(chapter, page);
      if (d != null) {
        await _applyScroll(_scrollController.position.pixels + d,
            animate: animate);
        return;
      }
    }
  }

  /// Scroll-axis extent of a laid-out entry, or null if not laid out.
  double? _entryExtent(_ContinuousReaderEntry entry) {
    final ctx = _itemKeys['${entry.chapter}:${entry.page}']?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return reader.mode == ReaderMode.continuousTopToBottom
        ? box.size.height
        : box.size.width;
  }

  /// The first image entry that currently has an attached render box.
  _ContinuousReaderEntry? _firstLaidOutEntry() {
    for (final entry in _entries) {
      if (!entry.isImage) continue;
      final ctx = _itemKeys['${entry.chapter}:${entry.page}']?.currentContext;
      final box = ctx?.findRenderObject();
      if (box is RenderBox && box.attached) return entry;
    }
    return null;
  }

  Future<void> _applyScroll(double offset, {required bool animate}) async {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    final target = offset.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (animate) {
      await _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else {
      _scrollController.jumpTo(target);
    }
  }

  @override
  Future<void> animateToPage(int page) {
    if (seamlessChapterReading) {
      return _goToEntry(reader.chapter, page, animate: true);
    }
    if (!_scrollController.hasClients) return Future.value();
    // Non-seamless: page index maps to the (page)-th sliver child.
    return _goToEntry(reader.chapter, page, animate: true);
  }

  @override
  void handleDoubleTap(Offset location) {
    if (appdata.settings['quickCollectImage'] == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    double target;
    if (photoViewController.scale !=
        photoViewController.getInitialScale?.call()) {
      target = photoViewController.getInitialScale!.call()!;
    } else {
      target = photoViewController.getInitialScale!.call()! * 1.75;
    }
    var size = MediaQuery.of(context).size;
    photoViewController.animateScale?.call(
      target,
      Offset(size.width / 2 - location.dx, size.height / 2 - location.dy),
    );
    onScaleUpdate(target);
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!appdata.settings['enableLongPressToZoom'] || delayedIsScrolling) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (appdata.settings['longPressZoomPosition'] != 'center') {
      zoomPosition = Offset(
        size.width / 2 - location.dx,
        size.height / 2 - location.dy,
      );
    } else {
      zoomPosition = Offset(0, 0);
    }
    photoViewController.animateScale?.call(target, zoomPosition);
    onScaleUpdate(target);
    isLongPressing = true;
  }

  @override
  void handleLongPressUp(Offset location) {
    if (!appdata.settings['enableLongPressToZoom']) {
      return;
    }
    double target = photoViewController.getInitialScale!.call()!;
    photoViewController.animateScale?.call(target);
    onScaleUpdate(target);
    isLongPressing = false;
  }

  @override
  void toPage(int page) {
    _futurePosition = null;
    _goToEntry(reader.chapter, page, animate: false);
  }

  @override
  void handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.controlLeft ||
        event.logicalKey == LogicalKeyboardKey.controlRight) {
      setState(() {
        if (event is KeyDownEvent) {
          isCTRLPressed = true;
        } else if (event is KeyUpEvent) {
          isCTRLPressed = false;
        }
      });
    }
    if (event is KeyUpEvent) {
      return;
    }
    bool? forward;
    if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      forward = true;
    } else if (reader.mode == ReaderMode.continuousTopToBottom &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousLeftToRight &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      forward = false;
    } else if (reader.mode == ReaderMode.continuousRightToLeft &&
        event.logicalKey == LogicalKeyboardKey.arrowRight) {
      forward = false;
    }
    if (forward == true) {
      scrollController.animateTo(
        scrollController.offset + context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    } else if (forward == false) {
      scrollController.animateTo(
        scrollController.offset - context.height * 0.25,
        duration: const Duration(milliseconds: 200),
        curve: Curves.ease,
      );
    }
  }

  @override
  bool handleOnTap(Offset location) {
    if (delayedIsScrolling) {
      return true;
    }
    return false;
  }

  @override
  Future<Uint8List?> getImageByOffset(Offset offset) async {
    var imageKey = getImageKeyByOffset(offset);
    if (imageKey == null) return null;
    if (imageKey.startsWith("file://")) {
      return await File(imageKey.substring(7)).readAsBytes();
    } else {
      final cache = await CacheManager().findCache(
        "$imageKey@${context.reader.type.sourceKey}@${context.reader.cid}@${context.reader.eid}",
      );
      return cache?.readAsBytes();
    }
  }

  @override
  String? getImageKeyByOffset(Offset offset) {
    String? imageKey;
    for (var imageState in imageStates) {
      if ((imageState as _ComicImageState).containsPoint(offset)) {
        imageKey = (imageState.widget.image as ReaderImageProvider).imageKey;
      }
    }
    return imageKey;
  }
}

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
  int page, {
  int? chapter,
}) {
  var reader = context.reader;
  final eid = chapter == null
      ? reader.eid
      : reader.widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';
  return ReaderImageProvider(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    eid,
    page,
    enableResize: reader
        .mode
        .isContinuous, // For continuous mode, we need to resize the image to improve performance
  );
}

ImageProvider _createImageProvider(int page, BuildContext context) {
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  return _createImageProviderFromKey(imageKey, context, page);
}

/// [_precacheImage] is used to precache the image for the given page.
/// The image is cached using the flutter's [precacheImage] method.
/// The image will be downloaded and decoded into memory.
void _precacheImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  precacheImage(_createImageProvider(page, context), context);
}

/// [_preDownloadImage] is used to download the image for the given page.
/// The image is downloaded using the [CacheManager] and saved to the local storage.
void _preDownloadImage(int page, BuildContext context) {
  if (page <= 0 || page > context.reader.images!.length) {
    return;
  }
  var reader = context.reader;
  var imageKey = reader.images![page - 1];
  if (imageKey.startsWith("file://")) {
    return;
  }
  var cid = reader.cid;
  var eid = reader.eid;
  var sourceKey = reader.type.comicSource?.key;
  ImageDownloader.loadComicImage(imageKey, sourceKey, cid, eid);
}

void _preDownloadImageEntry(
  _ContinuousReaderEntry entry,
  BuildContext context,
) {
  final imageKey = entry.imageKey;
  if (imageKey == null || imageKey.startsWith("file://")) {
    return;
  }
  final reader = context.reader;
  final eid =
      reader.widget.chapters?.ids.elementAtOrNull(entry.chapter - 1) ?? '0';
  ImageDownloader.loadComicImage(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    eid,
  );
}

class _SwipeChangeChapterProgress extends StatefulWidget {
  const _SwipeChangeChapterProgress({this.controller, required this.isPrev});

  final ScrollController? controller;

  final bool isPrev;

  @override
  State<_SwipeChangeChapterProgress> createState() =>
      _SwipeChangeChapterProgressState();
}

class _SwipeChangeChapterProgressState
    extends State<_SwipeChangeChapterProgress> {
  double value = 0;

  late final isPrev = widget.isPrev;

  ScrollController? controller;

  @override
  void initState() {
    super.initState();
    if (widget.controller != null) {
      controller = widget.controller;
      controller!.addListener(onScroll);
    }
  }

  @override
  void didUpdateWidget(covariant _SwipeChangeChapterProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      controller?.removeListener(onScroll);
      controller = widget.controller;
      controller?.addListener(onScroll);
      if (value != 0) {
        setState(() {
          value = 0;
        });
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
    controller?.removeListener(onScroll);
  }

  void onScroll() {
    var position = controller!.position.pixels;
    var offset = isPrev
        ? controller!.position.minScrollExtent - position
        : position - controller!.position.maxScrollExtent;
    var newValue = offset / _kChangeChapterOffset;
    newValue = newValue.clamp(0.0, 1.0);
    if (newValue != value) {
      setState(() {
        value = newValue;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.isPrev
        ? "Swipe down for previous chapter".tl
        : "Swipe up for next chapter".tl;

    return CustomPaint(
      painter: _ProgressPainter(
        value: value,
        backgroundColor: context.colorScheme.surfaceContainerLow,
        color: context.colorScheme.surfaceContainerHighest,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isPrev ? Icons.arrow_downward : Icons.arrow_upward,
            color: context.colorScheme.onSurface,
            size: 16,
          ),
          const SizedBox(width: 4),
          Text(msg),
        ],
      ).paddingVertical(6).paddingHorizontal(16),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  final double value;

  final Color backgroundColor;

  final Color color;

  const _ProgressPainter({
    required this.value,
    required this.backgroundColor,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromLTRBR(0, 0, size.width, size.height, Radius.circular(16)),
      paint,
    );

    paint.color = color;
    canvas.drawRRect(
      RRect.fromLTRBR(
        0,
        0,
        size.width * value,
        size.height,
        Radius.circular(16),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ProgressPainter ||
        oldDelegate.value != value ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.color != color;
  }
}

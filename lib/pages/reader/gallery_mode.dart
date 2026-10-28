part of 'reader.dart';

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

  int get totalImagePages => reader.maxPage;

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
    // A chapter entered by turning past the edge opens here, not through a
    // pager settle, and still counts as a turn for the e-ink refresh.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) reader._onGallerySettled(reader.page);
    });
    _schedulePrecache(reader.page);
    super.initState();
  }

  @override
  void dispose() {
    keyRepeatTimer?.cancel();
    _precacheTimer?.cancel();
    controller.dispose();
    for (final controller in photoViewControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Timer? _precacheTimer;

  /// Defers neighbor precaching until the page has settled. [cache] used to be
  /// invoked from the page builder — i.e. exactly while the page-turn
  /// animation was running — so full-resolution decodes and texture uploads
  /// competed with the animation frames and read as dropped frames (#107).
  /// The delay also coalesces rapid flips into a single cache pass.
  void _schedulePrecache(int page) {
    _precacheTimer?.cancel();
    _precacheTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || reader.page != page || isChapterCommentsPage(page)) {
        return;
      }
      cache(page);
    });
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
    if (fingers == 0) _scheduleRegroup();
  }

  /// Get the range of images for the given page. [page] is 1-based.
  (int start, int end) getPageImagesRange(int page) =>
      reader.galleryLayout.imagesOf(page);

  /// Get the image indices for current page. Returns null if no images.
  /// Returns a single index if only one image, or a range if multiple images.
  (int, int)? getCurrentPageImageRange() {
    if (reader.images == null || reader.images!.isEmpty) {
      return null;
    }
    // 评论页没有图片，按页码算出的起始索引会越过图片列表，提前排除以免越界
    if (reader.isOnChapterCommentsPage) {
      return null;
    }
    var (startIndex, endIndex) = getPageImagesRange(reader.page);
    if (startIndex >= reader.images!.length) {
      return null;
    }
    return (startIndex, endIndex);
  }

  void cache(int startPage) {
    // 向前"解码"预取的页数（不含仅下载）。只有解码进内存的页在滑入视口时
    // 才是现成纹理、不会临场解码掉帧；但 gallery 图为支持 pinch-zoom 保留全
    // 分辨率，解码占内存较大，故解码窗口远小于下载窗口 [preCacheCount] 并封顶
    // 到 2。向后保留 1 页（返回上一页时同样流畅）。超出解码窗口的页仍只下载，
    // 由 [_cachePage] 走 _preDownloadImage。
    final decodeAhead = preCacheCount.clamp(1, 2);
    final (shownStart, shownEnd) = getPageImagesRange(startPage);
    for (var i = shownStart; i < shownEnd; i++) {
      _measureImage(i);
    }
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
      if (shouldPreCache) {
        _precacheImage(i + 1, context);
        _measureImage(i);
      } else {
        _preDownloadImage(i + 1, context);
      }
    }
  }

  // ----- Landscape images on multi-image pages -----
  // A landscape image gets a page to itself, but whether an image is
  // landscape is only known once it has decoded. Images are measured off the
  // decodes the reader does anyway (the page on screen and the precache
  // window), and the pages regroup once the pager is at rest.

  final _measuredImages = <int>{};

  bool _regroupPending = false;

  bool _regroupScheduled = false;

  /// Swaps in a fresh pager on the next build, at the page being read.
  bool _remountPager = false;

  int _pagerGeneration = 0;

  void _measureImage(int index) {
    final images = reader.images;
    if (reader.imagesPerPage <= 1 ||
        images == null ||
        index < 0 ||
        index >= images.length ||
        !_measuredImages.add(index)) {
      return;
    }
    final stream = _createImageProvider(
      index + 1,
      context,
    ).resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final landscape = info.image.width > info.image.height;
        info.dispose();
        stream.removeListener(listener);
        if (!mounted) return;
        if (landscape && reader.noteWideImage(index)) {
          _regroupPending = true;
          _scheduleRegroup();
        }
      },
      onError: (_, _) {
        stream.removeListener(listener);
        _measuredImages.remove(index);
      },
    );
    stream.addListener(listener);
  }

  void _scheduleRegroup({bool wakeFrame = true}) {
    if (!_regroupPending || _regroupScheduled) return;
    _regroupScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _regroupScheduled = false;
      _regroup();
    });
    if (wakeFrame) WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Applies a pending regroup unless something is moving or the page is
  /// zoomed; the pager settling, fingers lifting and later builds retry.
  void _regroup() {
    if (!mounted || !_regroupPending) return;
    if (fingers > 0 ||
        reader.isPageAnimating ||
        reader._rippleTurnPending ||
        !controller.hasClients ||
        controller.position.isScrollingNotifier.value ||
        isImageZoomed ||
        reader.isOnChapterCommentsPage) {
      return;
    }
    _regroupPending = false;
    final oldPage = reader.page;
    final oldImages = getPageImagesRange(oldPage);
    final newPage = reader.regroupGallery();
    if (newPage == null) return;
    // The page can keep its number with fewer images on it; the pager is
    // rebuilt whenever the page being read changed in any way.
    final remount =
        newPage != oldPage || getPageImagesRange(newPage) != oldImages;
    if (newPage != oldPage) {
      // Same images under a new number: not a turn for the e-ink refresh.
      if (reader._settledPosition == (reader.chapter, oldPage)) {
        reader._settledPosition = (reader.chapter, newPage);
      }
      reader.page = newPage;
    }
    setState(() {
      if (remount) {
        _remountPager = true;
      } else {
        photoViewControllers.removeWhere((key, _) => key != newPage);
      }
    });
    context.readerScaffold.update();
    _schedulePrecache(newPage);
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

  /// Fires once the pager stops moving, whether it got there by swipe, jump or
  /// animated turn — the point where the page on screen is final.
  bool _onPagerSettled(ScrollEndNotification notification) {
    // Scrollables inside a page (the comments list) bubble up here too.
    if (notification.depth != 0 || !controller.hasClients) return false;
    _scheduleRegroup();
    final position = controller.page;
    if (position == null) return false;
    final settled = position.round();
    // Caught mid-flight by a new drag; the real settle follows.
    if ((position - settled).abs() > 0.01) return false;
    // Placeholder pages before the first and after the last page.
    if (settled < 1 || settled > totalPages) return false;
    // The neighbour hop that precedes a long animated jump.
    final pending = reader._pendingPage;
    if (pending != null && pending != settled) return false;
    reader._onGallerySettled(settled);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_remountPager) {
      _remountPager = false;
      // The page being read changed number or images: a fresh pager there,
      // with fresh zoom controllers, instead of reusing the old index's.
      final old = controller;
      controller = PageController(initialPage: reader.page);
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      photoViewControllers.clear();
      _pagerGeneration++;
    }
    // A regroup held back by an animation or a zoom tries again after this
    // frame; whatever cleared it is what caused the rebuild.
    _scheduleRegroup(wakeFrame: false);
    final gallery = Listener(
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
          // No controller on the comments page; guard against a null deref.
          var controller = photoViewControllers[reader.page];
          if (controller != null) {
            controller.updateMultiple(
              position: controller.position + event.delta,
            );
          }
        }
      },
      child: PhotoViewGallery.builder(
        key: ValueKey(_pagerGeneration),
        backgroundDecoration: BoxDecoration(
          color: reader.readerBackgroundColor,
        ),
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
              // 评论页是普通可滚动列表，关闭 PhotoView 手势，避免被双指缩放整页放大
              disableGestures: true,
            );
          } else {
            var (startIndex, endIndex) = getPageImagesRange(index);
            List<String> pageImages = reader.images!.sublist(
              startIndex,
              endIndex,
            );

            photoViewControllers[index] ??= PhotoViewController();

            if (reader.imagesPerPage == 1 || pageImages.length == 1) {
              final fillScreen = reader.effectiveSetting('galleryFillScreen') == true;
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

            // Size-only dependency: MediaQuery.of would also subscribe to
            // viewInsets, rebuilding every live gallery page on each frame of
            // the IME animation while typing in the embedded comments (#107).
            final viewportSize = MediaQuery.sizeOf(context);
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
            childSize: MediaQuery.sizeOf(context),
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
            _schedulePrecache(i);
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
    return NotificationListener<ScrollEndNotification>(
      onNotification: _onPagerSettled,
      child: gallery,
    );
  }

  Widget buildPageImages(List<String> images, int startIndex) {
    Axis axis = (reader.mode == ReaderMode.galleryTopToBottom)
        ? Axis.vertical
        : Axis.horizontal;

    final order = galleryPageOrder(
      images,
      startIndex,
      rightToLeft: reader.mode == ReaderMode.galleryRightToLeft,
    );

    List<Widget> imageWidgets;

    if (order.length == 2) {
      imageWidgets = [
        Expanded(
          child: ComicImage(
            width: double.infinity,
            height: double.infinity,
            image: _createImageProviderFromKey(
              order[0].$1,
              context,
              order[0].$2,
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
              order[1].$1,
              context,
              order[1].$2,
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
      imageWidgets = order.map((entry) {
        final (imageKey, number) = entry;
        ImageProvider imageProvider = _createImageProviderFromKey(
          imageKey,
          context,
          number,
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
  bool turnPage(bool forward) => false; // gallery 用默认按页码翻页

  @override
  bool jumpToChapter(int chapter, {bool toLastPage = false}) => false; // gallery keyed by chapter; uses the default remount path

  @override
  void syncAutoScroll() {} // gallery always turns pages on the reader's countdown

  @override
  bool get isImageZoomed {
    // 每页各自一个 PhotoViewController，取当前页的判断缩放；评论页等无控制器视为未缩放。
    final controller = photoViewControllers[reader.page];
    final scale = controller?.scale;
    if (scale == null) return false;
    // 与本页的初始缩放（fit/铺满屏幕时为 covered，非 1.0）比较，铺满屏幕模式下
    // 静止态就大于 1 也不误判为放大。
    final initial = controller!.getInitialScale?.call() ?? 1.0;
    return scale > initial * 1.01;
  }

  @override
  void handleDoubleTap(Offset location) {
    if (reader.effectiveSetting('quickCollectImage') == 'DoubleTap') {
      context.readerScaffold.addImageFavorite();
      return;
    }
    // 评论页等非图片页没有对应的 PhotoViewController，置空保护避免空指针
    var controller = photoViewControllers[reader.page];
    controller?.onDoubleClick?.call();
  }

  @override
  void handleLongPressDown(Offset location) {
    if (!reader.effectiveSetting('enableLongPressToZoom') || fingers != 1) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page];
    if (photoViewController == null) return;
    double target = photoViewController.getInitialScale!.call()! * 1.75;
    var size = reader.size;
    Offset zoomPosition;
    if (reader.effectiveSetting('longPressZoomPosition') != 'center') {
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
    if (!reader.effectiveSetting('enableLongPressToZoom') || !isLongPressing) {
      return;
    }
    var photoViewController = photoViewControllers[reader.page];
    if (photoViewController == null) {
      isLongPressing = false;
      return;
    }
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

/// The images of a multi-image gallery page in the order they are laid out,
/// each with its 1-based number in the chapter. Right-to-left reading lays
/// them out reversed, but every image keeps its own number: translations
/// and custom image processing are addressed by it.
List<(String, int)> galleryPageOrder(
  List<String> imageKeys,
  int startIndex, {
  required bool rightToLeft,
}) {
  final order = [
    for (var i = 0; i < imageKeys.length; i++)
      (imageKeys[i], startIndex + i + 1),
  ];
  return rightToLeft ? order.reversed.toList() : order;
}

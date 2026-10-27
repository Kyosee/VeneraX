library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/custom_slider.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/auto_page_turning.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/chapter_duplicates.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/eink_screen.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_enhance_shader.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/shortcuts.dart';
import 'package:venera/foundation/wide_page_split.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/images.dart';
import 'package:venera/pages/reader/auto_scroll_activity.dart';
import 'package:venera/pages/reader/continuous_page_turn_coordinator.dart';
import 'package:venera/pages/reader/shader_image.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/clipboard_image.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/memory_info.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/volume.dart';
import 'package:window_manager/window_manager.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

part 'scaffold.dart';

part 'images.dart';

part 'gesture.dart';

part 'comic_image.dart';

part 'loading.dart';

part 'chapters.dart';

part 'chapter_comments.dart';

@visibleForTesting
SystemUiMode resolveReaderSystemUiMode(bool showSystemStatusBar) {
  return showSystemStatusBar ? SystemUiMode.edgeToEdge : SystemUiMode.immersive;
}

@visibleForTesting
Future<void> applyReaderSystemUiMode(bool showSystemStatusBar) {
  return SystemChrome.setEnabledSystemUIMode(
    resolveReaderSystemUiMode(showSystemStatusBar),
  );
}

/// Reader-only orientation lock, cycled by the bottom bar's toggle:
/// null (follow the device) -> portrait -> landscape -> null.
@visibleForTesting
bool? nextReadingOrientation(bool? current) => switch (current) {
  null => false,
  false => true,
  _ => null,
};

/// Preferred orientations for a reader orientation lock. The unlocked state
/// resolves to the empty list, not [DeviceOrientation.values]: the latter forces
/// all four orientations on, overriding both the device's own rotation lock and
/// the platform manifest (which excludes upside-down portrait on phones). The
/// empty list is what hands control back, so leaving the reader restores
/// whatever the rest of the app already had.
@visibleForTesting
List<DeviceOrientation> resolveReadingOrientations(bool? rotation) =>
    switch (rotation) {
      false => const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ],
      true => const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
      _ => const <DeviceOrientation>[],
    };

/// How the page content moves when a gallery turns [forward]; null outside
/// gallery modes.
@visibleForTesting
RippleSweep? galleryRippleSweep(ReaderMode mode, {required bool forward}) {
  final sweep = switch (mode) {
    ReaderMode.galleryLeftToRight => RippleSweep.leftward,
    ReaderMode.galleryRightToLeft => RippleSweep.rightward,
    ReaderMode.galleryTopToBottom => RippleSweep.upward,
    _ => null,
  };
  return forward ? sweep : sweep?.opposite;
}

extension _ReaderContext on BuildContext {
  _ReaderState get reader => findAncestorStateOfType<_ReaderState>()!;

  _ReaderScaffoldState get readerScaffold =>
      findAncestorStateOfType<_ReaderScaffoldState>()!;
}

class Reader extends StatefulWidget {
  const Reader({
    super.key,
    required this.type,
    required this.cid,
    required this.name,
    required this.chapters,
    required this.history,
    this.initialPage,
    this.initialChapter,
    this.initialChapterGroup,
    required this.author,
    required this.tags,
  });

  final ComicType type;

  final String author;

  final List<String> tags;

  final String cid;

  final String name;

  final ComicChapters? chapters;

  /// Starts from 1, invalid values equal to 1
  final int? initialPage;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapter;

  /// Starts from 1, invalid values equal to 1
  final int? initialChapterGroup;

  final History history;

  @override
  State<Reader> createState() => _ReaderState();
}

class _ReaderState extends State<Reader>
    with
        _ReaderLocation,
        _ReaderWindow,
        _VolumeListener,
        _ImagePerPageHandler,
        _AutoPageTurner,
        WidgetsBindingObserver,
        RouteAware {
  dynamic effectiveSetting(String key) =>
      appdata.settings.getReaderSetting(cid, type.sourceKey, key);

  @override
  void update() {
    setState(() {});
  }

  /// The maximum page number for images only (excluding chapter comments page).
  /// This is used for display purposes and history recording.
  @override
  int get maxPage {
    if (images == null) return 1;
    return !showSingleImageOnFirstPage()
        ? (images!.length / imagesPerPage).ceil()
        : 1 + ((images!.length - 1) / imagesPerPage).ceil();
  }

  /// Total pages including chapter comments page (used for internal page control).
  @override
  int get totalPages {
    var pages = maxPage;
    if (_shouldShowChapterCommentsAtEnd) pages++;
    return pages;
  }

  /// Whether the current page is the chapter comments page.
  @override
  bool get isOnChapterCommentsPage {
    return _shouldShowChapterCommentsAtEnd && _page > maxPage;
  }

  bool get _shouldShowChapterCommentsAtEnd {
    if (mode != ReaderMode.galleryLeftToRight &&
        mode != ReaderMode.galleryRightToLeft) {
      return false;
    }
    if (widget.chapters == null) return false;
    var source = ComicSource.find(type.sourceKey);
    if (source?.chapterCommentsLoader == null) return false;
    return appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterComments',
            ) ==
            true &&
        appdata.settings.getReaderSetting(
              cid,
              type.sourceKey,
              'showChapterCommentsAtEnd',
            ) ==
            true;
  }

  @override
  ComicType get type => widget.type;

  @override
  String get cid => widget.cid;

  String get eid => widget.chapters?.ids.elementAtOrNull(chapter - 1) ?? '0';

  @override
  List<String>? images;

  @override
  late ReaderMode mode;

  @override
  bool get isPortrait =>
      MediaQuery.orientationOf(context) == Orientation.portrait;

  History? history;

  @override
  bool isLoading = false;

  var focusNode = FocusNode();

  /// Lives here rather than in the gallery so the refresh interval keeps
  /// counting across chapters, which remount the gallery.
  final _einkRefresher = EinkRefresher();

  @override
  bool get _flashesNextTurn => _einkRefresher.flashesNextTurn;

  /// Last (chapter, page) a gallery came to rest on.
  (int, int)? _settledPosition;

  /// Counts a turn only when the resting position actually changed: a remount
  /// on the same page or a bounce back at a chapter edge is not a turn.
  void _onGallerySettled(int settledPage) {
    final position = (chapter, settledPage);
    final previous = _settledPosition;
    _settledPosition = position;
    if (previous != null && previous != position) {
      _einkRefresher.onPageSettled();
    }
  }

  final ReadingTimeTracker _readingTimeTracker = ReadingTimeTracker();
  Timer? _readingCheckpointTimer;
  @override
  PageRoute<dynamic>? _readingRoute;
  @override
  bool _readerRouteVisible = false;
  bool _appIsForeground = true;
  bool _readingStatisticsChanged = false;

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    _appIsForeground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    page = widget.initialPage ?? 1;
    if (page < 1) {
      page = 1;
    }
    chapter = widget.initialChapter ?? 0;
    if (chapter < 1) {
      chapter = chapterOrder.firstOrNull ?? 1;
    } else if (widget.initialChapterGroup != null) {
      for (int i = 0; i < (widget.initialChapterGroup! - 1); i++) {
        chapter += widget.chapters!.getGroupByIndex(i).length;
      }
    }
    if (widget.initialPage != null) {
      page = widget.initialPage!;
      if (page < 1) {
        page = 1;
      }
    }
    // mode = ReaderMode.fromKey(appdata.settings['readerMode']);
    mode = ReaderMode.fromKey(
      appdata.settings.getReaderSetting(cid, type.sourceKey, 'readerMode'),
    );
    history = widget.history;
    final showSystemStatusBar =
        appdata.settings.getReaderSetting(
          cid,
          type.sourceKey,
          'showSystemStatusBar',
        ) ==
        true;
    applyReaderSystemUiMode(showSystemStatusBar);
    if (appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'enableTurnPageByVolumeKey',
    )) {
      handleVolumeEvent();
    }
    setImageCacheSize();
    Future.delayed(const Duration(milliseconds: 200), () {
      LocalFavoritesManager().onRead(cid, type);
      // Opening the reader is the point the comic stops being "later" — history
      // tracks it from here on.
      if (appdata.settings['autoRemoveFromReadLater'] == true &&
          ReadLaterManager().isExist(cid, type)) {
        ReadLaterManager().remove(cid, type);
      }
    });
    ImageTranslationService.instance.addListener(_onPageTranslated);
    super.initState();
  }

  /// When on, the reader shows original (untranslated) images even though
  /// translation is enabled — a temporary, session-only toggle so the reader
  /// can check the source art without turning translation off in settings.
  bool showOriginalPages = false;

  void toggleShowOriginalPages() {
    showOriginalPages = !showOriginalPages;
    // The provider key embeds the translation flag, so switching produces new
    // providers; clear the live image cache so the toggled variant is shown
    // immediately instead of a stale cached frame.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    if (mounted) setState(() {});
  }

  /// A background page translation finished: rebuild so the affected page's
  /// provider identity changes and the translated image swaps in.
  void _onPageTranslated() {
    if (mounted) {
      setState(() {});
    }
  }

  bool _isInitialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic> && route != _readingRoute) {
      if (_readingRoute != null) {
        App.rootRouteObserver.unsubscribe(this);
      }
      _readingRoute = route;
      App.rootRouteObserver.subscribe(this, route);
      _readerRouteVisible = route.isCurrent;
      _syncReadingTimer();
      _syncAutoTurn();
    }
    if (!_isInitialized) {
      initImagesPerPage(widget.initialPage ?? 1);
      _isInitialized = true;
    } else {
      // For orientation changed
      _checkImagesPerPageChange();
    }
    initReaderWindow();
  }

  void setImageCacheSize() async {
    int maxImageCacheSize;
    var availableRAM = await MemoryInfo.getFreePhysicalMemorySize();
    if (availableRAM == null) return;
    if (availableRAM < 1 << 30) {
      maxImageCacheSize = 100 << 20;
    } else if (availableRAM < 2 << 30) {
      maxImageCacheSize = 200 << 20;
    } else if (availableRAM < 4 << 30) {
      maxImageCacheSize = 300 << 20;
    } else {
      maxImageCacheSize = 500 << 20;
    }
    Log.info(
      "Reader",
      "Detect available RAM: $availableRAM, set image cache size to $maxImageCacheSize",
    );
    PaintingBinding.instance.imageCache.maximumSizeBytes = maxImageCacheSize;
  }

  @override
  void dispose() {
    _stopReadingTimer();
    App.rootRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    if (_updateHistoryTimer != null && history != null) {
      _updateHistoryTimer!.cancel();
      _updateHistoryTimer = null;
      unawaited(HistoryManager().addHistoryAsync(history!));
    }
    _disposeAutoPageTurning();
    _einkRefresher.dispose();
    focusNode.dispose();
    ImageTranslationService.instance.removeListener(_onPageTranslated);
    ImageTranslationService.instance.clearQueue();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    stopVolumeEvent();
    Future.microtask(() {
      DataSync().onDataChanged();
    });
    PaintingBinding.instance.imageCache.maximumSizeBytes = 100 << 20;
    disposeReaderWindow();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appIsForeground = state == AppLifecycleState.resumed;
    if (_appIsForeground) {
      _syncReadingTimer();
    } else {
      _stopReadingTimer();
      _notifyReadingStatisticsChanged();
    }
    // Inactive is still on screen: an unfocused desktop window, or a phone
    // with the notification shade pulled down.
    _appVisible =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    _syncAutoTurn();
  }

  @override
  void didPush() {
    _readerRouteVisible = true;
    _syncReadingTimer();
    _syncAutoTurn();
  }

  @override
  void didPopNext() {
    _readerRouteVisible = true;
    _syncReadingTimer();
    _syncAutoTurn();
  }

  @override
  void didPushNext() {
    _readerRouteVisible = false;
    _stopReadingTimer();
    _syncAutoTurn();
  }

  @override
  void didPop() {
    _readerRouteVisible = false;
    _stopReadingTimer();
    _syncAutoTurn();
  }

  void _syncReadingTimer() {
    if (_readerRouteVisible && _appIsForeground) {
      if (_readingTimeTracker.isActive) return;
      _readingTimeTracker.start();
      _readingCheckpointTimer ??= Timer.periodic(
        const Duration(seconds: 30),
        (_) => _recordReadingSlice(_readingTimeTracker.checkpoint()),
      );
    } else {
      _stopReadingTimer();
    }
  }

  void _stopReadingTimer() {
    _readingCheckpointTimer?.cancel();
    _readingCheckpointTimer = null;
    _recordReadingSlice(_readingTimeTracker.stop());
  }

  void _recordReadingSlice(ReadingTimeSlice? slice) {
    if (slice == null || slice.duration <= Duration.zero) return;
    HistoryManager().recordReadingDuration(
      id: widget.cid,
      type: widget.type,
      title: widget.name,
      subtitle: widget.author,
      cover: widget.history.cover,
      startedAt: slice.startedAt,
      duration: slice.duration,
    );
    _readingStatisticsChanged = true;
  }

  void _notifyReadingStatisticsChanged() {
    if (!_readingStatisticsChanged) return;
    _readingStatisticsChanged = false;
    Future.microtask(() => DataSync().onDataChanged());
  }

  @override
  Widget build(BuildContext context) {
    _checkImagesPerPageChange();
    return KeyboardListener(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: onKeyEvent,
      child: Overlay(
        initialEntries: [
          OverlayEntry(
            builder: (context) {
              return _ReaderScaffold(
                child: _ReaderGestureDetector(
                  child: _ReaderImages(
                    // Seamless mode keeps a constant key so cross-chapter
                    // scrolling doesn't remount. The nonce forces a one-off
                    // remount when an explicit jump targets an unloaded chapter.
                    key: _isSeamlessContinuous
                        ? Key('seamless_$chapterJumpNonce')
                        : Key(chapter.toString()),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void onKeyEvent(KeyEvent event) {
    if (event is! KeyUpEvent) {
      final action = AppShortcuts.match(event, const {
        ShortcutScope.app,
        ShortcutScope.reader,
      });
      // App-scope actions run from the root handler; either way the key is
      // taken, so the built-in arrow keys never act on it as well.
      if (action != null) {
        if (action.scope == ShortcutScope.reader) {
          _runShortcut(action, event is KeyRepeatEvent);
        }
        return;
      }
    }
    _imageViewController?.handleKeyEvent(event);
  }

  _ReaderScaffoldState? _scaffoldState;

  DateTime _lastShortcutTurn = DateTime.fromMillisecondsSinceEpoch(0);

  void _runShortcut(ShortcutAction action, bool isRepeat) {
    final turnsPage =
        action == ShortcutAction.nextPage || action == ShortcutAction.prevPage;
    // Held keys turn pages at the arrow keys' pace; other actions fire once.
    if (isRepeat) {
      if (!turnsPage) return;
      final gap = enablePageAnimation(cid, type)
          ? const Duration(milliseconds: 200)
          : const Duration(milliseconds: 50);
      if (DateTime.now().difference(_lastShortcutTurn) < gap) return;
    }
    if (turnsPage) _lastShortcutTurn = DateTime.now();
    final scaffold = _scaffoldState;
    switch (action) {
      // Same as the volume keys: past the last page, on to the next chapter.
      // A held key stops at the chapter end instead of racing through them.
      case ShortcutAction.nextPage:
        isRepeat ? toNextPage() : onDown();
      case ShortcutAction.prevPage:
        isRepeat ? toPrevPage() : onUp();
      case ShortcutAction.nextChapter:
        toNextChapter();
      case ShortcutAction.prevChapter:
        toPrevChapter();
      case ShortcutAction.toggleReaderMenu:
        if (scaffold?.mounted == true) scaffold!.openOrClose();
      case ShortcutAction.toggleAutoPageTurning:
        if (scaffold?.mounted == true) scaffold!.toggleAutoPageTurning();
      case ShortcutAction.toggleNightMode:
        if (scaffold?.mounted == true) scaffold!.toggleNightMode();
      case ShortcutAction.collectImage:
        if (scaffold?.mounted == true) scaffold!.addImageFavorite();
      case ShortcutAction.toggleFullscreen:
      case ShortcutAction.toggleWindow:
        break;
    }
  }

  @override
  int get maxChapter => widget.chapters?.length ?? 1;

  /// Keep the reading order stable while chapter images are loaded.
  @override
  late final List<int> chapterOrder = widget.chapters == null
      ? const [1]
      : ChapterOrderPrefs.orderedIndices(
          widget.chapters!,
          cid,
          type.sourceKey,
        ).map((index) => index + 1).toList();

  /// 1-based chapters collapsed by this comic's "hide duplicate chapters"
  /// switch. Computed once: the switch lives on the details page, so it cannot
  /// change while the reader is open.
  late final Set<int> _hiddenChapters = _computeHiddenChapters();

  Set<int> _computeHiddenChapters() {
    final chapters = widget.chapters;
    if (chapters == null ||
        !ChapterDuplicatePrefs.isHidden(cid, type.sourceKey)) {
      return const {};
    }
    // duplicateTitleIndices() is flat and 0-based; chapter numbers are 1-based.
    return chapters.duplicateTitleIndices().map((i) => i + 1).toSet();
  }

  @override
  bool isChapterHidden(int c) => _hiddenChapters.contains(c);

  /// Seamless continuous reading spans every chapter inside a single
  /// [_ContinuousMode]; scrolling into the next chapter bumps [chapter] without
  /// a rebuild. Keying [_ReaderImages] by chapter would then tear down and
  /// reload that widget on the next [update] (the tap-turn loading flash,
  /// issue #117-4), so the key must stay stable in this mode.
  bool get _isSeamlessContinuous =>
      mode.isContinuous &&
      widget.chapters != null &&
      maxChapter > 1 &&
      appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'enableContinuousChapterReading',
          ) ==
          true;

  @override
  void onPageChanged() {
    updateHistory();
    // Any turn, manual or automatic, gives the new page a full interval.
    _restartAutoTurnCountdown();
  }

  /// Prevent multiple history updates in a short time.
  /// `HistoryManager().addHistoryAsync` is a high-cost operation because it creates a new isolate.
  Timer? _updateHistoryTimer;

  void updateHistory() {
    if (history != null) {
      // page >= maxPage handles both last image page and chapter comments page
      if (page >= maxPage) {
        /// Record the last image of chapter
        history!.page = images?.length ?? 1;
      } else {
        /// Record the first image of the page
        if (!showSingleImageOnFirstPage() || imagesPerPage == 1) {
          history!.page = (page - 1) * imagesPerPage + 1;
        } else {
          if (page == 1) {
            history!.page = 1;
          } else {
            history!.page = (page - 2) * imagesPerPage + 2;
          }
        }
      }
      history!.maxPage = images?.length ?? 1;
      if (widget.chapters?.isGrouped ?? false) {
        int g = 0;
        int c = chapter;
        while (c > widget.chapters!.getGroupByIndex(g).length) {
          c -= widget.chapters!.getGroupByIndex(g).length;
          g++;
        }
        history!.readEpisode.add('${g + 1}-$c');
        history!.ep = c;
        history!.group = g + 1;
      } else {
        history!.readEpisode.add(chapter.toString());
        history!.ep = chapter;
      }
      history!.time = DateTime.now();
      _updateHistoryTimer?.cancel();
      _updateHistoryTimer = Timer(const Duration(seconds: 1), () {
        HistoryManager().addHistoryAsync(history!);
        _updateHistoryTimer = null;
      });
    }
  }

  /// 0-based group holding the 1-based flat chapter [c]; always 0 when the
  /// comic isn't grouped.
  @override
  int groupIndexOfChapter(int c) {
    final chapters = widget.chapters;
    if (chapters == null || !chapters.isGrouped) return 0;
    var remaining = c;
    var g = 0;
    while (g < chapters.groups.length) {
      final size = chapters.getGroupByIndex(g).length;
      if (remaining <= size) break;
      remaining -= size;
      g++;
    }
    return g;
  }

  bool get isFirstChapterOfGroup {
    final previous = visibleChapterFrom(chapter, -1);
    return previous == null ||
        groupIndexOfChapter(previous) != groupIndexOfChapter(chapter);
  }

  bool get isLastChapterOfGroup {
    final next = visibleChapterFrom(chapter, 1);
    return next == null ||
        groupIndexOfChapter(next) != groupIndexOfChapter(chapter);
  }

  /// Get the size of the reader.
  /// The size is not always the same as the size of the screen.
  Size get size {
    var renderBox = context.findRenderObject() as RenderBox;
    return renderBox.size;
  }

  /// Reading area background color, independent of the app theme.
  /// `system` keeps following the theme surface color (default behavior).
  Color get readerBackgroundColor {
    var value = appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'readerBackgroundColor',
    );
    switch (value) {
      case 'white':
        return Colors.white;
      case 'gray':
        return const Color(0xFFBDBDBD);
      case 'black':
        return Colors.black;
      case 'sepia':
        return const Color(0xFFE8DCC0);
      case 'green':
        return const Color(0xFFC7E6C7);
      default:
        return context.colorScheme.surface;
    }
  }
}

abstract mixin class _ImagePerPageHandler {
  late int _lastImagesPerPage;

  late bool _lastOrientation;

  /// Track if we were on the chapter comments page before orientation change
  bool _wasOnCommentsPage = false;

  bool get isPortrait;

  int get page;

  set page(int value);

  ReaderMode get mode;

  String get cid;

  ComicType get type;

  /// Whether the current page is the chapter comments page
  bool get isOnChapterCommentsPage;

  /// Get the max page (excluding comments page)
  int get maxPage;

  /// Get images list for calculating maxPage
  List<String>? get images;

  void initImagesPerPage(int initialPage) {
    _lastImagesPerPage = imagesPerPage;
    _lastOrientation = isPortrait;
    _wasOnCommentsPage = false;
    if (imagesPerPage != 1) {
      if (showSingleImageOnFirstPage()) {
        page = ((initialPage - 1) / imagesPerPage).ceil() + 1;
      } else {
        page = (initialPage / imagesPerPage).ceil();
      }
    }
  }

  bool showSingleImageOnFirstPage() => appdata.settings.getReaderSetting(
    cid,
    type.sourceKey,
    'showSingleImageOnFirstPage',
  );

  /// The number of images displayed on one screen
  int get imagesPerPage {
    if (mode.isContinuous) return 1;
    if (isPortrait) {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForPortrait',
          ) ??
          1;
    } else {
      return appdata.settings.getReaderSetting(
            cid,
            type.sourceKey,
            'readerScreenPicNumberForLandscape',
          ) ??
          1;
    }
  }

  /// Calculate maxPage with a specific imagesPerPage value
  int _calcMaxPage(int imagesPerPageValue) {
    if (images == null) return 1;
    return !showSingleImageOnFirstPage()
        ? (images!.length / imagesPerPageValue).ceil()
        : 1 + ((images!.length - 1) / imagesPerPageValue).ceil();
  }

  /// Check if the number of images per page has changed
  void _checkImagesPerPageChange() {
    int currentImagesPerPage = imagesPerPage;
    bool currentOrientation = isPortrait;

    if (_lastImagesPerPage != currentImagesPerPage ||
        _lastOrientation != currentOrientation) {
      // Calculate old maxPage using old imagesPerPage to correctly determine
      // if we were on the comments page before the orientation change
      int oldMaxPage = _calcMaxPage(_lastImagesPerPage);
      _wasOnCommentsPage = page > oldMaxPage;

      _adjustPageForImagesPerPageChange(
        _lastImagesPerPage,
        currentImagesPerPage,
      );
      _lastImagesPerPage = currentImagesPerPage;
      _lastOrientation = currentOrientation;
    }
  }

  /// Adjust the page number when the number of images per page changes
  void _adjustPageForImagesPerPageChange(
    int oldImagesPerPage,
    int newImagesPerPage,
  ) {
    int previousImageIndex = 1;
    if (!showSingleImageOnFirstPage() || oldImagesPerPage == 1) {
      previousImageIndex = (page - 1) * oldImagesPerPage + 1;
    } else {
      if (page == 1) {
        previousImageIndex = 1;
      } else {
        previousImageIndex = (page - 2) * oldImagesPerPage + 2;
      }
    }

    int newPage;
    if (newImagesPerPage != 1) {
      if (showSingleImageOnFirstPage()) {
        newPage = ((previousImageIndex - 1) / newImagesPerPage).ceil() + 1;
      } else {
        newPage = (previousImageIndex / newImagesPerPage).ceil();
      }
    } else {
      newPage = previousImageIndex;
    }

    // Clamp to valid range (1 to maxPage)
    newPage = newPage.clamp(1, maxPage);

    // If we were on the comments page, stay on the comments page
    if (_wasOnCommentsPage) {
      page = maxPage + 1;
    } else {
      page = newPage;
    }
  }
}

abstract mixin class _VolumeListener {
  bool toNextPage();

  bool toPrevPage();

  bool toNextChapter();

  bool toPrevChapter({bool toLastPage = false});

  VolumeListener? volumeListener;

  void onDown() {
    if (!toNextPage()) {
      toNextChapter();
    }
  }

  void onUp() {
    if (!toPrevPage()) {
      toPrevChapter(toLastPage: true);
    }
  }

  void handleVolumeEvent() {
    if (!App.isAndroid) {
      // Currently only support Android
      return;
    }
    if (volumeListener != null) {
      volumeListener?.cancel();
    }
    volumeListener = VolumeListener(onDown: onDown, onUp: onUp)..listen();
  }

  void stopVolumeEvent() {
    if (volumeListener != null) {
      volumeListener?.cancel();
      volumeListener = null;
    }
  }
}

abstract mixin class _ReaderLocation {
  int _page = 1;
  int? _pendingPage;

  /// Flag to indicate that the page should jump to the last page after images are loaded.
  bool _jumpToLastPageOnLoad = false;

  int get page => _page;

  set page(int value) {
    _page = value;
    onPageChanged();
  }

  int chapter = 1;

  /// Bumped on explicit chapter jumps so the seamless reader (constant key) is
  /// forced to remount when the target chapter isn't in its loaded window.
  int chapterJumpNonce = 0;

  int get maxPage;

  /// Total pages including chapter comments page (for internal page control).
  int get totalPages;

  int get maxChapter;

  /// Original 1-based chapter numbers in reading order.
  List<int> get chapterOrder;

  /// Whether chapter [c] (1-based) is collapsed by "hide duplicate chapters".
  /// Hidden chapters stay addressable — history may point at one — but no
  /// navigation ever lands on them on its own.
  bool isChapterHidden(int c);

  /// 0-based group holding the 1-based flat chapter [c].
  int groupIndexOfChapter(int c);

  bool get isLoading;

  String get cid;

  ComicType get type;

  void update();

  bool enablePageAnimation(String cid, ComicType type) {
    return appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'enablePageAnimation',
    );
  }

  _ImageViewController? _imageViewController;

  void onPageChanged();

  void setPage(int page) {
    // Prevent page change during animation
    if (_animationCount > 0 && _pendingPage != null && page != _pendingPage) {
      return;
    }
    this.page = page;
  }

  bool _validatePage(int page) {
    return page >= 1 && page <= totalPages;
  }

  /// Returns true if the page is changed
  bool toNextPage() {
    // 连续模式自行在扁平 entry 序列里移动（可跨衔接页/跨章），不走按页码
    // 重建的老路径，避免翻页触发本章重载(bug#117-4)与卡在章尾(bug#117-5)。
    if (_imageViewController?.turnPage(true) == true) {
      return true;
    }
    return toPage(page + 1);
  }

  /// Returns true if the page is changed
  bool toPrevPage() {
    if (_imageViewController?.turnPage(false) == true) {
      return true;
    }
    return toPage(page - 1);
  }

  int _animationCount = 0;

  ReaderMode get mode;

  bool get mounted;

  /// Whether the next settled turn will be covered by an e-ink refresh.
  bool get _flashesNextTurn;

  /// Ripple turns are on and the panel supports them in this mode.
  bool get _rippleActive =>
      mode.isGallery &&
      appdata.settings['einkRipplePageTurn'] == true &&
      EinkPanel.rippleSupported;

  /// Sweep for a ripple turn to [page], or null for a plain turn: no real
  /// change of page, or a full refresh about to cover the turn anyway.
  RippleSweep? _rippleSweepTo(int page) {
    if (!_rippleActive || page == this.page || _flashesNextTurn) return null;
    return galleryRippleSweep(mode, forward: page > this.page);
  }

  bool _rippleTurnPending = false;

  /// Arms the ripple before anything repaints, then jumps: the panel animates
  /// the change itself, so the slide animation stays off.
  Future<void> _turnWithRipple(int page, RippleSweep sweep) async {
    _rippleTurnPending = true;
    final view = _imageViewController;
    try {
      await EinkPanel.queueRipple(sweep);
    } finally {
      _rippleTurnPending = false;
    }
    // The reader closed, or a remount replaced the gallery, while waiting.
    if (!mounted || view == null || !identical(view, _imageViewController)) {
      return;
    }
    this.page = page;
    update();
    view.toPage(page);
  }

  bool toPage(int page) {
    if (_validatePage(page)) {
      if (page == this.page && page != 1 && page != totalPages) {
        return false;
      }
      // Dropped while a ripple turn waits for its command. Reporting it as
      // handled keeps callers from switching chapter instead.
      if (_rippleTurnPending) return true;
      final sweep = _rippleSweepTo(page);
      if (sweep != null) {
        unawaited(_turnWithRipple(page, sweep));
        return true;
      }
      // The ripple stands in for the slide, also on the turns it skips.
      final hasAnimation = enablePageAnimation(cid, type) && !_rippleActive;
      if (hasAnimation) {
        _pendingPage = page;
        _animationCount++;
        update();
        _imageViewController!.animateToPage(page).then((_) {
          _animationCount--;
          if (_pendingPage == page) {
            _pendingPage = null;
          }
          update();
        });
      } else {
        this.page = page;
        update();
        _imageViewController!.toPage(page);
      }
      return true;
    }
    return false;
  }

  bool get isPageAnimating => _animationCount > 0;

  bool _validateChapter(int chapter) {
    return chapter >= 1 && chapter <= maxChapter;
  }

  /// The first chapter after [from] in [step] direction that isn't collapsed as
  /// a duplicate, or null when the run of hidden chapters reaches the end.
  /// Continuous mode uses this instead of `chapter ± 1` so its load window and
  /// separators skip hidden chapters too.
  int? visibleChapterFrom(int from, int step) => nextVisibleChapter(
    from: from,
    step: step,
    maxChapter: maxChapter,
    isHidden: isChapterHidden,
    groupOf: groupIndexOfChapter,
    order: chapterOrder,
  );

  int? _nextVisibleChapter(int step) => visibleChapterFrom(chapter, step);

  /// Returns true if the chapter is changed
  bool toNextChapter() {
    final target = _nextVisibleChapter(1);
    return target != null && toChapter(target);
  }

  /// Returns true if the chapter is changed
  /// If [toLastPage] is true, the page will be set to the last page of the previous chapter.
  bool toPrevChapter({bool toLastPage = false}) {
    final target = _nextVisibleChapter(-1);
    return target != null && toChapter(target, toLastPage: toLastPage);
  }

  bool toChapter(int c, {bool toLastPage = false}) {
    if (_validateChapter(c) && !isLoading) {
      // Seamless mode scrolls to the chapter in place when it's loaded; if it
      // handles the jump we're done. Otherwise fall through to the remount path.
      if (_imageViewController?.jumpToChapter(c, toLastPage: toLastPage) ==
          true) {
        return true;
      }
      chapter = c;
      page = 1;
      _jumpToLastPageOnLoad = toLastPage;
      chapterJumpNonce++;
      update();
      return true;
    }
    return false;
  }
}

/// Auto turning: turns a page every interval, or in continuous modes set to
/// scroll, scrolls the list at a steady speed (driven by the view). Pauses
/// while the menu is open, the reader is covered or the app is hidden.
/// Also owns keeping the screen awake, for auto turning and for the
/// `readerKeepScreenOn` setting.
abstract mixin class _AutoPageTurner {
  String get cid;

  ComicType get type;

  ReaderMode get mode;

  bool get isLoading;

  List<String>? get images;

  bool get mounted;

  BuildContext get context;

  bool get _readerRouteVisible;

  PageRoute<dynamic>? get _readingRoute;

  _ImageViewController? get _imageViewController;

  bool toNextPage();

  bool toNextChapter();

  void update();

  /// The user's switch; stays on while paused.
  bool autoPageTurning = false;

  bool _readerMenuOpen = false;

  bool _appVisible = true;

  /// Set while the reader waits for a tap of its own, e.g. picking which
  /// image of a page to save.
  bool _autoTurnHeld = false;

  Timer? _autoTurnTimer;

  /// Readers currently wanting the screen on. Shared, as the platform flag
  /// is: a reader opened over another must not switch it off for both.
  static final _screenOnHolders = <Object>{};

  static const _screenChannel = MethodChannel("venera/method_channel");

  bool get _autoTurnActive =>
      autoPageTurning && !_readerMenuOpen && _readerRouteVisible && _appVisible;

  bool get _autoTurnScrolls => autoTurnScrolls(
    mode.key,
    appdata.settings.getReaderSetting(
      cid,
      type.sourceKey,
      'autoPageTurningMode',
    ),
  );

  /// Whether the continuous view should be scrolling right now.
  bool get autoScrollRunning => _autoTurnActive && _autoTurnScrolls;

  /// A popup over the reader (context menu, drawer, dialog). Those never
  /// reach the route observer, so turning is skipped while one is up rather
  /// than paused, and carries on once it closes.
  bool get _autoTurnInterrupted =>
      _autoTurnHeld || !(_readingRoute?.isCurrent ?? true);

  void toggleAutoPageTurning() {
    autoPageTurning = !autoPageTurning;
    _syncAutoTurn(restartCountdown: true);
  }

  void stopAutoPageTurning({String? message}) {
    if (!autoPageTurning) return;
    autoPageTurning = false;
    _syncAutoTurn();
    if (message != null && mounted) {
      context.showMessage(message: message);
    }
    update();
  }

  void _onMenuToggled(bool open) {
    _readerMenuOpen = open;
    // Closing the menu gives the page a fresh interval.
    _syncAutoTurn(restartCountdown: true);
  }

  /// Brings the countdown, the view's scrolling and the screen lock in line
  /// with the current state. Called on every change that can affect them.
  void _syncAutoTurn({bool restartCountdown = false}) {
    if (!_autoTurnActive || _autoTurnScrolls) {
      _autoTurnTimer?.cancel();
      _autoTurnTimer = null;
    } else if (_autoTurnTimer == null || restartCountdown) {
      _armAutoTurn();
    }
    _imageViewController?.syncAutoScroll();
    _syncScreenOn();
  }

  /// On while the reader is visible and auto turning, or always while
  /// reading when the user asked for it.
  void _syncScreenOn() {
    _keepScreenOn(
      _readerRouteVisible &&
          (autoPageTurning ||
              appdata.settings.getReaderSetting(
                    cid,
                    type.sourceKey,
                    'readerKeepScreenOn',
                  ) ==
                  true),
    );
  }

  void _armAutoTurn() {
    _autoTurnTimer?.cancel();
    final interval = autoTurnIntervalOf(
      appdata.settings.getReaderSetting(
        cid,
        type.sourceKey,
        'autoPageTurningInterval',
      ),
    );
    _autoTurnTimer = Timer(Duration(seconds: interval), _onAutoTurnTick);
  }

  void _restartAutoTurnCountdown() {
    if (_autoTurnTimer != null) _armAutoTurn();
  }

  void _onAutoTurnTick() {
    _autoTurnTimer = null;
    if (!mounted || !_autoTurnActive || _autoTurnScrolls) return;
    // A chapter still loading re-arms once its images arrive.
    if (isLoading) return;
    if (_autoTurnInterrupted) {
      _armAutoTurn();
      return;
    }
    if (images == null) {
      stopAutoPageTurning(message: "Auto page turning stopped".tl);
      return;
    }
    if (toNextPage() || toNextChapter()) {
      _armAutoTurn();
    } else {
      stopAutoPageTurning(
        message: "Reached the end. Auto page turning stopped".tl,
      );
    }
  }

  /// A chapter opened during auto turning starts its countdown only once
  /// its pages can actually be shown.
  void _onChapterImagesLoaded() => _syncAutoTurn(restartCountdown: true);

  void _onChapterLoadFailed() {
    stopAutoPageTurning(message: "Auto page turning stopped".tl);
  }

  void _disposeAutoPageTurning() {
    _autoTurnTimer?.cancel();
    _autoTurnTimer = null;
    _keepScreenOn(false);
  }

  void _keepScreenOn(bool on) {
    if (!(App.isAndroid || App.isIOS)) return;
    final wasOn = _screenOnHolders.isNotEmpty;
    if (on) {
      _screenOnHolders.add(this);
    } else {
      _screenOnHolders.remove(this);
    }
    final isOn = _screenOnHolders.isNotEmpty;
    if (wasOn == isOn) return;
    // The two native handlers read their argument differently.
    _screenChannel
        .invokeMethod('setScreenOn', App.isAndroid ? {'set': isOn} : isOn)
        .catchError((e) {
          Log.error("Reader", "Failed to keep the screen on: $e");
        });
  }
}

mixin class _ReaderWindow {
  late WindowFrameController windowFrame;

  bool _isInit = false;

  bool _windowDisposed = false;

  /// Whether the window was already fullscreen when reading began; null until
  /// known. Leaving the reader restores that state, so fullscreen entered
  /// while reading (auto or by shortcut) ends with it, and one the user set
  /// beforehand stays.
  bool? _fullscreenBeforeReading;

  void initReaderWindow() {
    if (!App.isDesktop || _isInit) return;
    windowFrame = WindowFrame.of(App.rootContext);
    windowFrame.addCloseListener(onWindowClose);
    _isInit = true;
    _initFullscreen();
  }

  Future<void> _initFullscreen() async {
    final wasFullscreen = await windowManager.isFullScreen();
    if (_windowDisposed) return;
    _fullscreenBeforeReading = wasFullscreen;
    if (!wasFullscreen && appdata.settings['autoFullscreenOnRead'] == true) {
      WindowFullscreen.set(true);
    }
  }

  void fullscreen() => WindowFullscreen.toggle();

  bool onWindowClose() {
    if (Navigator.of(App.rootContext).canPop()) {
      Navigator.of(App.rootContext).pop();
      return false;
    } else {
      return true;
    }
  }

  void disposeReaderWindow() {
    if (!_isInit) return;
    _windowDisposed = true;
    windowFrame.removeCloseListener(onWindowClose);
    if (_fullscreenBeforeReading == false) {
      WindowFullscreen.set(false);
    }
  }
}

enum ReaderMode {
  galleryLeftToRight('galleryLeftToRight'),
  galleryRightToLeft('galleryRightToLeft'),
  galleryTopToBottom('galleryTopToBottom'),
  continuousTopToBottom('continuousTopToBottom'),
  continuousLeftToRight('continuousLeftToRight'),
  continuousRightToLeft('continuousRightToLeft');

  final String key;

  bool get isGallery => key.startsWith('gallery');

  bool get isContinuous => key.startsWith('continuous');

  const ReaderMode(this.key);

  static ReaderMode fromKey(String key) {
    for (var mode in values) {
      if (mode.key == key) {
        return mode;
      }
    }
    return galleryLeftToRight;
  }
}

abstract interface class _ImageViewController {
  void toPage(int page);

  Future<void> animateToPage(int page);

  /// Continuous mode: turn one page by moving to the adjacent image entry,
  /// crossing chapter join pages and (in seamless mode) chapter boundaries
  /// without rebuilding. The single-chapter page-number model can't reach a
  /// seamless join page or the next chapter's first page (issue #117), and
  /// rebuilding on chapter change reloads the whole chapter (the loading
  /// flash). Returns true if handled; false lets the caller fall back to the
  /// page-number model (gallery, and non-seamless continuous at a boundary).
  bool turnPage(bool forward);

  /// Explicit chapter jump (bottom-bar buttons / drawer). Seamless continuous
  /// mode has a constant key and never remounts, so it scrolls to the target
  /// itself here. Returns false to let keyed modes fall back to the remount path.
  bool jumpToChapter(int chapter, {bool toLastPage = false});

  /// Starts or stops scrolling to match [_AutoPageTurner.autoScrollRunning].
  void syncAutoScroll();

  void handleDoubleTap(Offset location);

  void handleLongPressDown(Offset location);

  void handleLongPressUp(Offset location);

  void handleKeyEvent(KeyEvent event);

  /// Returns true if the event is handled.
  bool handleOnTap(Offset location);

  /// Whether the current page's image is zoomed in (scale above the fit
  /// scale). While zoomed, a single-finger drag pans the image, so the
  /// swipe-to-favorite gesture (#143) and the iOS back swipe (#310) must
  /// stand down to avoid false triggers.
  bool get isImageZoomed;

  Future<Uint8List?> getImageByOffset(Offset offset);

  String? getImageKeyByOffset(Offset offset);
}

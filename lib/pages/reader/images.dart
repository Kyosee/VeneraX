part of 'reader.dart';

const _readerPageLoadTimeout = Duration(seconds: 30);

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
      try {
        var cp = reader.widget.chapters?.ids.elementAtOrNull(
          reader.chapter - 1,
        );
        var res = await reader
            .type
            .comicSource!
            .loadComicPages!(reader.widget.cid, cp)
            .timeout(
              _readerPageLoadTimeout,
              onTimeout: () => const Res.error("Network error"),
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
      } catch (e) {
        if (!mounted) return;
        setState(() {
          error = e.toString();
          reader.isLoading = false;
          inProgress = false;
        });
      }
    }
    if (!mounted) return;
    if (error == null) {
      reader._onChapterImagesLoaded();
    } else {
      reader._onChapterLoadFailed();
    }
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

ImageProvider _createImageProviderFromKey(
  String imageKey,
  BuildContext context,
  int page, {
  int? chapter,
}) {
  var reader = context.reader;
  final chapterNumber = chapter ?? reader.chapter;
  final eid =
      reader.widget.chapters?.ids.elementAtOrNull(chapterNumber - 1) ?? '0';
  String? translationKey;
  String? legacyTranslationKey;
  TranslationConfig? translationConfig;
  var translated = false;
  // Gate on the per-comic switch alone (which syncs over WebDAV), not on model
  // readiness: a device without translation models can still render a translated
  // page from a stored result that synced across (see renderStoredPage). When
  // models ARE present, missing pages get translated on demand as before.
  if (!reader.showOriginalPages &&
      ImageTranslationService.isEnabledForComic(
        reader.cid,
        reader.type.sourceKey,
      )) {
    translationKey = ImageTranslationService.cacheKeyFor(
      reader.type.comicSource?.key,
      reader.cid,
      eid,
      page,
    );
    legacyTranslationKey = ImageTranslationService.legacyCacheKeyFor(
      imageKey,
      reader.type.comicSource?.key,
      reader.cid,
      eid,
    );
    translationConfig = TranslationConfig.of(
      reader.cid,
      reader.type.comicSource?.key,
    );
    translated = ImageTranslationService.instance.isTranslated(
      translationKey,
      translationConfig.mode,
    );
  }
  return ReaderImageProvider(
    imageKey,
    reader.type.comicSource?.key,
    reader.cid,
    eid,
    page,
    enableResize: reader
        .mode
        .isContinuous, // For continuous mode, we need to resize the image to improve performance
    translationKey: translationKey,
    legacyTranslationKey: legacyTranslationKey,
    translationConfig: translationConfig,
    translated: translated,
    comicTitle: reader.widget.name,
    comicCover: reader.widget.history.cover,
    chapterTitle:
        reader.widget.chapters?.titles.elementAtOrNull(chapterNumber - 1) ??
        reader.widget.name,
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

Future<void> _precacheImageEntry(
  _ContinuousReaderEntry entry,
  BuildContext context,
) async {
  final imageKey = entry.imageKey;
  if (imageKey == null) return;
  await precacheImage(
    _createImageProviderFromKey(
      imageKey,
      context,
      entry.page,
      chapter: entry.chapter,
    ),
    context,
  );
}

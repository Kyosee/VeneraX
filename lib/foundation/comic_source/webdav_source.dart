import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/utils/translations.dart';

/// Builds the native (Dart, non-JS) [ComicSource] that exposes the WebDAV
/// comic library. It wires only the read-side hooks the library needs
/// (`loadComicInfo` / `loadComicPages` / image loading config); everything else
/// is null, since there is no account, search, category or explore surface.
///
/// Being a real [ComicSource] means the reader, cover loader, detail page,
/// history and favourites all treat a WebDAV comic like any other network
/// comic without a single change to those paths.
ComicSource buildWebdavComicSource() {
  final lib = WebdavLibrary.instance;
  return ComicSource(
    // Name kept generic and localizable; it only shows in a couple of places
    // that we otherwise hide this source from.
    "WebDAV Library".tl,
    WebdavLibrary.sourceKey,
    null, // account
    null, // categoryData
    null, // categoryComicsData
    null, // favoriteData
    const [], // explorePages
    null, // searchPageData
    null, // settings
    (id) => lib.loadComicInfo(id),
    null, // loadComicThumbnail
    (id, ep) => lib.loadComicPages(id, ep),
    // Supplies the Basic-auth header for the direct image GET.
    (imageKey, comicId, epId) async => lib.imageLoadingConfig(),
    // Covers/thumbnails need the same auth header.
    (imageKey) => lib.imageLoadingConfig(),
    "", // filePath — none; this is a built-in source, not a script on disk
    "", // url
    "1.0.0", // version
    null, // commentsLoader
    null, // sendCommentFunc
    null, // chapterCommentsLoader
    null, // sendChapterCommentFunc
    null, // likeOrUnlikeComic
    null, // voteCommentFunc
    null, // likeCommentFunc
    null, // idMatcher
    null, // translations
    null, // handleClickTagEvent
    null, // onTagSuggestionSelected
    null, // linkHandler
    false, // enableTagsSuggestions
    false, // enableTagsTranslate
    null, // starRatingFunc
    null, // archiveDownloader
  );
}

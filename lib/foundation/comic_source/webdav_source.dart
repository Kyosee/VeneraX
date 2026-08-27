import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/webdav_library.dart';

/// Builds the native (Dart, non-JS) [ComicSource] that exposes one configured
/// WebDAV comic library. It wires only the read-side hooks the library needs
/// (`loadComicInfo` / `loadComicPages` / image loading config); everything else
/// is null, since there is no account, search, category or explore surface.
///
/// Being a real [ComicSource] means the reader, cover loader, detail page,
/// history and favourites all treat a WebDAV comic like any other network
/// comic without a single change to those paths. One source per configured
/// address (#171) is what keeps two servers' reading state apart.
///
/// The client is resolved per call from the current configuration rather than
/// captured here: the user can edit an address or password while the source
/// stays registered, and a captured client would keep using the old
/// credentials until the next restart.
ComicSource buildWebdavComicSource(WebdavLibraryConfig config) {
  final sourceKey = config.sourceKey;
  WebdavLibraryClient client() =>
      WebdavLibraryClient.forSourceKey(sourceKey) ??
      WebdavLibraryClient(config);
  return ComicSource(
    // The library's own name, so a comic badge/history row says which server it
    // came from when several are configured.
    config.displayName,
    sourceKey,
    null, // account
    null, // categoryData
    null, // categoryComicsData
    null, // favoriteData
    const [], // explorePages
    null, // searchPageData
    null, // settings
    (id) => client().loadComicInfo(id),
    null, // loadComicThumbnail
    (id, ep) => client().loadComicPages(id, ep),
    // Supplies the Basic-auth header for the direct image GET.
    (imageKey, comicId, epId) async => client().imageLoadingConfig(),
    // Covers/thumbnails need the same auth header.
    (imageKey, comicId) async => client().imageLoadingConfig(),
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

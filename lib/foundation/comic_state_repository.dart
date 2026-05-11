import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/source_platform.dart';

class ComicIdentity {
  const ComicIdentity({
    required this.comicId,
    required this.sourceKey,
    required this.sourceComicId,
    required this.platform,
    required this.type,
  });

  factory ComicIdentity.fromSource({
    required String sourceKey,
    required String sourceComicId,
  }) {
    final platform = SourcePlatformResolver.fromSourceKey(sourceKey);
    return ComicIdentity(
      comicId: DomainDatabase.comicIdFor(platform, sourceComicId),
      sourceKey: platform.canonicalKey,
      sourceComicId: sourceComicId,
      platform: platform,
      type: platform.legacyIntType == null
          ? ComicType.fromKey(platform.canonicalKey)
          : ComicType(platform.legacyIntType!),
    );
  }

  final String comicId;
  final String sourceKey;
  final String sourceComicId;
  final SourcePlatformRef platform;
  final ComicType type;

  bool get isLocal => platform.kind == SourcePlatformKind.local;
}

class ComicState {
  const ComicState({
    required this.identity,
    this.title,
    this.subtitle,
    this.cover,
    this.description,
    this.tags,
    this.history,
    this.localComic,
    this.localFavoriteFolders = const [],
    this.isDownloaded = false,
  });

  final ComicIdentity identity;
  final String? title;
  final String? subtitle;
  final String? cover;
  final String? description;
  final List<String>? tags;
  final History? history;
  final LocalComic? localComic;
  final List<String> localFavoriteFolders;
  final bool isDownloaded;

  bool get isLocalFavorite => localFavoriteFolders.isNotEmpty;
  bool get isInLocalLibrary => localComic != null;
}

class ComicStateRepository {
  const ComicStateRepository({
    DomainDatabase? domain,
    LocalManager? localManager,
    HistoryManager? historyManager,
    LocalFavoritesManager? favoritesManager,
  }) : _domain = domain,
       _localManager = localManager,
       _historyManager = historyManager,
       _favoritesManager = favoritesManager;

  final DomainDatabase? _domain;
  final LocalManager? _localManager;
  final HistoryManager? _historyManager;
  final LocalFavoritesManager? _favoritesManager;

  DomainDatabase get _db => _domain ?? App.domain;
  LocalManager get _local => _localManager ?? LocalManager();
  HistoryManager get _history => _historyManager ?? HistoryManager();
  LocalFavoritesManager get _favorites =>
      _favoritesManager ?? LocalFavoritesManager();

  ComicIdentity identityFor(String sourceKey, String sourceComicId) {
    return ComicIdentity.fromSource(
      sourceKey: sourceKey,
      sourceComicId: sourceComicId,
    );
  }

  ComicState load(String sourceKey, String sourceComicId) {
    final identity = identityFor(sourceKey, sourceComicId);
    final history = _findHistory(sourceComicId, identity.type);
    final localComic = _findLocalComic(sourceComicId, identity.type);
    final favoriteFolders = _findFavoriteFolders(sourceComicId, identity.type);
    final favorite = _findFavoriteItem(
      favoriteFolders,
      sourceComicId,
      identity.type,
    );

    return ComicState(
      identity: identity,
      title: localComic?.title ?? favorite?.title ?? history?.title,
      subtitle: localComic?.subtitle ?? favorite?.subtitle ?? history?.subtitle,
      cover: localComic?.cover ?? favorite?.cover ?? history?.cover,
      description:
          localComic?.description ??
          favorite?.description ??
          history?.description,
      tags: localComic?.tags ?? favorite?.tags ?? history?.tags,
      history: history,
      localComic: localComic,
      localFavoriteFolders: favoriteFolders,
      isDownloaded: localComic != null,
    );
  }

  String mirrorComic(Comic comic) {
    final identity = identityFor(comic.sourceKey, comic.id);
    return _safeMirror(
      fallbackComicId: identity.comicId,
      write: () => _db.ensureComicSource(
        platform: identity.platform,
        sourceComicId: comic.id,
        title: comic.title,
        subtitle: comic.subtitle ?? '',
        description: comic.description,
        language: comic.language,
        coverUri: comic.cover,
      ),
      afterBaseWrite: (comicId) => _mirrorCommonState(identity, comicId),
    );
  }

  String mirrorComicDetails(ComicDetails comic) {
    final identity = identityFor(comic.sourceKey, comic.id);
    return _safeMirror(
      fallbackComicId: identity.comicId,
      write: () => _db.ensureComicSource(
        platform: identity.platform,
        sourceComicId: comic.id,
        title: comic.title,
        subtitle: comic.subTitle ?? '',
        description: comic.description ?? '',
        coverUri: comic.cover,
        sourceUrl: comic.url,
        sourceTitle: comic.title,
      ),
      afterBaseWrite: (comicId) => _mirrorCommonState(identity, comicId),
    );
  }

  String mirrorLocalComic(LocalComic comic) {
    final identity = identityFor(comic.sourceKey, comic.id);
    return _safeMirror(
      fallbackComicId: identity.comicId,
      write: () {
        final comicId = _db.ensureComicSource(
          platform: identity.platform,
          sourceComicId: comic.id,
          title: comic.title,
          subtitle: comic.subtitle,
          description: comic.description,
          coverUri: comic.cover,
          timestamp: comic.createdAt.millisecondsSinceEpoch,
        );
        _db.markLocalLibraryItem(
          comicId: comicId,
          directory: comic.directory,
          importRoot: comic.baseDir,
        );
        return comicId;
      },
      afterBaseWrite: (comicId) => _mirrorCommonState(identity, comicId),
    );
  }

  String _safeMirror({
    required String fallbackComicId,
    required String Function() write,
    required void Function(String comicId) afterBaseWrite,
  }) {
    try {
      final comicId = write();
      try {
        afterBaseWrite(comicId);
      } catch (error, stackTrace) {
        Log.warning(
          'Domain mirror skipped common state',
          '$error\n$stackTrace',
        );
      }
      return comicId;
    } catch (error, stackTrace) {
      Log.warning('Domain mirror failed', '$error\n$stackTrace');
      return fallbackComicId;
    }
  }

  void _mirrorCommonState(ComicIdentity identity, String comicId) {
    final history = _findHistory(identity.sourceComicId, identity.type);
    if (history != null) {
      _db.markRead(
        comicId: comicId,
        occurredAt: history.time.millisecondsSinceEpoch,
      );
    }
    for (final folder in _findFavoriteFolders(
      identity.sourceComicId,
      identity.type,
    )) {
      _db.markFavorite(comicId: comicId, folderName: folder);
    }
  }

  History? _findHistory(String sourceComicId, ComicType type) {
    if (_historyManager == null && !App.isInitialized) {
      return null;
    }
    if (!_history.isInitialized) {
      return null;
    }
    try {
      return _history.find(sourceComicId, type);
    } catch (_) {
      return null;
    }
  }

  LocalComic? _findLocalComic(String sourceComicId, ComicType type) {
    if (_localManager == null && !App.isInitialized) {
      return null;
    }
    try {
      return _local.find(sourceComicId, type);
    } catch (_) {
      return null;
    }
  }

  List<String> _findFavoriteFolders(String sourceComicId, ComicType type) {
    if (_favoritesManager == null && !App.isInitialized) {
      return const [];
    }
    try {
      return _favorites.find(sourceComicId, type);
    } catch (_) {
      return const [];
    }
  }

  FavoriteItem? _findFavoriteItem(
    List<String> folders,
    String sourceComicId,
    ComicType type,
  ) {
    if (folders.isEmpty || (_favoritesManager == null && !App.isInitialized)) {
      return null;
    }
    try {
      return _favorites.getComic(folders.first, sourceComicId, type);
    } catch (_) {
      return null;
    }
  }
}

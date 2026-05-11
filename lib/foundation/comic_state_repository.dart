import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
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

class ComicDisplayInfo {
  const ComicDisplayInfo({
    required this.title,
    required this.cover,
    required this.sourceName,
    this.author,
    this.status,
    this.updateTime,
    this.progressText,
    this.pagesText,
    this.description,
    this.tags = const [],
    this.rating,
    this.hasNewUpdate = false,
  });

  final String title;
  final String cover;
  final String? sourceName;
  final String? author;
  final String? status;
  final String? updateTime;
  final String? progressText;
  final String? pagesText;
  final String? description;
  final List<String> tags;
  final double? rating;
  final bool hasNewUpdate;
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

  ComicDisplayInfo displayInfoFor(Comic comic, {String? badge}) {
    final identity = identityFor(comic.sourceKey, comic.id);
    final domain = _findDomainBaseInfo(identity);
    final history = comic is History
        ? comic
        : _findHistory(comic.id, identity.type);
    final localComic = _findLocalComic(comic.id, identity.type);
    final favoriteFolders = _findFavoriteFolders(comic.id, identity.type);
    final favorite = comic is FavoriteItem
        ? comic
        : _findFavoriteItem(favoriteFolders, comic.id, identity.type);
    final updateInfo = comic is FavoriteItemWithUpdateInfo
        ? comic
        : _findFollowUpdateInfo(comic.id, identity.type);

    final currentMeta = _ComicMetadata.fromComic(comic);
    final favoriteMeta = favorite == null
        ? null
        : _ComicMetadata.fromFavorite(favorite);
    final localMeta = localComic == null
        ? null
        : _ComicMetadata.fromLocalComic(localComic);
    final domainTags = domain?.tags ?? const <String>[];
    final tags = _mergeTags([
      domainTags,
      updateInfo?.tags ?? const <String>[],
      favorite?.tags ?? const <String>[],
      localComic?.tags ?? const <String>[],
      comic.tags ?? const <String>[],
    ]);

    final status = _pick([
      domain?.status,
      _ComicMetadata.statusFromTags(updateInfo?.tags),
      favoriteMeta?.status,
      localMeta?.status,
      currentMeta.status,
    ]);
    final updateTime = _pick([
      updateInfo?.updateTime,
      domain?.updateTime,
      currentMeta.updateTime,
      favoriteMeta?.updateTime,
      localMeta?.updateTime,
    ]);
    final pages = _pick([
      comic.maxPage?.toString(),
      domain?.pageCount?.toString(),
      currentMeta.pageCount?.toString(),
    ]);

    return ComicDisplayInfo(
      title:
          _pick([
            domain?.title,
            localComic?.title,
            updateInfo?.title,
            favorite?.title,
            history?.title,
            comic.title,
          ]) ??
          comic.title,
      cover:
          _pick([
            domain?.coverUri,
            localComic?.cover,
            updateInfo?.cover,
            favorite?.cover,
            history?.cover,
            comic.cover,
          ]) ??
          comic.cover,
      sourceName: badge ?? _sourceNameFor(comic.sourceKey),
      author: _pick([
        domain?.author,
        localMeta?.author,
        favoriteMeta?.author,
        currentMeta.author,
        history?.subtitle,
      ]),
      status: status,
      updateTime: updateTime,
      progressText: history?.description,
      pagesText: pages,
      description: _pick([
        domain?.description,
        localComic?.description,
        updateInfo?.description,
        favorite?.description,
        comic.description,
      ]),
      tags: tags,
      rating: comic.stars,
      hasNewUpdate: updateInfo?.hasNewUpdate ?? false,
    );
  }

  List<DomainComicSourceLink> relatedSourcesFor(Comic comic) {
    final identity = identityFor(comic.sourceKey, comic.id);
    return _db.getRelatedSources(identity.comicId);
  }

  void linkRelatedSource({
    required Comic comic,
    required String targetSourceKey,
    required String targetComicId,
  }) {
    mirrorComic(comic);
    final identity = identityFor(comic.sourceKey, comic.id);
    final targetPlatform = SourcePlatformResolver.fromSourceKey(
      targetSourceKey,
    );
    _db.linkSourceComics(
      sourcePlatform: identity.platform,
      sourceComicId: identity.sourceComicId,
      targetPlatform: targetPlatform,
      targetSourceComicId: targetComicId,
    );
  }

  void acceptRelatedSource(DomainComicSourceLink link) {
    _db.acceptWorkSource(workId: link.workId, comicId: link.comicId);
  }

  void rejectRelatedSource(DomainComicSourceLink link) {
    _db.rejectWorkSource(workId: link.workId, comicId: link.comicId);
  }

  void unlinkRelatedSource(DomainComicSourceLink link) {
    _db.unlinkWorkSource(workId: link.workId, comicId: link.comicId);
  }

  String mirrorComic(Comic comic) {
    final identity = identityFor(comic.sourceKey, comic.id);
    final metadata = _ComicMetadata.fromComic(comic);
    return _safeMirror(
      fallbackComicId: identity.comicId,
      write: () => _db.ensureComicSource(
        platform: identity.platform,
        sourceComicId: comic.id,
        title: comic.title,
        subtitle: comic.subtitle ?? '',
        description: comic.description,
        author: metadata.author,
        status: metadata.status,
        updateTime: metadata.updateTime,
        language: comic.language,
        coverUri: comic.cover,
        tags: comic.tags,
        pageCount: comic.maxPage,
      ),
      afterBaseWrite: (comicId) => _mirrorCommonState(identity, comicId),
    );
  }

  String mirrorComicDetails(ComicDetails comic) {
    final identity = identityFor(comic.sourceKey, comic.id);
    final metadata = _ComicMetadata.fromDetails(comic);
    return _safeMirror(
      fallbackComicId: identity.comicId,
      write: () => _db.ensureComicSource(
        platform: identity.platform,
        sourceComicId: comic.id,
        title: comic.title,
        subtitle: comic.subTitle ?? '',
        description: comic.description ?? '',
        author: metadata.author,
        status: metadata.status,
        updateTime: metadata.updateTime,
        coverUri: comic.cover,
        sourceUrl: comic.url,
        sourceTitle: comic.title,
        tags: comic.plainTags,
        pageCount: comic.maxPage,
      ),
      afterBaseWrite: (comicId) => _mirrorCommonState(identity, comicId),
    );
  }

  String mirrorLocalComic(LocalComic comic) {
    final identity = identityFor(comic.sourceKey, comic.id);
    final metadata = _ComicMetadata.fromLocalComic(comic);
    return _safeMirror(
      fallbackComicId: identity.comicId,
      write: () {
        final comicId = _db.ensureComicSource(
          platform: identity.platform,
          sourceComicId: comic.id,
          title: comic.title,
          subtitle: comic.subtitle,
          description: comic.description,
          author: metadata.author,
          status: metadata.status,
          updateTime: metadata.updateTime,
          coverUri: comic.cover,
          tags: comic.tags,
          pageCount: metadata.pageCount,
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

  FavoriteItemWithUpdateInfo? _findFollowUpdateInfo(
    String sourceComicId,
    ComicType type,
  ) {
    final folder = appdata.settings['followUpdatesFolder'];
    if (folder is! String ||
        (_favoritesManager == null && !App.isInitialized)) {
      return null;
    }
    try {
      return _favorites.getComicWithUpdatesInfo(folder, sourceComicId, type);
    } catch (_) {
      return null;
    }
  }

  DomainComicBaseInfo? _findDomainBaseInfo(ComicIdentity identity) {
    try {
      final domain = _domain ?? (App.isInitialized ? App.domain : null);
      if (domain == null || !domain.isInitialized) {
        return null;
      }
      return domain.getComicBaseInfoBySource(
        platform: identity.platform,
        sourceComicId: identity.sourceComicId,
      );
    } catch (_) {
      return null;
    }
  }

  String? _sourceNameFor(String sourceKey) {
    if (sourceKey == 'local') {
      return 'Local';
    }
    return ComicSource.find(sourceKey)?.name;
  }

  List<String> _mergeTags(List<List<String>> groups) {
    final result = <String>[];
    for (final group in groups) {
      for (final tag in group) {
        final clean = _ComicMetadata.clean(tag);
        if (clean == null || _ComicMetadata.isMetadataTag(clean)) {
          continue;
        }
        if (!result.contains(clean)) {
          result.add(clean);
        }
      }
    }
    return result;
  }

  String? _pick(Iterable<String?> values) {
    for (final value in values) {
      final clean = _ComicMetadata.clean(value);
      if (clean != null) {
        return clean;
      }
    }
    return null;
  }
}

class _ComicMetadata {
  const _ComicMetadata({
    this.author,
    this.status,
    this.updateTime,
    this.pageCount,
  });

  final String? author;
  final String? status;
  final String? updateTime;
  final int? pageCount;

  factory _ComicMetadata.fromComic(Comic comic) {
    final tags = comic.tags ?? const <String>[];
    return _ComicMetadata(
      author:
          clean(comic.subtitle) ??
          _first(namespaceValues(tags, _authorNamespaces)),
      status: statusFromTags(tags),
      updateTime: _first(
        namespaceValues(tags, _updateNamespaces).where(_looksLikeDate),
      ),
      pageCount: comic.maxPage ?? _firstPageCount(tags),
    );
  }

  factory _ComicMetadata.fromFavorite(FavoriteItem favorite) {
    return _ComicMetadata(
      author:
          clean(favorite.author) ??
          _first(namespaceValues(favorite.tags, _authorNamespaces)),
      status: statusFromTags(favorite.tags),
      updateTime: _first(
        namespaceValues(favorite.tags, _updateNamespaces).where(_looksLikeDate),
      ),
      pageCount: _firstPageCount(favorite.tags),
    );
  }

  factory _ComicMetadata.fromLocalComic(LocalComic comic) {
    return _ComicMetadata(
      author:
          clean(comic.subtitle) ??
          _first(namespaceValues(comic.tags, _authorNamespaces)),
      status: statusFromTags(comic.tags),
      updateTime: _first(
        namespaceValues(comic.tags, _updateNamespaces).where(_looksLikeDate),
      ),
      pageCount: comic.maxPage ?? _firstPageCount(comic.tags),
    );
  }

  factory _ComicMetadata.fromDetails(ComicDetails comic) {
    final tags = comic.plainTags;
    return _ComicMetadata(
      author:
          clean(comic.findAuthor()) ??
          clean(comic.subTitle) ??
          clean(comic.uploader) ??
          _first(namespaceValues(tags, _authorNamespaces)),
      status: statusFromTags(tags),
      updateTime:
          clean(comic.findUpdateTime()) ??
          _first(
            namespaceValues(tags, _updateNamespaces).where(_looksLikeDate),
          ),
      pageCount: comic.maxPage ?? _firstPageCount(tags),
    );
  }

  static String? statusFromTags(List<String>? tags) {
    if (tags == null) {
      return null;
    }
    return _first(namespaceValues(tags, _statusNamespaces)) ??
        _first(tags.map(clean).whereType<String>().where(_looksLikeStatus));
  }

  static List<String> namespaceValues(
    List<String> tags,
    Set<String> namespaces,
  ) {
    final values = <String>[];
    for (final tag in tags) {
      final index = tag.indexOf(':');
      if (index <= 0) {
        continue;
      }
      final namespace = _normalizeNamespace(tag.substring(0, index));
      if (!namespaces.contains(namespace)) {
        continue;
      }
      final value = clean(tag.substring(index + 1));
      if (value != null) {
        values.add(value);
      }
    }
    return values;
  }

  static bool isMetadataTag(String tag) {
    final index = tag.indexOf(':');
    if (index <= 0) {
      final value = clean(tag);
      return value == null || _looksLikeDate(value) || _looksLikeStatus(value);
    }
    final namespace = _normalizeNamespace(tag.substring(0, index));
    final value = clean(tag.substring(index + 1));
    return _metadataNamespaces.contains(namespace) ||
        value == null ||
        _looksLikeDate(value) ||
        _looksLikeStatus(value);
  }

  static String? clean(String? value) {
    final result = value?.replaceAll('\n', ' ').trim();
    return result == null ||
            result.isEmpty ||
            result == 'Unknown' ||
            result.startsWith('Unknown:')
        ? null
        : result;
  }

  static int? _firstPageCount(List<String> tags) {
    final value = _first(namespaceValues(tags, _pagesNamespaces));
    return value == null ? null : int.tryParse(value);
  }

  static String? _first(Iterable<String> values) {
    for (final value in values) {
      final cleanValue = clean(value);
      if (cleanValue != null) {
        return cleanValue;
      }
    }
    return null;
  }

  static bool _looksLikeDate(String value) {
    return RegExp(r'^\d{4}[-/]\d{1,2}[-/]\d{1,2}').hasMatch(value) ||
        RegExp(r'^\d{4}').hasMatch(value);
  }

  static bool _looksLikeStatus(String value) {
    final normalized = value.trim().toLowerCase();
    return const {
      'completed',
      'complete',
      'ongoing',
      'serializing',
      '連載',
      '連載中',
      '连载',
      '连载中',
      '完結',
      '完结',
      '已完結',
      '已完结',
      '休載',
      '休载',
    }.contains(normalized);
  }

  static String _normalizeNamespace(String value) {
    return value.trim().toLowerCase().replaceAll(' ', '');
  }

  static const _authorNamespaces = {
    'author',
    'artist',
    'authors',
    'artists',
    'creator',
    '原作',
    '作者',
    '作家',
    '作画',
    '作畫',
    '漫畫',
    '漫画',
    '著者',
    '绘师',
    '繪師',
  };

  static const _statusNamespaces = {
    'status',
    'state',
    'serialization',
    '連載',
    '连载',
    '狀態',
    '状态',
  };

  static const _updateNamespaces = {
    'date',
    'lastupdate',
    'time',
    'update',
    'updated',
    '更新',
    '最後更新',
    '最后更新',
    '時間',
    '时间',
    '日期',
  };

  static const _pagesNamespaces = {'page', 'pages', '頁數', '页数'};

  static const _metadataNamespaces = {
    ..._authorNamespaces,
    ..._statusNamespaces,
    ..._updateNamespaces,
    ..._pagesNamespaces,
    'language',
    'source',
    'uploader',
    '語言',
    '语言',
    '來源',
    '来源',
    '上傳者',
    '上传者',
  };
}

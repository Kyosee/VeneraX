import 'package:dio/dio.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';

class ServerHistoryPage {
  const ServerHistoryPage({required this.items, required this.total});

  final List<History> items;
  final int total;
}

class ServerFavoriteFolder {
  const ServerFavoriteFolder({
    required this.name,
    required this.count,
    required this.order,
    this.sourceKey,
    this.sourceFolder,
  });

  final String name;
  final int count;
  final int order;
  final String? sourceKey;
  final String? sourceFolder;
}

class ServerFavoritePage {
  const ServerFavoritePage({required this.items, required this.total});

  final List<FavoriteItem> items;
  final int total;
}

class ServerImageFavoritePage {
  const ServerImageFavoritePage({required this.items, required this.total});

  final List<ImageFavoritesComic> items;
  final int total;
}

class ServerDbClient {
  const ServerDbClient();

  String get _profile {
    final value = appdata.settings['webServerDbProfile']?.toString().trim();
    return value == null || value.isEmpty ? 'default' : value;
  }

  Dio _dio() {
    return Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 60),
        sendTimeout: const Duration(seconds: 30),
      ),
    );
  }

  Future<ServerHistoryPage?> listHistory({
    int limit = 100,
    int offset = 0,
  }) async {
    try {
      final response = await _dio().post(
        '/api/server-db/history/list',
        data: {'profile': _profile, 'limit': limit, 'offset': offset},
      );
      final data = response.data;
      if (data is! Map || data['ok'] != true) {
        return null;
      }
      final rawItems = data['items'];
      final items = rawItems is List
          ? rawItems
                .whereType<Map>()
                .map((item) => History.fromMap(item.cast<String, dynamic>()))
                .toList()
          : <History>[];
      final total = data['total'];
      return ServerHistoryPage(
        items: items,
        total: total is num ? total.toInt() : items.length,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Map<String, dynamic> _historyPayload(History history) {
    return {
      'id': history.id,
      'title': history.title,
      'subtitle': history.subtitle,
      'cover': history.cover,
      'time': history.time.millisecondsSinceEpoch,
      'type': history.type.value,
      'sourceKey': history.sourceKey,
      'ep': history.ep,
      'page': history.page,
      'readEpisode': history.readEpisode.toList(),
      'max_page': history.maxPage,
      'chapter_group': history.group,
    };
  }

  Future<bool> upsertHistory(History history) async {
    final response = await _dio().post(
      '/api/server-db/history/upsert',
      data: {'profile': _profile, 'history': _historyPayload(history)},
    );
    final data = response.data;
    return data is Map && data['ok'] == true;
  }

  Future<bool> deleteHistory(String id, ComicType type) async {
    final response = await _dio().post(
      '/api/server-db/history/delete',
      data: {'profile': _profile, 'id': id, 'type': type.value},
    );
    final data = response.data;
    return data is Map && data['ok'] == true;
  }

  Future<bool> clearHistory() async {
    final response = await _dio().post(
      '/api/server-db/history/clear',
      data: {'profile': _profile},
    );
    final data = response.data;
    return data is Map && data['ok'] == true;
  }

  Future<bool> clearUnfavoritedHistory() async {
    final response = await _dio().post(
      '/api/server-db/history/clear-unfavorited',
      data: {'profile': _profile},
    );
    final data = response.data;
    return data is Map && data['ok'] == true;
  }

  Future<bool> _postOk(String path, Map<String, dynamic> data) async {
    final response = await _dio().post(
      path,
      data: {'profile': _profile, ...data},
    );
    final responseData = response.data;
    return responseData is Map && responseData['ok'] == true;
  }

  Map<String, dynamic> _favoriteItemPayload(FavoriteItem item) {
    return {...item.toJson(), 'time': item.time};
  }

  FavoriteItem _favoriteItemFromMap(Map<String, dynamic> item) {
    final favorite = FavoriteItem.fromJson({
      'id': item['id'],
      'name': item['name'],
      'author': item['author'],
      'type': item['type'],
      'tags': item['tags'],
      'coverPath': item['coverPath'],
      'lastUpdateTime': item['lastUpdateTime'],
      'hasNewUpdate': item['hasNewUpdate'],
      'lastCheckTime': item['lastCheckTime'],
    });
    final time = item['time']?.toString();
    if (time != null && time.isNotEmpty) {
      favorite.time = time;
    }
    return favorite;
  }

  Map<String, dynamic> _imageFavoritePayload(ImageFavoritesComic comic) {
    return {
      'id': comic.id,
      'title': comic.title,
      'subTitle': comic.subTitle,
      'author': comic.author,
      'tags': comic.tags,
      'translatedTags': comic.translatedTags,
      'time': comic.time.millisecondsSinceEpoch,
      'maxPage': comic.maxPage,
      'sourceKey': comic.sourceKey,
      'imageFavoritesEp': comic.imageFavoritesEp
          .map((ep) => ep.toJson())
          .toList(),
      'other': comic.other,
    };
  }

  ImageFavoritesComic _imageFavoriteFromMap(Map<String, dynamic> item) {
    final rawEps = item['imageFavoritesEp'] ?? item['image_favorites_ep'];
    final eps = rawEps is List ? rawEps : const [];
    final imageFavoritesEp = eps.whereType<Map>().map((rawEp) {
      final ep = rawEp.cast<String, dynamic>();
      final epIndex = (ep['ep'] as num?)?.toInt() ?? 0;
      final eid = ep['eid']?.toString() ?? '';
      final epName = ep['epName']?.toString() ?? '';
      final maxPage = (ep['maxPage'] as num?)?.toInt() ?? 1;
      final rawImages = ep['imageFavorites'];
      final images = rawImages is List ? rawImages : const [];
      return ImageFavoritesEp(
        eid,
        epIndex,
        images.whereType<Map>().map((rawImage) {
          final image = rawImage.cast<String, dynamic>();
          return ImageFavorite(
            (image['page'] as num?)?.toInt() ?? 0,
            image['imageKey']?.toString() ?? '',
            image['isAutoFavorite'] as bool?,
            eid,
            item['id']?.toString() ?? '',
            epIndex,
            item['sourceKey']?.toString() ?? '',
            epName,
          );
        }).toList(),
        epName,
        maxPage,
      );
    }).toList();
    final rawOther = item['other'];
    return ImageFavoritesComic(
      item['id']?.toString() ?? '',
      imageFavoritesEp,
      item['title']?.toString() ?? '',
      item['sourceKey']?.toString() ?? '',
      (item['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      (item['translatedTags'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[],
      DateTime.fromMillisecondsSinceEpoch(
        (item['time'] as num?)?.toInt() ?? 0,
      ),
      item['author']?.toString() ?? '',
      rawOther is Map ? rawOther.cast<String, dynamic>() : <String, dynamic>{},
      item['subTitle']?.toString() ?? '',
      (item['maxPage'] as num?)?.toInt() ?? 0,
    );
  }

  Future<ServerImageFavoritePage?> listImageFavorites({
    int limit = 500,
    int offset = 0,
  }) async {
    try {
      final response = await _dio().post(
        '/api/server-db/image-favorites/list',
        data: {'profile': _profile, 'limit': limit, 'offset': offset},
      );
      final data = response.data;
      if (data is! Map || data['ok'] != true) {
        return null;
      }
      final rawItems = data['items'];
      final items = rawItems is List
          ? rawItems
                .whereType<Map>()
                .map((item) => _imageFavoriteFromMap(item.cast<String, dynamic>()))
                .toList()
          : <ImageFavoritesComic>[];
      final total = data['total'];
      return ServerImageFavoritePage(
        items: items,
        total: total is num ? total.toInt() : items.length,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<bool> replaceImageFavorites(List<ImageFavoritesComic> comics) {
    return _postOk('/api/server-db/image-favorites/replace', {
      'items': comics.map(_imageFavoritePayload).toList(),
    });
  }

  Future<List<ServerFavoriteFolder>?> listFavoriteFolders() async {
    try {
      final response = await _dio().post(
        '/api/server-db/favorites/folders',
        data: {'profile': _profile},
      );
      final data = response.data;
      if (data is! Map || data['ok'] != true) {
        return null;
      }
      final folders = data['folders'];
      if (folders is! List) {
        return <ServerFavoriteFolder>[];
      }
      return folders.whereType<Map>().map((folder) {
        final item = folder.cast<String, dynamic>();
        return ServerFavoriteFolder(
          name: item['name']?.toString() ?? '',
          count: item['count'] is num ? (item['count'] as num).toInt() : 0,
          order: item['order'] is num ? (item['order'] as num).toInt() : 0,
          sourceKey: item['sourceKey']?.toString(),
          sourceFolder: item['sourceFolder']?.toString(),
        );
      }).where((folder) => folder.name.isNotEmpty).toList();
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<ServerFavoritePage?> listFavoriteItems(
    String folder, {
    int limit = 100,
    int offset = 0,
  }) async {
    try {
      final response = await _dio().post(
        '/api/server-db/favorites/list',
        data: {
          'profile': _profile,
          'folder': folder,
          'limit': limit,
          'offset': offset,
        },
      );
      final data = response.data;
      if (data is! Map || data['ok'] != true) {
        return null;
      }
      final rawItems = data['items'];
      final items = rawItems is List
          ? rawItems
                .whereType<Map>()
                .map((item) => _favoriteItemFromMap(item.cast<String, dynamic>()))
                .toList()
          : <FavoriteItem>[];
      final total = data['total'];
      return ServerFavoritePage(
        items: items,
        total: total is num ? total.toInt() : items.length,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<bool> createFavoriteFolder(
    String name, {
    bool renameWhenInvalidName = false,
  }) {
    return _postOk('/api/server-db/favorites/folder/create', {
      'name': name,
      'renameWhenInvalidName': renameWhenInvalidName,
    });
  }

  Future<bool> deleteFavoriteFolder(String name) {
    return _postOk('/api/server-db/favorites/folder/delete', {'name': name});
  }

  Future<bool> renameFavoriteFolder(String before, String after) {
    return _postOk('/api/server-db/favorites/folder/rename', {
      'before': before,
      'after': after,
    });
  }

  Future<bool> updateFavoriteFolderOrder(List<String> folders) {
    return _postOk('/api/server-db/favorites/folder/order', {
      'folders': folders,
    });
  }

  Future<bool> linkFavoriteFolderToNetwork(
    String folder,
    String source,
    String networkFolder,
  ) {
    return _postOk('/api/server-db/favorites/folder/link', {
      'folder': folder,
      'source': source,
      'networkFolder': networkFolder,
    });
  }

  Future<bool> addFavoriteItem(
    String folder,
    FavoriteItem item, {
    int? order,
    String? updateTime,
  }) {
    return _postOk('/api/server-db/favorites/add', {
      'folder': folder,
      'item': _favoriteItemPayload(item),
      if (order != null) 'order': order,
      if (updateTime != null) 'updateTime': updateTime,
    });
  }

  Future<bool> deleteFavoriteItem(String folder, String id, ComicType type) {
    return _postOk('/api/server-db/favorites/delete', {
      'folder': folder,
      'id': id,
      'type': type.value,
    });
  }

  Future<bool> batchDeleteFavoriteItems(
    String folder,
    List<FavoriteItem> items,
  ) {
    return _postOk('/api/server-db/favorites/batch-delete', {
      'folder': folder,
      'items': items
          .map((item) => {'id': item.id, 'type': item.type.value})
          .toList(),
    });
  }

  Future<bool> batchDeleteFavoriteItemsInAllFolders(List<ComicID> items) {
    return _postOk('/api/server-db/favorites/batch-delete-all', {
      'items': items
          .map((item) => {'id': item.id, 'type': item.type.value})
          .toList(),
    });
  }

  Future<bool> reorderFavoriteItems(String folder, List<FavoriteItem> items) {
    return _postOk('/api/server-db/favorites/reorder', {
      'folder': folder,
      'items': [
        for (var i = 0; i < items.length; i++)
          {'id': items[i].id, 'type': items[i].type.value, 'order': i},
      ],
    });
  }

  Future<bool> updateFavoriteTags(
    String folder,
    String id,
    ComicType? type,
    List<String> tags,
  ) {
    return _postOk('/api/server-db/favorites/tags', {
      'folder': folder,
      'id': id,
      if (type != null) 'type': type.value,
      'tags': tags,
    });
  }

  Future<bool> updateFavoriteInfo(String folder, FavoriteItem item) {
    return _postOk('/api/server-db/favorites/info', {
      'folder': folder,
      'item': _favoriteItemPayload(item),
    });
  }

  Future<bool> updateFavoriteUpdateTime(
    String folder,
    String id,
    ComicType type,
    String updateTime,
    int lastCheckTime,
  ) {
    return _postOk('/api/server-db/favorites/update-time', {
      'folder': folder,
      'id': id,
      'type': type.value,
      'updateTime': updateTime,
      'lastCheckTime': lastCheckTime,
    });
  }

  Future<bool> updateFavoriteCheckTime(
    String folder,
    String id,
    ComicType type,
    int lastCheckTime,
  ) {
    return _postOk('/api/server-db/favorites/check-time', {
      'folder': folder,
      'id': id,
      'type': type.value,
      'lastCheckTime': lastCheckTime,
    });
  }

  Future<bool> markFavoriteAsRead(String folder, String id, ComicType type) {
    return _postOk('/api/server-db/favorites/mark-read', {
      'folder': folder,
      'id': id,
      'type': type.value,
    });
  }

  Future<bool> readFavorite(
    String id,
    ComicType type, {
    required String moveMode,
    String? followUpdatesFolder,
  }) {
    return _postOk('/api/server-db/favorites/read', {
      'id': id,
      'type': type.value,
      'moveMode': moveMode,
      if (followUpdatesFolder != null) 'followUpdatesFolder': followUpdatesFolder,
    });
  }

  Future<bool> moveFavoriteItem(
    String sourceFolder,
    String targetFolder,
    String id,
    ComicType type,
  ) {
    return _postOk('/api/server-db/favorites/move', {
      'sourceFolder': sourceFolder,
      'targetFolder': targetFolder,
      'id': id,
      'type': type.value,
    });
  }

  Future<bool> batchMoveFavoriteItems(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    return _postOk('/api/server-db/favorites/batch-move', {
      'sourceFolder': sourceFolder,
      'targetFolder': targetFolder,
      'items': items
          .map((item) => {'id': item.id, 'type': item.type.value})
          .toList(),
    });
  }

  Future<bool> batchCopyFavoriteItems(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    return _postOk('/api/server-db/favorites/batch-copy', {
      'sourceFolder': sourceFolder,
      'targetFolder': targetFolder,
      'items': items
          .map((item) => {'id': item.id, 'type': item.type.value})
          .toList(),
    });
  }

  Future<List<String>?> findFavoriteFolders(String id, ComicType type) async {
    try {
      final response = await _dio().post(
        '/api/server-db/favorites/find',
        data: {'profile': _profile, 'id': id, 'type': type.value},
      );
      final data = response.data;
      if (data is! Map || data['ok'] != true) {
        return null;
      }
      final folders = data['folders'];
      return folders is List
          ? folders.map((item) => item.toString()).toList()
          : <String>[];
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }

  Future<FavoriteItem?> getFavoriteItem(
    String folder,
    String id,
    ComicType type,
  ) async {
    try {
      final response = await _dio().post(
        '/api/server-db/favorites/get',
        data: {
          'profile': _profile,
          'folder': folder,
          'id': id,
          'type': type.value,
        },
      );
      final data = response.data;
      if (data is! Map || data['ok'] != true || data['item'] is! Map) {
        return null;
      }
      return _favoriteItemFromMap(
        (data['item'] as Map).cast<String, dynamic>(),
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      rethrow;
    }
  }
}

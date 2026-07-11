part of "history.dart";

class ImageFavorite {
  final String eid;
  final String id; // 漫画id
  final int ep;
  final String epName;
  final String sourceKey;
  String imageKey;
  int page;
  bool? isAutoFavorite;

  ImageFavorite(
    this.page,
    this.imageKey,
    this.isAutoFavorite,
    this.eid,
    this.id,
    this.ep,
    this.sourceKey,
    this.epName,
  );

  Map<String, dynamic> toJson() {
    return {
      'page': page,
      'imageKey': imageKey,
      'isAutoFavorite': isAutoFavorite,
      'eid': eid,
      'id': id,
      'ep': ep,
      'sourceKey': sourceKey,
      'epName': epName,
    };
  }

  ImageFavorite.fromJson(Map<String, dynamic> json)
    : page = json['page'],
      imageKey = json['imageKey'],
      isAutoFavorite = json['isAutoFavorite'],
      eid = json['eid'],
      id = json['id'],
      ep = json['ep'],
      sourceKey = json['sourceKey'],
      epName = json['epName'];

  ImageFavorite copyWith({
    int? page,
    String? imageKey,
    bool? isAutoFavorite,
    String? eid,
    String? id,
    int? ep,
    String? sourceKey,
    String? epName,
  }) {
    return ImageFavorite(
      page ?? this.page,
      imageKey ?? this.imageKey,
      isAutoFavorite ?? this.isAutoFavorite,
      eid ?? this.eid,
      id ?? this.id,
      ep ?? this.ep,
      sourceKey ?? this.sourceKey,
      epName ?? this.epName,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ImageFavorite &&
        other.id == id &&
        other.sourceKey == sourceKey &&
        other.page == page &&
        other.eid == eid &&
        other.ep == ep;
  }

  @override
  int get hashCode => Object.hash(id, sourceKey, page, eid, ep);
}

class ImageFavoritesEp {
  // 小心拷贝等多章节的可能更新章节顺序
  String eid;
  final int ep;
  int maxPage;
  String epName;
  List<ImageFavorite> imageFavorites;

  ImageFavoritesEp(
    this.eid,
    this.ep,
    this.imageFavorites,
    this.epName,
    this.maxPage,
  );

  // 是否有封面
  bool get isHasFirstPage {
    return imageFavorites[0].page == firstPage;
  }

  // 是否都有imageKey
  bool get isHasImageKey {
    return imageFavorites.every((e) => e.imageKey != "");
  }

  Map<String, dynamic> toJson() {
    return {
      'eid': eid,
      'ep': ep,
      'maxPage': maxPage,
      'epName': epName,
      'imageFavorites': imageFavorites.map((e) => e.toJson()).toList(),
    };
  }
}

class ImageFavoritesComic {
  final String id;
  final String title;
  String subTitle;
  String author;
  final String sourceKey;

  // 不一定是真的这本漫画的所有页数, 如果是多章节的时候
  int maxPage;
  List<String> tags;
  List<String> translatedTags;
  final DateTime time;
  List<ImageFavoritesEp> imageFavoritesEp;
  final Map<String, dynamic> other;

  ImageFavoritesComic(
    this.id,
    this.imageFavoritesEp,
    this.title,
    this.sourceKey,
    this.tags,
    this.translatedTags,
    this.time,
    this.author,
    this.other,
    this.subTitle,
    this.maxPage,
  );

  // 是否都有imageKey
  bool get isAllHasImageKey {
    return imageFavoritesEp.every(
      (e) => e.imageFavorites.every((j) => j.imageKey != ""),
    );
  }

  int get maxPageFromEp {
    int temp = 0;
    for (var e in imageFavoritesEp) {
      temp += e.maxPage;
    }
    return temp;
  }

  // 是否都有封面
  bool get isAllHasFirstPage {
    return imageFavoritesEp.every((e) => e.isHasFirstPage);
  }

  Iterable<ImageFavorite> get images sync* {
    for (var e in imageFavoritesEp) {
      yield* e.imageFavorites;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is ImageFavoritesComic &&
        other.id == id &&
        other.sourceKey == sourceKey;
  }

  @override
  int get hashCode => Object.hash(id, sourceKey);

  factory ImageFavoritesComic.fromRow(Row r) {
    var tempImageFavoritesEp = jsonDecode(r["image_favorites_ep"]);
    List<ImageFavoritesEp> finalImageFavoritesEp = [];
    tempImageFavoritesEp.forEach((i) {
      List<ImageFavorite> temp = [];
      i["imageFavorites"].forEach((j) {
        temp.add(
          ImageFavorite(
            j["page"],
            j["imageKey"],
            j["isAutoFavorite"],
            i["eid"],
            r["id"],
            i["ep"],
            r["source_key"],
            i["epName"],
          ),
        );
      });
      finalImageFavoritesEp.add(
        ImageFavoritesEp(
          i["eid"],
          i["ep"],
          temp,
          i["epName"],
          i["maxPage"] ?? 1,
        ),
      );
    });
    return ImageFavoritesComic(
      r["id"],
      finalImageFavoritesEp,
      r["title"],
      r["source_key"],
      r["tags"].split(","),
      r["translated_tags"].split(","),
      DateTime.fromMillisecondsSinceEpoch(r["time"]),
      r["author"],
      jsonDecode(r["other"]),
      r["sub_title"],
      r["max_page"],
    );
  }
}

class ImageFavoriteManager with ChangeNotifier {
  CommonDatabase get _db => HistoryManager()._db;

  List<ImageFavoritesComic> get comics => getAll();

  static ImageFavoriteManager? _cache;

  ImageFavoriteManager._();

  factory ImageFavoriteManager() => (_cache ??= ImageFavoriteManager._());

  /// 检查表image_favorites是否存在, 不存在则创建
  void init() {
    _db.execute(
      "CREATE TABLE IF NOT EXISTS image_favorites ("
      "id TEXT,"
      "title TEXT NOT NULL,"
      "sub_title TEXT,"
      "author TEXT,"
      "tags TEXT,"
      "translated_tags TEXT,"
      "time int,"
      "max_page int,"
      "source_key TEXT NOT NULL,"
      "image_favorites_ep TEXT NOT NULL,"
      "other TEXT NOT NULL,"
      "PRIMARY KEY (id,source_key)"
      ");",
    );
    _checkAndFixCacheKeyBug();
  }

  /// 检测并修复旧版本缓存 key 缺少 page 字段导致的图片错乱问题。
  ///
  /// 问题：v2.0.11 及更早版本的缓存 key 格式为：
  /// `ImageFavorites imageKey@sourceKey@id@eid`（缺少 @page）
  /// 导致同一章节的不同页共享缓存，后下载的图片覆盖先下载的。
  ///
  /// 修复策略：
  /// 1. 检查 implicitData 中的版本标记
  /// 2. 如果是旧版本或未标记，清空图片收藏缓存目录
  /// 3. 标记已修复，避免重复清理
  void _checkAndFixCacheKeyBug() {
    const cacheKeyFixVersion = 'image_favorites_cache_key_fix_v1';

    // 已经修复过，跳过
    if (appdata.implicitData[cacheKeyFixVersion] == true) {
      return;
    }

    try {
      // 清空图片收藏缓存目录
      final cachePath = FilePath.join(App.cachePath, 'image_favorites');
      final cacheDir = Directory(cachePath);
      if (cacheDir.existsSync()) {
        final fileCount = cacheDir.listSync().length;
        cacheDir.deleteSync(recursive: true);
        Log.info(
          'ImageFavoriteManager',
          'Cleared $fileCount corrupted cache files due to cache key bug fix',
        );
      }

      // 标记已修复
      appdata.implicitData[cacheKeyFixVersion] = true;
      appdata.writeImplicitData();
    } catch (e, stackTrace) {
      Log.error('ImageFavoriteManager', 'Failed to fix cache key bug: $e', stackTrace);
    }
  }

  // 做排序和去重的操作
  void addOrUpdateOrDelete(ImageFavoritesComic favorite, [bool notify = true]) {
    // 没有章节了就删掉
    if (favorite.imageFavoritesEp.isEmpty) {
      _db.execute(
        """
      delete from image_favorites
      where id == ? and source_key == ?;
    """,
        [favorite.id, favorite.sourceKey],
      );
    } else {
      // 去重章节
      List<ImageFavoritesEp> tempImageFavoritesEp = [];
      for (var e in favorite.imageFavoritesEp) {
        int index = tempImageFavoritesEp.indexWhere((i) {
          return i.ep == e.ep;
        });
        // 再做一层保险, 防止出现ep为0的脏数据
        if (index == -1 && e.ep > 0) {
          tempImageFavoritesEp.add(e);
        }
      }
      tempImageFavoritesEp.sort((a, b) => a.ep.compareTo(b.ep));
      List<dynamic> finalImageFavoritesEp = jsonDecode(
        jsonEncode(tempImageFavoritesEp),
      );
      for (var e in tempImageFavoritesEp) {
        List<Map> finalImageFavorites = [];
        int epIndex = tempImageFavoritesEp.indexOf(e);
        for (ImageFavorite j in e.imageFavorites) {
          int index = finalImageFavorites.indexWhere(
            (i) => i["page"] == j.page,
          );
          if (index == -1 && j.page > 0) {
            // isAutoFavorite 为 null 不写入数据库, 同时只保留需要的属性, 避免增加太多重复字段在数据库里
            if (j.isAutoFavorite != null) {
              finalImageFavorites.add({
                "page": j.page,
                "imageKey": j.imageKey,
                "isAutoFavorite": j.isAutoFavorite,
              });
            } else {
              finalImageFavorites.add({"page": j.page, "imageKey": j.imageKey});
            }
          }
        }
        finalImageFavorites.sort((a, b) => a["page"].compareTo(b["page"]));
        finalImageFavoritesEp[epIndex]["imageFavorites"] = finalImageFavorites;
      }
      if (tempImageFavoritesEp.isEmpty) {
        throw "Error: No ImageFavoritesEp";
      }
      _db.execute(
        """
      insert or replace into image_favorites(id, title, sub_title, author, tags, translated_tags, time, max_page, source_key, image_favorites_ep, other)
      values(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
    """,
        [
          favorite.id,
          favorite.title,
          favorite.subTitle,
          favorite.author,
          favorite.tags.join(","),
          favorite.translatedTags.join(","),
          favorite.time.millisecondsSinceEpoch,
          favorite.maxPage,
          favorite.sourceKey,
          jsonEncode(finalImageFavoritesEp),
          jsonEncode(favorite.other),
        ],
      );
    }
    if (notify) {
      notifyListeners();
    }
  }

  bool has(String id, String sourceKey, String eid, int page, int ep) {
    var comic = find(id, sourceKey);
    if (comic == null) {
      return false;
    }
    var epIndex = comic.imageFavoritesEp.where((e) => e.eid == eid).firstOrNull;
    if (epIndex == null) {
      return false;
    }
    return epIndex.imageFavorites.any((e) => e.page == page && e.ep == ep);
  }

  List<ImageFavoritesComic> getAll([String? keyword]) {
    if (!HistoryManager().isInitialized) return [];
    ResultSet res;
    if (keyword == null || keyword == "") {
      res = _db.select("select * from image_favorites;");
    } else {
      res = _db.select(
        """
    select * from image_favorites
    WHERE title LIKE ?
    OR sub_title LIKE ?
    OR LOWER(tags) LIKE LOWER(?)
    OR LOWER(translated_tags) LIKE LOWER(?)
    OR author LIKE ?;
    """,
        ['%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%', '%$keyword%'],
      );
    }
    try {
      return res.map((e) => ImageFavoritesComic.fromRow(e)).toList();
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
      return [];
    }
  }

  void deleteImageFavorite(Iterable<ImageFavorite> imageFavoriteList) {
    if (imageFavoriteList.isEmpty) {
      return;
    }
    for (var i in imageFavoriteList) {
      ImageFavoritesProvider.deleteFromCache(i);
    }
    var comics = <ImageFavoritesComic>{};
    for (var i in imageFavoriteList) {
      var comic =
          comics
              .where((c) => c.id == i.id && c.sourceKey == i.sourceKey)
              .firstOrNull ??
          find(i.id, i.sourceKey);
      if (comic == null) {
        continue;
      }
      var ep = comic.imageFavoritesEp.firstWhereOrNull((e) => e.ep == i.ep);
      if (ep == null) {
        continue;
      }
      ep.imageFavorites.remove(i);
      if (ep.imageFavorites.isEmpty) {
        comic.imageFavoritesEp.remove(ep);
      }
      comics.add(comic);
    }
    for (var i in comics) {
      addOrUpdateOrDelete(i, false);
    }
    notifyListeners();
  }

  int get length {
    if (!HistoryManager().isInitialized) return 0;
    var res = _db.select("select count(*) from image_favorites;");
    return res.first.values.first! as int;
  }

  List<ImageFavoritesComic> search(String keyword) {
    if (keyword == "") {
      return [];
    }
    return getAll(keyword);
  }

  static Future<ImageFavoritesComputed> computeImageFavorites() {
    try {
      var count = ImageFavoriteManager().length;
      if (count == 0) {
        return Future.value(ImageFavoritesComputed([], [], [], 0));
      } else if (count <= 100) {
        return Future.value(_computeImageFavorites());
      } else {
        final token = ServicesBinding.rootIsolateToken;
        if (token == null) {
          return Future.value(_computeImageFavorites());
        }
        // Raw guardedRead instead of isolateOp: this op must bring up manager
        // code inside the isolate (App.init + HistoryManager().init, which
        // registers its handle with the isolate's OWN gateway singleton), not
        // just open one connection. The handle is released by the sqlite3
        // package's finalizer when the isolate exits.
        return DatabaseGateway.instance.guardedRead(() {
          return Isolate.run(() async {
            BackgroundIsolateBinaryMessenger.ensureInitialized(token);
            await App.init();
            await HistoryManager().init();
            return _computeImageFavorites();
          });
        });
      }
    } catch (_) {
      return Future.value(ImageFavoritesComputed([], [], [], 0));
    }
  }

  /// Namespaces that some sources attach to comics as pseudo-tags but which
  /// are metadata, not genre/character tags. Matched case-insensitively
  /// against the part before the first ":".
  static const Set<String> _metadataNamespaces = {
    'time',
    'date',
    'updated',
    'update',
    'uploaded',
    'upload',
    'posted',
    'pages',
    'page',
    '更新',
    '更新时间',
    '更新日期',
    '日期',
    '时间',
    '上传',
    '上传时间',
    '页数',
  };

  /// Matches values that are clearly a date or timestamp, e.g.
  /// `2024-12-01`, `2024/12/01`, `2024-12-01 12:30`, `2024.12.01`.
  static final RegExp _dateLike = RegExp(
    r'^\d{4}[-/.]\d{1,2}([-/.]\d{1,2})?([ T]\d{1,2}:\d{2}(:\d{2})?)?$',
  );

  /// True when [tag] is metadata that should not appear in the Tags chart.
  /// Decides by namespace first, then by a date-pattern check on the value
  /// (catches metadata from sources that use an unknown namespace).
  static bool _isMetadataTag(String tag) {
    var idx = tag.indexOf(":");
    if (idx > 0) {
      var ns = tag.substring(0, idx).trim().toLowerCase();
      if (_metadataNamespaces.contains(ns)) return true;
    }
    var value = tag.split(":").last.trim();
    return _dateLike.hasMatch(value);
  }

  static ImageFavoritesComputed _computeImageFavorites() {
    const maxLength = 20;

    var comics = ImageFavoriteManager().getAll();
    // 去掉这些没有意义的标签
    const List<String> exceptTags = [
      '連載中',
      '',
      'translated',
      'chinese',
      'sole male',
      'sole female',
      'original',
      'doujinshi',
      'manga',
      'multi-work series',
      'mosaic censorship',
      'dilf',
      'bbm',
      'uncensored',
      'full censorship',
    ];

    Map<String, int> tagCount = {};
    Map<String, int> authorCount = {};
    Map<ImageFavoritesComic, int> comicImageCount = {};
    Map<ImageFavoritesComic, int> comicMaxPages = {};
    int count = 0;

    for (var comic in comics) {
      count += comic.images.length;
      for (var tag in comic.tags) {
        // Skip metadata fields (update date, upload time, page count, etc.)
        // that some sources mix into the tag list — they pollute the chart.
        if (_isMetadataTag(tag)) continue;
        String finalTag = tag.split(":").last;
        tagCount[finalTag] = (tagCount[finalTag] ?? 0) + 1;
      }

      if (comic.author != "") {
        String finalAuthor = comic.author;
        authorCount[finalAuthor] =
            (authorCount[finalAuthor] ?? 0) + comic.images.length;
      }
      // 小于10页的漫画不统计
      if (comic.maxPageFromEp < 10) {
        continue;
      }
      comicImageCount[comic] =
          (comicImageCount[comic] ?? 0) + comic.images.length;
      comicMaxPages[comic] = (comicMaxPages[comic] ?? 0) + comic.maxPageFromEp;
    }

    // 按数量排序标签
    List<String> sortedTags = tagCount.keys.toList()
      ..sort((a, b) => tagCount[b]!.compareTo(tagCount[a]!));

    // 按数量排序作者
    List<String> sortedAuthors = authorCount.keys.toList()
      ..sort((a, b) => authorCount[b]!.compareTo(authorCount[a]!));

    // 按收藏数量排序漫画
    List<MapEntry<ImageFavoritesComic, int>> sortedComicsByNum =
        comicImageCount.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));

    validateTag(String tag) {
      if (tag.startsWith("Category:")) {
        return false;
      }
      return !exceptTags.contains(tag.split(":").last.toLowerCase()) &&
          !tag.isNum;
    }

    return ImageFavoritesComputed(
      sortedTags
          .where(validateTag)
          .map((tag) => TextWithCount(tag, tagCount[tag]!))
          .take(maxLength)
          .toList(),
      sortedAuthors
          .map((author) => TextWithCount(author, authorCount[author]!))
          .take(maxLength)
          .toList(),
      sortedComicsByNum
          .map((comic) => TextWithCount(comic.key.title, comic.value))
          .take(maxLength)
          .toList(),
      count,
    );
  }

  ImageFavoritesComic? find(String id, String sourceKey) {
    var row = _db.select(
      """
    select * from image_favorites
    where id == ? and source_key == ?;
    """,
      [id, sourceKey],
    );
    if (row.isEmpty) {
      return null;
    }
    return ImageFavoritesComic.fromRow(row.first);
  }
}

class TextWithCount {
  final String text;
  final int count;

  const TextWithCount(this.text, this.count);
}

class ImageFavoritesComputed {
  /// 基于收藏的标签数排序
  final List<TextWithCount> tags;

  /// 基于收藏的作者数排序
  final List<TextWithCount> authors;

  /// 基于喜欢的图片数排序
  final List<TextWithCount> comics;

  final int count;

  /// 计算后的图片收藏数据
  const ImageFavoritesComputed(
    this.tags,
    this.authors,
    this.comics,
    this.count,
  );

  bool get isEmpty => tags.isEmpty && authors.isEmpty && comics.isEmpty;
}

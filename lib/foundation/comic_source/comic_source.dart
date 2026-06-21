library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/source_library.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/pages/category_comics_page.dart';
import 'package:venera/pages/search_result_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import '../js_engine.dart';
import '../log.dart';

part 'category.dart';

part 'favorites.dart';

part 'parser.dart';

part 'models.dart';

part 'types.dart';

class ComicSourceManager with ChangeNotifier, Init {
  final List<ComicSource> _sources = [];

  static ComicSourceManager? _instance;

  ComicSourceManager._create();

  final _recoverableParseWarnings = <String>{};

  factory ComicSourceManager() => _instance ??= ComicSourceManager._create();

  List<ComicSource> all() => List.from(_sources);

  ComicSource? find(String key) =>
      _sources.firstWhereOrNull((element) => element.key == key);

  ComicSource? fromIntKey(int key) =>
      _sources.firstWhereOrNull((element) => element.key.hashCode == key) ??
      switch (SourcePlatformResolver.sourceKeyFromLegacyInt(key)) {
        final sourceKey? => find(sourceKey),
        null => null,
      };

  @override
  @protected
  Future<void> doInit() async {
    await JsEngine().ensureInit();
    ComicSourceLibraryManager.migrateIfNeeded();
    final path = "${App.dataPath}/comic_source";
    if (!(await Directory(path).exists())) {
      await Directory(path).create(recursive: true);
      return;
    }
    await for (var entity in Directory(path).list()) {
      if (entity is File && entity.path.endsWith(".js")) {
        try {
          var source = await ComicSourceParser().parse(
            await entity.readAsString(),
            entity.absolute.path,
          );
          _addParsedSource(source, entity.name);
        } catch (e, s) {
          if (e is ComicSourceParseException && e.isRecoverable) {
            _logRecoverableParseWarning(entity.name, e);
          } else {
            Log.error("ComicSource", e, s);
          }
        }
      }
    }
  }

  Future reload() async {
    _sources.clear();
    _recoverableParseWarnings.clear();
    JsEngine().runCode("ComicSource.sources = {};");
    await doInit();
    notifyListeners();
  }

  /// Adds a parsed source. Returns false if a source with the same key is
  /// already installed (the duplicate is rejected), so callers can clean up the
  /// just-downloaded script and surface a message instead of silently
  /// half-installing it.
  bool add(ComicSource source) {
    final added = _addParsedSource(source, source.filePath);
    if (added) {
      notifyListeners();
    }
    return added;
  }

  bool _addParsedSource(ComicSource source, String sourceName) {
    if (find(source.key) != null) {
      _logRecoverableParseWarning(
        sourceName,
        ComicSourceParseException(
          "key(${source.key}) already exists",
          isRecoverable: true,
        ),
      );
      return false;
    }
    _sources.add(source);
    SourcePlatformResolver.registerLegacyIntSourceKey(
      source.key.hashCode,
      source.key,
    );
    return true;
  }

  void _logRecoverableParseWarning(
    String sourceName,
    ComicSourceParseException error,
  ) {
    if (error.message == "Invalid Content") {
      return;
    }
    if (error.message.startsWith("key(") &&
        error.message.endsWith("already exists")) {
      return;
    }
    final warningKey = "$sourceName:${error.message}";
    if (!_recoverableParseWarnings.add(warningKey)) {
      return;
    }
    Log.warning("ComicSource", "Skipped $sourceName: $error");
  }

  void remove(String key) {
    _sources.removeWhere((element) => element.key == key);
    // Drop cached update state so a reinstalled source with the same key does
    // not inherit a stale version badge, download URL, or switch hint.
    _availableUpdates.remove(key);
    _updateUrls.remove(key);
    _newerElsewhere.remove(key);
    notifyListeners();
  }

  bool get isEmpty => _sources.isEmpty;

  /// Key is the source key, value is the version.
  final _availableUpdates = <String, String>{};

  /// Key is the source key, value is the download URL resolved from the source
  /// list during the last update check. Single-source updates prefer this over
  /// the URL baked into the installed script, so a migrated source list points
  /// downloads at the new address instead of the dead old one.
  final _updateUrls = <String, String>{};

  /// Replaces the entire pending-update set. Used by the multi-library check so
  /// that a source whose update is no longer offered (origin library removed or
  /// disabled, or it was just updated) does not linger as a stale badge.
  void replaceAvailableUpdates(Map<String, String> updates) {
    _availableUpdates
      ..clear()
      ..addAll(updates);
    notifyListeners();
  }

  /// Transient (never persisted) record of sources whose update-governing
  /// library version is beaten by a DIFFERENT library offering the same key.
  /// Drives a "newer version exists in another library" hint and the explicit
  /// switch action; it never triggers an automatic update.
  final _newerElsewhere = <String, ({String libraryId, String version})>{};

  ({String libraryId, String version})? newerElsewhereFor(String key) =>
      _newerElsewhere[key];

  void setNewerElsewhere(
    Map<String, ({String libraryId, String version})> data,
  ) {
    _newerElsewhere
      ..clear()
      ..addAll(data);
  }

  Map<String, String> get availableUpdates => Map.from(_availableUpdates);

  /// Records the download URL for [key] resolved from the source list.
  void setUpdateUrl(String key, String url) {
    _updateUrls[key] = url;
  }

  /// Returns the source-list-derived download URL for [key], if known.
  String? updateUrlFor(String key) => _updateUrls[key];

  void clearAvailableUpdate(String key) {
    final hadUpdate = _availableUpdates.remove(key) != null;
    _updateUrls.remove(key);
    if (hadUpdate) {
      notifyListeners();
    }
  }

  /// Origin/offering libraries for an installed source. Backed by the
  /// device-local settings store (not synced), so it survives an update-reload
  /// (which removes and re-adds the same key) and only clears on a genuine
  /// uninstall.
  SourceProvenance? provenanceFor(String key) =>
      ComicSourceLibraryManager.provenanceFor(key);

  void updateProvenance(String key, SourceProvenance provenance) {
    ComicSourceLibraryManager.setProvenance(key, provenance);
    notifyListeners();
  }

  void notifyStateChange() {
    notifyListeners();
  }
}

class ComicSource {
  static List<ComicSource> all() => ComicSourceManager().all();

  static ComicSource? find(String key) => ComicSourceManager().find(key);

  static ComicSource? fromIntKey(int key) =>
      ComicSourceManager().fromIntKey(key);

  static bool get isEmpty => ComicSourceManager().isEmpty;

  /// Name of this source.
  final String name;

  /// Identifier of this source.
  final String key;

  int get intKey {
    return key.hashCode;
  }

  /// Account config.
  final AccountConfig? account;

  /// Category data used to build a static category tags page.
  final CategoryData? categoryData;

  /// Category comics data used to build a comics page with a category tag.
  final CategoryComicsData? categoryComicsData;

  /// Favorite data used to build favorite page.
  final FavoriteData? favoriteData;

  /// Explore pages.
  final List<ExplorePageData> explorePages;

  /// Search page.
  final SearchPageData? searchPageData;

  /// Load comic info.
  final LoadComicFunc? loadComicInfo;

  final ComicThumbnailLoader? loadComicThumbnail;

  /// Load comic pages.
  final LoadComicPagesFunc? loadComicPages;

  final GetImageLoadingConfigFunc? getImageLoadingConfig;

  final Map<String, dynamic> Function(String imageKey)?
  getThumbnailLoadingConfig;

  var data = <String, dynamic>{};

  bool get isLogged => data["account"] != null;

  final String filePath;

  final String url;

  final String version;

  final CommentsLoader? commentsLoader;

  final SendCommentFunc? sendCommentFunc;

  final ChapterCommentsLoader? chapterCommentsLoader;

  final SendChapterCommentFunc? sendChapterCommentFunc;

  final RegExp? idMatcher;

  final LikeOrUnlikeComicFunc? likeOrUnlikeComic;

  final VoteCommentFunc? voteCommentFunc;

  final LikeCommentFunc? likeCommentFunc;

  final Map<String, Map<String, dynamic>>? settings;

  final Map<String, Map<String, String>>? translations;

  final HandleClickTagEvent? handleClickTagEvent;

  /// Callback when a tag suggestion is selected in search.
  final TagSuggestionSelectFunc? onTagSuggestionSelected;

  final LinkHandler? linkHandler;

  final bool enableTagsSuggestions;

  final bool enableTagsTranslate;

  final StarRatingFunc? starRatingFunc;

  final ArchiveDownloader? archiveDownloader;

  Future<void> loadData() async {
    var file = File("${App.dataPath}/comic_source/$key.data");
    if (await file.exists()) {
      data = Map.from(jsonDecode(await file.readAsString()));
    }
  }

  bool _isSaving = false;
  bool _haveWaitingTask = false;

  Future<void> saveData() async {
    if (_haveWaitingTask) return;
    while (_isSaving) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 20));
      _haveWaitingTask = false;
    }
    _isSaving = true;
    var file = File("${App.dataPath}/comic_source/$key.data");
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(data));
    _isSaving = false;
    DataSync().uploadData();
  }

  Future<bool> reLogin() async {
    if (data["account"] == null) {
      return false;
    }
    final List accountData = data["account"];
    var res = await account!.login!(accountData[0], accountData[1]);
    if (res.error) {
      Log.error("Failed to re-login", res.errorMessage ?? "Error");
    }
    return !res.error;
  }

  /// Get settings dynamically from JavaScript source.
  /// This allows sources to use getters for dynamic settings that can change at runtime.
  Map<String, Map<String, dynamic>>? getSettingsDynamic() {
    try {
      var value = JsEngine().runCode("ComicSource.sources.$key.settings");
      if (value is Map) {
        var newMap = <String, Map<String, dynamic>>{};
        for (var e in value.entries) {
          if (e.key is! String) {
            continue;
          }
          var v = <String, dynamic>{};
          for (var e2 in e.value.entries) {
            if (e2.key is! String) {
              continue;
            }
            var v2 = e2.value;
            if (v2 is JSInvokable) {
              v2 = JSAutoFreeFunction(v2);
            }
            v[e2.key] = v2;
          }
          newMap[e.key] = v;
        }
        return newMap;
      }
      return null;
    } catch (e) {
      Log.error("ComicSource", "Failed to get dynamic settings: $e");
      return settings;
    }
  }

  ComicSource(
    this.name,
    this.key,
    this.account,
    this.categoryData,
    this.categoryComicsData,
    this.favoriteData,
    this.explorePages,
    this.searchPageData,
    this.settings,
    this.loadComicInfo,
    this.loadComicThumbnail,
    this.loadComicPages,
    this.getImageLoadingConfig,
    this.getThumbnailLoadingConfig,
    this.filePath,
    this.url,
    this.version,
    this.commentsLoader,
    this.sendCommentFunc,
    this.chapterCommentsLoader,
    this.sendChapterCommentFunc,
    this.likeOrUnlikeComic,
    this.voteCommentFunc,
    this.likeCommentFunc,
    this.idMatcher,
    this.translations,
    this.handleClickTagEvent,
    this.onTagSuggestionSelected,
    this.linkHandler,
    this.enableTagsSuggestions,
    this.enableTagsTranslate,
    this.starRatingFunc,
    this.archiveDownloader,
  );
}

class AccountConfig {
  final LoginFunction? login;

  final String? loginWebsite;

  final String? registerWebsite;

  final void Function() logout;

  final List<AccountInfoItem> infoItems;

  final bool Function(String url, String title)? checkLoginStatus;

  final void Function()? onLoginWithWebviewSuccess;

  final List<String>? cookieFields;

  final Future<bool> Function(List<String>)? validateCookies;

  const AccountConfig(
    this.login,
    this.loginWebsite,
    this.registerWebsite,
    this.logout,
    this.checkLoginStatus,
    this.onLoginWithWebviewSuccess,
    this.cookieFields,
    this.validateCookies,
  ) : infoItems = const [];
}

class AccountInfoItem {
  final String title;
  final String Function()? data;
  final void Function()? onTap;
  final WidgetBuilder? builder;

  AccountInfoItem({required this.title, this.data, this.onTap, this.builder});
}

class LoadImageRequest {
  String url;

  Map<String, String> headers;

  LoadImageRequest(this.url, this.headers);
}

class ExplorePageData {
  final String title;

  final ExplorePageType type;

  final ComicListBuilder? loadPage;

  final ComicListBuilderWithNext? loadNext;

  final Future<Res<List<ExplorePagePart>>> Function()? loadMultiPart;

  /// return a `List` contains `List<Comic>` or `ExplorePagePart`
  final Future<Res<List<Object>>> Function(int index)? loadMixed;

  ExplorePageData(
    this.title,
    this.type,
    this.loadPage,
    this.loadNext,
    this.loadMultiPart,
    this.loadMixed,
  );
}

class ExplorePagePart {
  final String title;

  final List<Comic> comics;

  /// If this is not null, the [ExplorePagePart] will show a button to jump to new page.
  ///
  /// Value of this field should match the following format:
  ///   - search:keyword
  ///   - category:categoryName
  ///
  /// End with `@`+`param` if the category has a parameter.
  final PageJumpTarget? viewMore;

  const ExplorePagePart(this.title, this.comics, this.viewMore);
}

enum ExplorePageType {
  multiPageComicList,
  singlePageWithMultiPart,
  mixed,
  override,
}

typedef SearchFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      int page,
      List<String> searchOption,
    );

typedef SearchNextFunction =
    Future<Res<List<Comic>>> Function(
      String keyword,
      String? next,
      List<String> searchOption,
    );

class SearchPageData {
  /// If this is not null, the default value of search options will be first element.
  final List<SearchOptions>? searchOptions;

  final SearchFunction? loadPage;

  final SearchNextFunction? loadNext;

  const SearchPageData(this.searchOptions, this.loadPage, this.loadNext);
}

class SearchOptions {
  final LinkedHashMap<String, String> options;

  final String label;

  final String type;

  final String? defaultVal;

  const SearchOptions(this.options, this.label, this.type, this.defaultVal);

  String get defaultValue => defaultVal ?? options.keys.firstOrNull ?? "";
}

typedef CategoryComicsLoader =
    Future<Res<List<Comic>>> Function(
      String category,
      String? param,
      List<String> options,
      int page,
    );

typedef CategoryOptionsLoader =
    Future<Res<List<CategoryComicsOptions>>> Function(
      String category,
      String? param,
    );

class CategoryComicsData {
  /// options
  final List<CategoryComicsOptions>? options;

  final CategoryOptionsLoader? optionsLoader;

  /// [category] is the one clicked by the user on the category page.
  ///
  /// if [BaseCategoryPart.categoryParams] is not null, [param] will be not null.
  ///
  /// [Res.subData] should be maxPage or null if there is no limit.
  final CategoryComicsLoader load;

  final RankingData? rankingData;

  const CategoryComicsData({
    this.options,
    this.optionsLoader,
    required this.load,
    this.rankingData,
  });
}

class RankingData {
  final Map<String, String> options;

  final Future<Res<List<Comic>>> Function(String option, int page)? load;

  final Future<Res<List<Comic>>> Function(String option, String? next)?
  loadWithNext;

  const RankingData(this.options, this.load, this.loadWithNext);
}

class CategoryComicsOptions {
  // The label will not be displayed if it is empty.
  final String label;

  /// Use a [LinkedHashMap] to describe an option list.
  /// key is for loading comics, value is the name displayed on screen.
  /// Default value will be the first of the Map.
  final LinkedHashMap<String, String> options;

  /// If [notShowWhen] contains category's name, the option will not be shown.
  final List<String> notShowWhen;

  final List<String>? showWhen;

  const CategoryComicsOptions(
    this.label,
    this.options,
    this.notShowWhen,
    this.showWhen,
  );
}

class LinkHandler {
  final List<String> domains;

  final String? Function(String url) linkToId;

  const LinkHandler(this.domains, this.linkToId);
}

class ArchiveDownloader {
  final Future<Res<List<ArchiveInfo>>> Function(String cid) getArchives;

  final Future<Res<String>> Function(String cid, String aid) getDownloadUrl;

  const ArchiveDownloader(this.getArchives, this.getDownloadUrl);
}

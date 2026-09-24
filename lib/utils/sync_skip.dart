/// Which settings a device keeps out of WebDAV sync.
///
/// The stored `disableSyncFields` value is a comma-joined list of entries:
/// `@<id>` selects a whole [SyncSkipCategory], anything else is a raw settings
/// key. A selected category is written as its token followed by its current
/// keys, so an older install still honors the keys it knows, while this
/// version expands the token to keys added since. Pure logic, no app state.
library;

/// Stands for the search history list, which sits beside the settings map in
/// the synced snapshot rather than inside it.
const searchHistoryField = 'searchHistory';

/// A user-facing group of synced settings that can be kept on this device.
class SyncSkipCategory {
  const SyncSkipCategory(this.id, this.label, this.description, this.keys);

  /// Stored as `@id`. Never rename: saved selections refer to it.
  final String id;

  /// Translation key for the category name.
  final String label;

  /// Translation key for the one-line explanation.
  final String description;

  /// Settings keys the category covers. New keys can be added freely.
  final List<String> keys;

  String get token => '@$id';
}

/// Every setting that syncs belongs to one of these, to `Appdata._disableSync`
/// (always device-local), or to the short never-skippable list in
/// `test/sync_skip_test.dart`, which fails when a new setting is unclassified.
const syncSkipCategories = <SyncSkipCategory>[
  SyncSkipCategory(
    'appearance',
    "Appearance",
    "Theme, comic tiles, home layout and start page",
    [
      "color",
      "theme_mode",
      "comicDisplayMode",
      "comicTileScale",
      "initialPage",
      "homeSections",
      "imageFavoritesTabs",
      "comicCollectionDetailDisplayMode",
      "reading_statistics_sort",
    ],
  ),
  SyncSkipCategory(
    'reading',
    "Reading Options",
    "Reader mode, page turning, image enhancement and per-comic reader settings",
    [
      "readerMode",
      "enableContinuousChapterReading",
      "readerScreenPicNumberForLandscape",
      "readerScreenPicNumberForPortrait",
      "enableTapToTurnPages",
      "reverseTapToTurnPages",
      "enableCustomTapZones",
      "tapZoneTop",
      "tapZoneBottom",
      "tapZoneLeft",
      "tapZoneRight",
      "enablePageAnimation",
      "autoPageTurningInterval",
      "enableLongPressToZoom",
      "longPressZoomPosition",
      "enableTurnPageByVolumeKey",
      "enableClockAndBatteryInfoInReader",
      "showPageNumberInReader",
      "showSingleImageOnFirstPage",
      "enableDoubleTapToZoom",
      "reverseChapterOrder",
      "chapterOrderOverrides",
      "showSystemStatusBar",
      "readerScrollSpeed",
      "readerCenterPageOnTurn",
      "readerPageSpacing",
      "comicListDisplayMode",
      "galleryFillScreen",
      "autoFullscreenOnRead",
      "autoRemoveFromReadLater",
      "readerBackgroundColor",
      "readerNightModeFollowSystem",
      "readerNightModeColor",
      "readerNightModeIntensity",
      "enableReaderImageEnhance",
      "readerImageEnhanceStrength",
      "readerImageEnhanceClarity",
      "readerImageEnhanceContrast",
      "readerImageEnhanceVibrance",
      "enableCustomImageProcessing",
      "limitImageWidth",
      "imageWidthPercent",
      "preloadImageCount",
      "showChapterComments",
      "commentsFontSize",
      "showChapterCommentsAtEnd",
      "comicSpecificSettings",
      "deviceSpecificSettings",
    ],
  ),
  SyncSkipCategory(
    'translation',
    "AI Translation",
    "LLM providers and API keys, languages, prompt and text removal",
    [
      "imageTranslationProviders",
      "imageTranslationActiveProviderId",
      "imageTranslationPrompt",
      "imageTranslationSource",
      "imageTranslationTarget",
      "imageTranslationInpaintMode",
      "imageTranslationHfEndpoint",
      // Legacy single-provider keys, still read by the provider migration.
      "imageTranslationLlmUrl",
      "imageTranslationLlmKey",
      "imageTranslationLlmModel",
      "enableImageTranslation",
    ],
  ),
  SyncSkipCategory(
    'explore',
    "Explore",
    "Explore pages, categories, search options and content filters",
    [
      "explore_pages",
      "categories",
      "searchSources",
      "defaultSearchTarget",
      "autoAddLanguageFilter",
      "blockedWords",
      "blockedTags",
      "blockedCommentWords",
      "showFavoriteStatusOnTile",
      "showHistoryStatusOnTile",
      "showReadLaterStatusOnTile",
      "showCollectionStatusOnTile",
      "showPageCountOnTile",
    ],
  ),
  SyncSkipCategory(
    'searchHistory',
    "Search History",
    "Recent search keywords",
    [searchHistoryField],
  ),
  SyncSkipCategory(
    'favorites',
    "Favorites settings",
    "Network favorite pages, where new favorites go and quick-favorite options",
    [
      "favorites",
      "newFavoriteAddTo",
      "moveFavoriteAfterRead",
      "quickFavorite",
      "quickCollectImage",
      "autoFavoriteCover",
      "onClickFavorite",
      "localFavoritesFirst",
      "autoCloseFavoritePanel",
    ],
  ),
  SyncSkipCategory(
    'followUpdates',
    "Follow Updates",
    "Check interval, check on startup and scheduled check time",
    [
      "followUpdatesIntervalHours",
      "followUpdatesCheckOnStart",
      "followUpdatesFixedTime",
    ],
  ),
  SyncSkipCategory(
    'sources',
    "Comic Source list",
    "Source libraries, update origins and ordering",
    [
      "comicSourceLibraries",
      "comicSourceListUrl",
      "comicSourceLibrariesMigrated",
      "comicSourceOrigins",
      "comicSourceOrder",
    ],
  ),
  SyncSkipCategory(
    'webdavLibraries',
    "WebDAV Comic Library",
    "Library addresses and accounts",
    [
      "webdavComicLibraries",
      "webdavComicLibrary",
      "webdavComicLibrariesMigrated",
    ],
  ),
  SyncSkipCategory(
    'network',
    "Network & Downloads",
    "DNS overrides, SNI, certificate check, sync proxy and download options",
    [
      "enableDnsOverrides",
      "dnsOverrides",
      "sni",
      "ignoreBadCertificate",
      "webdavUseProxy",
      "downloadThreads",
      "maxParallelDownloads",
      "downloadWifiOnly",
    ],
  ),
  SyncSkipCategory(
    'app',
    "App",
    "Language, cache limit, update check, tray and history auto-clean",
    [
      "language",
      "cacheSize",
      "checkUpdateOnStart",
      "minimizeToTray",
      "autoCleanHistoryDays",
    ],
  ),
];

/// Selections saved before category tokens existed held a category's full key
/// list. These keys, in their category since the picker first shipped, still
/// identify such a selection. Frozen: don't edit when a category's keys change.
const _legacySignatures = <String, List<String>>{
  'appearance': ["color", "theme_mode", "comicDisplayMode", "comicTileScale"],
  'reading': [
    "readerMode",
    "enableTapToTurnPages",
    "readerBackgroundColor",
    "preloadImageCount",
    "showChapterCommentsAtEnd",
  ],
  'explore': [
    "explore_pages",
    "categories",
    "searchSources",
    "blockedWords",
    "showReadLaterStatusOnTile",
  ],
  'favorites': [
    "favorites",
    "newFavoriteAddTo",
    "quickFavorite",
    "autoCloseFavoritePanel",
  ],
  'sources': ["comicSourceLibraries", "comicSourceListUrl"],
};

class SyncSkipSelection {
  const SyncSkipSelection._(this._categoryIds, this._fields);

  factory SyncSkipSelection.parse(String stored) =>
      SyncSkipSelection.fromEntries(stored.split(','));

  factory SyncSkipSelection.fromEntries(Iterable<String> entries) {
    final ids = <String>{};
    final fields = <String>{};
    for (final raw in entries) {
      final entry = raw.trim();
      if (entry.isEmpty) continue;
      if (entry.startsWith('@') && _category(entry.substring(1)) != null) {
        ids.add(entry.substring(1));
      } else {
        // Raw keys, plus tokens from a newer version, kept so a round trip
        // through this version doesn't drop them.
        fields.add(entry);
      }
    }
    _legacySignatures.forEach((id, signature) {
      if (signature.every(fields.contains)) ids.add(id);
    });
    for (final id in ids) {
      fields.removeAll(_category(id)!.keys);
    }
    return SyncSkipSelection._(ids, fields);
  }

  final Set<String> _categoryIds;

  /// Entries no selected category covers.
  final Set<String> _fields;

  static SyncSkipCategory? _category(String id) {
    for (final c in syncSkipCategories) {
      if (c.id == id) return c;
    }
    return null;
  }

  bool isSelected(SyncSkipCategory category) =>
      _categoryIds.contains(category.id);

  /// Some, but not all, of the category's keys are skipped — only reachable
  /// through keys typed into the old free-text field.
  bool isPartial(SyncSkipCategory category) =>
      !isSelected(category) && category.keys.any(_fields.contains);

  /// Raw keys outside every category.
  List<String> get otherFields => [
    for (final f in _fields)
      if (!f.startsWith('@') &&
          !syncSkipCategories.any((c) => c.keys.contains(f)))
        f,
  ];

  /// What the sync layer leaves out, in both directions.
  Set<String> get skippedFields => {
    for (final c in syncSkipCategories)
      if (isSelected(c)) ...c.keys,
    ..._fields,
  };

  SyncSkipSelection withCategory(SyncSkipCategory category, bool skip) {
    final ids = {..._categoryIds};
    final fields = {..._fields}
      ..removeAll(category.keys)
      ..removeAll(_legacySignatures[category.id] ?? const []);
    if (skip) {
      ids.add(category.id);
    } else {
      ids.remove(category.id);
    }
    return SyncSkipSelection._(ids, fields);
  }

  SyncSkipSelection withAll(bool skip) {
    var next = this;
    for (final c in syncSkipCategories) {
      next = next.withCategory(c, skip);
    }
    return next;
  }

  SyncSkipSelection withoutOtherFields() {
    final other = otherFields.toSet();
    return SyncSkipSelection._(
      {..._categoryIds},
      _fields.where((f) => !other.contains(f)).toSet(),
    );
  }

  String serialize() => [
    for (final c in syncSkipCategories)
      if (isSelected(c)) ...[c.token, ...c.keys],
    ..._fields,
  ].join(', ');
}

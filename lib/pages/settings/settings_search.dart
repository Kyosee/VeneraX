part of 'settings_page.dart';

/// Searchable index of all settings (issue #75).
///
/// IMPORTANT: this list mirrors the settings rendered by the category pages
/// (explore_settings.dart, reader.dart, local_favorites.dart, data_sync.dart,
/// app.dart, network.dart, about.dart, debug.dart). When you add, rename, or
/// remove a setting on those pages, update the matching entry here so it stays
/// searchable.
///
/// Titles reuse the exact English source strings the pages pass to `.tl`, so a
/// single entry localizes automatically in every locale. `category` indexes
/// into [_settingsCategories] / [_settingsCategoryIcons]; tapping a result opens
/// that category page (rendering the real tiles inline isn't viable — they are
/// nested in expansion tiles, gated by platform/state conditions, and coupled to
/// each page's own `setState`).
class _SettingsSearchEntry {
  const _SettingsSearchEntry(
    this.title,
    this.category, {
    this.keywords = const [],
    this.visible,
  });

  /// English source string, identical to the one the page passes to `.tl`.
  final String title;

  /// Index into [_settingsCategories] / [_settingsCategoryIcons].
  final int category;

  /// Extra English match terms / synonyms beyond the localized title.
  final List<String> keywords;

  /// Optional availability guard, mirroring the page's own conditional so a
  /// result never points at a setting the current platform doesn't show.
  final bool Function()? visible;
}

/// The full index. Built once; `visible` guards are evaluated lazily at match
/// time so this is safe to construct before [App] is initialized.
final _settingsSearchIndex = <_SettingsSearchEntry>[
  // --- 4: Explore ---
  _SettingsSearchEntry("Display mode of comic tile", 4),
  _SettingsSearchEntry("Size of comic tile", 4),
  _SettingsSearchEntry("Explore Pages", 4),
  _SettingsSearchEntry("Category Pages", 4),
  _SettingsSearchEntry("Network Favorite Pages", 4),
  _SettingsSearchEntry("Search Sources", 4),
  _SettingsSearchEntry("Show favorite status on comic tile", 4),
  _SettingsSearchEntry("Show history on comic tile", 4),
  _SettingsSearchEntry("Show read later status on comic tile", 4),
  _SettingsSearchEntry("Reverse default chapter order", 4),
  _SettingsSearchEntry("Keyword blocking", 4, keywords: ["block", "filter"]),
  _SettingsSearchEntry("Tag blocking", 4, keywords: ["block", "filter", "tag"]),
  _SettingsSearchEntry("Comment keyword blocking", 4, keywords: ["block"]),
  _SettingsSearchEntry("Default Search Target", 4, keywords: ["search"]),
  _SettingsSearchEntry("Auto Language Filters", 4, keywords: ["language"]),
  _SettingsSearchEntry("Initial Page", 4),
  _SettingsSearchEntry("Display mode of comic list", 4),

  // --- 1: Reading settings ---
  _SettingsSearchEntry(
    "Enable device specific settings",
    1,
    keywords: ["device"],
  ),
  _SettingsSearchEntry("Page turn mode", 1, keywords: ["tap"]),
  _SettingsSearchEntry("Page animation", 1),
  _SettingsSearchEntry("Reading mode", 1, keywords: ["gallery", "continuous"]),
  _SettingsSearchEntry("Seamless chapter reading", 1),
  _SettingsSearchEntry(
    "The number of pic in screen for landscape (Only Gallery Mode)",
    1,
  ),
  _SettingsSearchEntry(
    "The number of pic in screen for portrait (Only Gallery Mode)",
    1,
  ),
  _SettingsSearchEntry("Show single image on first page", 1),
  _SettingsSearchEntry("Fill screen", 1),
  _SettingsSearchEntry("Reading background color", 1, keywords: ["background"]),
  _SettingsSearchEntry("Night mode", 1, keywords: ["dark", "eye"]),
  _SettingsSearchEntry("Follow system dark mode", 1, keywords: ["dark"]),
  _SettingsSearchEntry("Night mode color", 1, keywords: ["dark"]),
  _SettingsSearchEntry("Night mode intensity", 1, keywords: ["dark"]),
  _SettingsSearchEntry("Auto page turning interval", 1, keywords: ["auto"]),
  _SettingsSearchEntry("Mouse scroll speed", 1, keywords: ["scroll"]),
  _SettingsSearchEntry("Number of images preloaded", 1, keywords: ["preload"]),
  _SettingsSearchEntry("Double tap to zoom", 1, keywords: ["gesture", "zoom"]),
  _SettingsSearchEntry("Long press to zoom", 1, keywords: ["gesture", "zoom"]),
  _SettingsSearchEntry("Long press zoom position", 1, keywords: ["zoom"]),
  _SettingsSearchEntry(
    "Turn page by volume keys",
    1,
    keywords: ["volume", "gesture"],
    visible: () => App.isAndroid,
  ),
  _SettingsSearchEntry("Also collect chapter cover when collecting image", 1),
  _SettingsSearchEntry("Quick collect image", 1),
  _SettingsSearchEntry("Limit image width", 1),
  _SettingsSearchEntry(
    "Custom Image Processing",
    1,
    keywords: ["script", "process"],
  ),
  _SettingsSearchEntry(
    "Image enhancement",
    1,
    keywords: ["sharpen", "enhance"],
  ),
  _SettingsSearchEntry("Sharpen strength", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Clarity", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Contrast", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Color vibrance", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Display time & battery info in reader", 1),
  _SettingsSearchEntry("Show system status bar", 1),
  _SettingsSearchEntry("Show Page Number", 1),
  _SettingsSearchEntry("Show Chapter Comments", 1, keywords: ["comment"]),
  _SettingsSearchEntry(
    "Show Comments at Chapter End",
    1,
    keywords: ["comment"],
  ),
  _SettingsSearchEntry(
    "AI Translation (experimental)",
    1,
    keywords: ["LLM", "OCR", "translate"],
  ),
  _SettingsSearchEntry("LLM providers", 1, keywords: ["API", "model"]),
  _SettingsSearchEntry("Performance mode", 1, keywords: ["speed", "mobile"]),
  _SettingsSearchEntry("Text removal", 1, keywords: ["erase", "inpaint"]),
  _SettingsSearchEntry("Translation models", 1, keywords: ["OCR", "download"]),

  // --- 0: App / Appearance ---
  _SettingsSearchEntry("Theme Mode", 0, keywords: ["dark", "light"]),
  _SettingsSearchEntry("Theme Color", 0, keywords: ["accent", "color"]),
  _SettingsSearchEntry(
    "Predictive Back Animation",
    0,
    keywords: ["back", "gesture", "animation"],
    visible: () => App.isAndroid,
  ),
  _SettingsSearchEntry("Home Page Layout", 0, keywords: ["home", "layout"]),
  _SettingsSearchEntry("Image Favorites Tabs", 0, keywords: ["tabs"]),
  _SettingsSearchEntry(
    "App Icon",
    0,
    keywords: ["launcher", "icon"],
    visible: () => LauncherIconService.isSupported,
  ),

  // --- 2: Local Favorites ---
  _SettingsSearchEntry("Show local favorites before network favorites", 2),
  _SettingsSearchEntry("Auto close favorite panel after operation", 2),
  _SettingsSearchEntry("Add new favorite to", 2),
  _SettingsSearchEntry("Move favorite after reading", 2),
  _SettingsSearchEntry("Quick Favorite", 2),
  _SettingsSearchEntry("Delete all unavailable local favorite items", 2),
  _SettingsSearchEntry("Click favorite", 2),

  // --- 3: Data & Sync ---
  _SettingsSearchEntry("Storage Path for local comics", 3, keywords: ["path"]),
  _SettingsSearchEntry("Set New Storage Path", 3, keywords: ["path"]),
  _SettingsSearchEntry("Cache Size", 3, keywords: ["cache"]),
  _SettingsSearchEntry("Clear Cache", 3, keywords: ["cache"]),
  _SettingsSearchEntry("Cache Limit", 3, keywords: ["cache"]),
  _SettingsSearchEntry("Auto clean reading history", 3),
  _SettingsSearchEntry("Export App Data", 3, keywords: ["backup", "export"]),
  _SettingsSearchEntry("Import App Data", 3, keywords: ["restore", "import"]),
  _SettingsSearchEntry(
    "Data Sync",
    3,
    keywords: ["webdav", "backup", "sync", "cloud"],
  ),
  _SettingsSearchEntry("Sync Logs", 3, keywords: ["webdav", "log"]),
  _SettingsSearchEntry(
    "WebDAV Comic Library",
    3,
    keywords: ["webdav", "library", "comic", "remote", "nas", "cloud"],
  ),

  // --- 0: App ---
  _SettingsSearchEntry("Language", 0, keywords: ["locale", "language"]),
  _SettingsSearchEntry(
    "Authorization Required",
    0,
    keywords: ["password", "lock", "biometric", "fingerprint", "privacy"],
    visible: () => !App.isLinux,
  ),
  _SettingsSearchEntry(
    "Minimize to tray",
    0,
    keywords: ["tray", "window"],
    visible: () => App.isWindows,
  ),

  // --- 5: Network ---
  _SettingsSearchEntry("Proxy", 5, keywords: ["vpn", "socks", "http"]),
  _SettingsSearchEntry("DNS Overrides", 5, keywords: ["dns", "hosts", "sni"]),
  _SettingsSearchEntry("Download Threads", 5, keywords: ["download"]),
  _SettingsSearchEntry("Parallel Downloads", 5, keywords: ["download"]),
  _SettingsSearchEntry(
    "Download on WiFi Only",
    5,
    keywords: ["wifi", "wlan", "download", "data"],
  ),

  // --- 7: About ---
  _SettingsSearchEntry("Check for updates", 7, keywords: ["update", "version"]),
  _SettingsSearchEntry("Check for updates on startup", 7, keywords: ["update"]),
  _SettingsSearchEntry(
    "Guide",
    7,
    keywords: ["guide", "help", "manual", "how to", "usage"],
  ),
  _SettingsSearchEntry("Repository", 7, keywords: ["github", "source"]),
  _SettingsSearchEntry("User Agreement & Disclaimer", 7),

  // --- 6: Debug ---
  _SettingsSearchEntry("Reload Configs", 6),
  _SettingsSearchEntry("Open Log", 6, keywords: ["log", "logs"]),
  _SettingsSearchEntry(
    "Ignore Certificate Errors",
    6,
    keywords: ["ssl", "tls"],
  ),
  _SettingsSearchEntry(
    "JS Evaluator",
    6,
    keywords: ["javascript", "js", "eval"],
  ),
];

/// Returns the entries matching [query] (case-insensitive substring over the
/// localized title, the English source, the category name, and keywords).
List<_SettingsSearchEntry> _matchSettingsSearch(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final result = <_SettingsSearchEntry>[];
  for (final e in _settingsSearchIndex) {
    if (e.visible != null && !e.visible!()) continue;
    if (_settingsEntryMatches(e, q)) result.add(e);
  }
  return result;
}

bool _settingsEntryMatches(_SettingsSearchEntry e, String q) {
  if (e.title.toLowerCase().contains(q)) return true;
  if (e.title.tl.toLowerCase().contains(q)) return true;
  final catName = _settingsCategories[e.category];
  if (catName.toLowerCase().contains(q) ||
      catName.tl.toLowerCase().contains(q)) {
    return true;
  }
  for (final k in e.keywords) {
    if (k.toLowerCase().contains(q) || k.tl.toLowerCase().contains(q)) {
      return true;
    }
  }
  return false;
}

/// Builds the search results list shown in place of the category list while a
/// query is active. [onOpen] receives the tapped entry's category index.
Widget _buildSettingsSearchResults(
  BuildContext context,
  String query,
  void Function(int category) onOpen,
) {
  final results = _matchSettingsSearch(query);
  if (results.isEmpty) {
    return Center(
      child: Text("No matching settings".tl, style: ts.s14),
    ).paddingTop(32);
  }
  return ListView.builder(
    padding: EdgeInsets.zero,
    itemCount: results.length,
    itemBuilder: (context, index) {
      final e = results[index];
      return ListTile(
        leading: Icon(_settingsCategoryIcons[e.category]),
        title: Text(e.title.tl),
        subtitle: Text(_settingsCategories[e.category].tl),
        onTap: () => onOpen(e.category),
      );
    },
  );
}

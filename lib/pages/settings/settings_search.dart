part of 'settings_page.dart';

/// Searchable index of all settings (issue #75).
///
/// IMPORTANT: this list mirrors the settings rendered by the category pages
/// (explore_settings.dart, reader.dart, appearance.dart, local_favorites.dart,
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
  // --- 0: Explore ---
  _SettingsSearchEntry("Display mode of comic tile", 0),
  _SettingsSearchEntry("Size of comic tile", 0),
  _SettingsSearchEntry("Explore Pages", 0),
  _SettingsSearchEntry("Category Pages", 0),
  _SettingsSearchEntry("Network Favorite Pages", 0),
  _SettingsSearchEntry("Search Sources", 0),
  _SettingsSearchEntry("Show favorite status on comic tile", 0),
  _SettingsSearchEntry("Show history on comic tile", 0),
  _SettingsSearchEntry("Show read later status on comic tile", 0),
  _SettingsSearchEntry("Reverse default chapter order", 0),
  _SettingsSearchEntry("Keyword blocking", 0, keywords: ["block", "filter"]),
  _SettingsSearchEntry("Comment keyword blocking", 0, keywords: ["block"]),
  _SettingsSearchEntry("Default Search Target", 0, keywords: ["search"]),
  _SettingsSearchEntry("Auto Language Filters", 0, keywords: ["language"]),
  _SettingsSearchEntry("Initial Page", 0),
  _SettingsSearchEntry("Display mode of comic list", 0),

  // --- 1: Reading ---
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
  _SettingsSearchEntry("Image enhancement", 1, keywords: ["sharpen", "enhance"]),
  _SettingsSearchEntry("Sharpen strength", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Clarity", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Contrast", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Color vibrance", 1, keywords: ["enhance"]),
  _SettingsSearchEntry("Display time & battery info in reader", 1),
  _SettingsSearchEntry("Show system status bar", 1),
  _SettingsSearchEntry("Show Page Number", 1),
  _SettingsSearchEntry("Show Chapter Comments", 1, keywords: ["comment"]),
  _SettingsSearchEntry("Show Comments at Chapter End", 1, keywords: ["comment"]),

  // --- 2: Appearance ---
  _SettingsSearchEntry("Theme Mode", 2, keywords: ["dark", "light"]),
  _SettingsSearchEntry("Theme Color", 2, keywords: ["accent", "color"]),
  _SettingsSearchEntry("Home Page Layout", 2, keywords: ["home", "layout"]),
  _SettingsSearchEntry("Image Favorites Tabs", 2, keywords: ["tabs"]),

  // --- 3: Local Favorites ---
  _SettingsSearchEntry("Show local favorites before network favorites", 3),
  _SettingsSearchEntry("Auto close favorite panel after operation", 3),
  _SettingsSearchEntry("Add new favorite to", 3),
  _SettingsSearchEntry("Move favorite after reading", 3),
  _SettingsSearchEntry("Quick Favorite", 3),
  _SettingsSearchEntry("Delete all unavailable local favorite items", 3),
  _SettingsSearchEntry("Click favorite", 3),

  // --- 4: APP ---
  _SettingsSearchEntry("Storage Path for local comics", 4, keywords: ["path"]),
  _SettingsSearchEntry("Set New Storage Path", 4, keywords: ["path"]),
  _SettingsSearchEntry("Cache Size", 4, keywords: ["cache"]),
  _SettingsSearchEntry("Clear Cache", 4, keywords: ["cache"]),
  _SettingsSearchEntry("Cache Limit", 4, keywords: ["cache"]),
  _SettingsSearchEntry("Export App Data", 4, keywords: ["backup", "export"]),
  _SettingsSearchEntry("Import App Data", 4, keywords: ["restore", "import"]),
  _SettingsSearchEntry(
    "Data Sync",
    4,
    keywords: ["webdav", "backup", "sync", "cloud"],
  ),
  _SettingsSearchEntry("Sync Logs", 4, keywords: ["webdav", "log"]),
  _SettingsSearchEntry(
    "WebDAV Comic Library",
    4,
    keywords: ["webdav", "library", "comic", "remote", "nas", "cloud"],
  ),
  _SettingsSearchEntry("Language", 4, keywords: ["locale", "language"]),
  _SettingsSearchEntry(
    "Authorization Required",
    4,
    keywords: ["password", "lock", "biometric", "fingerprint", "privacy"],
    visible: () => !App.isLinux,
  ),
  _SettingsSearchEntry(
    "Minimize to tray",
    4,
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

  // --- 6: About ---
  _SettingsSearchEntry(
    "Check for updates",
    6,
    keywords: ["update", "version"],
  ),
  _SettingsSearchEntry("Check for updates on startup", 6, keywords: ["update"]),
  _SettingsSearchEntry("Repository", 6, keywords: ["github", "source"]),
  _SettingsSearchEntry("User Agreement & Disclaimer", 6),

  // --- 7: Debug ---
  _SettingsSearchEntry("Reload Configs", 7),
  _SettingsSearchEntry("Open Log", 7, keywords: ["log", "logs"]),
  _SettingsSearchEntry("Ignore Certificate Errors", 7, keywords: ["ssl", "tls"]),
  _SettingsSearchEntry(
    "JS Evaluator",
    7,
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
  if (catName.toLowerCase().contains(q) || catName.tl.toLowerCase().contains(q)) {
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

import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/auto_page_turning.dart';
import 'package:venera/foundation/battery_optimization.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/download_network_guard.dart';
import 'package:venera/foundation/eink_screen.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/image_enhance_shader.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/script_translator.dart';
import 'package:venera/foundation/image_translation/pre_translation_tasks.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/image_translation/translation_sources.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/image_translation/translation_targets.dart';
import 'package:venera/foundation/import_tasks.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/launcher_icon.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/shortcuts.dart';
import 'package:venera/foundation/tray.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/pages/app_lock_setup.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/guide_page.dart';
import 'package:venera/pages/settings/image_enhance_preview.dart';
import 'package:venera/pages/settings/sync_config_qr.dart';
import 'package:venera/pages/webdav_libraries_page.dart';
import 'package:venera/utils/app_lock.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/platform_abi.dart';
import 'package:venera/utils/sync_config_transfer.dart';
import 'package:venera/utils/sync_skip.dart';
import 'package:venera/utils/translations.dart';

part 'reader.dart';
part 'translation_models_settings.dart';
part 'llm_providers_settings.dart';
part 'translation_script_settings.dart';
part 'translation_prompt_settings.dart';
part 'translation_languages_settings.dart';
part 'explore_settings.dart';
part 'setting_components.dart';
part 'launcher_icon_settings.dart';
part 'keyboard_shortcuts_settings.dart';
part 'home_layout.dart';
part 'local_favorites.dart';
part 'app.dart';
part 'data_sync.dart';
part 'cache_directory_settings.dart';
part 'about.dart';
part 'network.dart';
part 'debug.dart';
part 'settings_search.dart';
part 'settings_scope.dart';
part 'settings_focus.dart';
part 'settings_layout.dart';

// Keep the original numeric destinations for existing callers and search.
const _settingsCategories = <String>[
  'Appearance & layout',
  'Reading settings',
  'Library & favorites',
  'Sync & backup',
  'Browsing & filters',
  'Network',
  'Debug',
  'About & help',
  'AI Translation',
  'Downloads & storage',
  'Privacy & device',
];
const _settingsCategoryIcons = <IconData>[
  Icons.palette_outlined,
  Icons.menu_book_outlined,
  Icons.favorite_border,
  Icons.cloud_outlined,
  Icons.explore_outlined,
  Icons.public,
  Icons.bug_report_outlined,
  Icons.info_outline,
  Icons.translate,
  Icons.download_outlined,
  Icons.shield_outlined,
];
const _settingsDescriptions = [
  'Theme, language and home layout',
  'Page layout, gestures and reading display',
  'Favorite folders and collection behavior',
  'WebDAV, automatic backups and data transfer',
  'Comic lists, sources and content filters',
  'Proxy and DNS connections',
  'Logs and troubleshooting tools',
  'Version, updates and help',
  'Translation services, languages, models and performance',
  'Downloads, folders and cache',
  'App lock, background behavior and shortcuts',
];
const _settingsClusters = <(String, List<int>)>[
  ('Reading experience', [0, 1, 8]),
  ('Content & data', [2, 4, 9, 3]),
  ('More', [5, 10, 7]),
];

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.initialPage = -1, super.key});
  final int initialPage;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int currentPage = -1;
  String? _focusTitle;
  String? _focusFallback;
  int _destinationVersion = 0;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  String _searchQuery = '';
  bool enableTwoViews = false;
  ColorScheme get colors => context.colorScheme;

  @override
  void initState() {
    super.initState();
    currentPage =
        widget.initialPage >= 0 &&
            widget.initialPage < _settingsCategories.length
        ? widget.initialPage
        : -1;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      // Use the pane width for foldables and constrained windows.
      enableTwoViews = constraints.maxWidth > 600;
      if (enableTwoViews && currentPage == -1) currentPage = 1;
      return buildSettings();
    },
  );

  Widget buildSettings() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyK, control: true):
          _searchFocus.requestFocus,
      const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
          _searchFocus.requestFocus,
    },
    child: Material(
      color: colors.surface,
      child: enableTwoViews
          ? Row(
              children: [
                SizedBox(width: 232, child: buildLeft()),
                VerticalDivider(
                  width: 1,
                  thickness: 0.7,
                  color: colors.outlineVariant,
                ),
                Expanded(
                  child: Column(
                    children: [
                      SafeArea(bottom: false, child: buildSearchField()),
                      Expanded(
                        child: _searchQuery.trim().isEmpty
                            ? buildRight()
                            : _buildSettingsSearchResults(
                                context,
                                _searchQuery,
                                _openSettingsResult,
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : buildLeft(),
    ),
  );

  Widget buildSearchField() => Padding(
    padding: EdgeInsets.fromLTRB(
      enableTwoViews ? 32 : 20,
      enableTwoViews ? 12 : 4,
      enableTwoViews ? 32 : 20,
      enableTwoViews ? 12 : 0,
    ),
    child: TextField(
      controller: _searchController,
      focusNode: _searchFocus,
      style: const TextStyle(fontSize: 14),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search settings'.tl,
        prefixIcon: const Icon(Icons.search, size: 20),
        filled: true,
        fillColor: enableTwoViews
            ? colors.surfaceContainerLow
            : colors.surfaceContainerHighest,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        suffixIcon: _searchQuery.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear'.tl,
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              ),
      ),
      onChanged: (value) => setState(() => _searchQuery = value),
    ),
  );

  Widget buildLeft() => Material(
    color: colors.surfaceContainerLow,
    child: SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              8,
              enableTwoViews ? 8 : 0,
              16,
              enableTwoViews ? 8 : 0,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back'.tl,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: context.pop,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Settings'.tl,
                    style: TextStyle(
                      fontSize: enableTwoViews ? 22 : 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (!enableTwoViews) buildSearchField(),
          Expanded(
            child: !enableTwoViews && _searchQuery.trim().isNotEmpty
                ? _buildSettingsSearchResults(
                    context,
                    _searchQuery,
                    _openSettingsResult,
                  )
                : buildCategories(),
          ),
        ],
      ),
    ),
  );

  Widget buildCategories() => SingleChildScrollView(
    padding: EdgeInsets.fromLTRB(
      enableTwoViews ? 12 : 20,
      0,
      enableTwoViews ? 12 : 20,
      24,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (title, ids) in _settingsClusters) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
              8,
              !enableTwoViews && title == _settingsClusters.first.$1 ? 8 : 20,
              8,
              9,
            ),
            child: Text(
              title.tl,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
          Material(
            color: enableTwoViews ? Colors.transparent : colors.surface,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < ids.length; i++) ...[
                  if (!enableTwoViews && i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.6,
                      indent: 48,
                      color: colors.outlineVariant,
                    ),
                  _categoryTile(ids[i]),
                ],
              ],
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 28, 8, 8),
          child: Text(
            'Venera ${App.version}',
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
        ),
      ],
    ),
  );

  Widget _categoryTile(int id) {
    final selected =
        enableTwoViews && id == (currentPage == 6 ? 7 : currentPage);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: enableTwoViews ? 2 : 0),
      child: ListTile(
        key: ValueKey('settings-category-$id'),
        dense: enableTwoViews,
        minTileHeight: enableTwoViews ? 44 : 68,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        selected: selected,
        selectedTileColor: colors.primaryContainer.withValues(alpha: 0.45),
        leading: Icon(_settingsCategoryIcons[id], size: 21),
        minLeadingWidth: 21,
        horizontalTitleGap: 11,
        title: Text(
          _settingsCategories[id].tl,
          style: const TextStyle(fontSize: 14),
        ),
        subtitle: enableTwoViews
            ? null
            : Text(
                _settingsDescriptions[id].tl,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
        trailing: enableTwoViews
            ? null
            : const Icon(Icons.chevron_right, size: 18),
        onTap: () => _openSettingsCategory(id),
      ),
    );
  }

  void _clearSearch() {
    _searchController.clear();
    _searchFocus.unfocus();
    _searchQuery = '';
  }

  void _openSettingsCategory(int id) {
    if (enableTwoViews) {
      setState(() {
        _clearSearch();
        currentPage = id;
        _focusTitle = null;
        _focusFallback = null;
        _destinationVersion++;
      });
    } else {
      context.to(() => _SettingsDetailPage(pageIndex: id));
    }
  }

  void _openSettingsResult(_SettingsSearchEntry entry) {
    if (enableTwoViews) {
      setState(() {
        _clearSearch();
        currentPage = entry.category;
        _focusTitle = entry.targetTitle;
        _focusFallback = entry.fallbackTitle;
        _destinationVersion++;
      });
    } else {
      _searchFocus.unfocus();
      context.to(
        () => _SettingsDetailPage(
          pageIndex: entry.category,
          focusTitle: entry.targetTitle,
          fallbackTitle: entry.fallbackTitle,
        ),
      );
    }
  }

  Widget buildRight() => Navigator(
    key: ValueKey('$currentPage:$_destinationVersion'),
    onGenerateRoute: (settings) => PageRouteBuilder(
      pageBuilder: (context, animation, secondaryAnimation) =>
          _SettingsDetailPage(
            pageIndex: currentPage,
            focusTitle: _focusTitle,
            fallbackTitle: _focusFallback,
          ),
      transitionDuration: Duration.zero,
    ),
  );
}

class _SettingsDetailPage extends StatelessWidget {
  const _SettingsDetailPage({
    required this.pageIndex,
    this.focusTitle,
    this.fallbackTitle,
  });

  final int pageIndex;
  final String? focusTitle;
  final String? fallbackTitle;

  @override
  Widget build(BuildContext context) {
    final page = _buildPage();
    return Material(
      child: focusTitle == null
          ? page
          : _SettingsDestination(
              title: focusTitle!,
              fallback: fallbackTitle,
              child: page,
            ),
    );
  }

  Widget _buildPage() {
    return switch (pageIndex) {
      0 => const AppSettings(),
      1 => const ReaderSettings(),
      2 => const LocalFavoritesSettings(),
      3 => const DataSyncSettings(),
      4 => const ExploreSettings(),
      5 => const NetworkSettings(),
      6 => const DebugPage(),
      7 => const AboutSettings(),
      8 => const ReaderSettings(translationOnly: true),
      9 => const DataSyncSettings(storageOnly: true),
      10 => const AppSettings(deviceOnly: true),
      _ => throw UnimplementedError(),
    };
  }
}

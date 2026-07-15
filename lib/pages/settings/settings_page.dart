import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/battery_optimization.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/download_network_guard.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/image_enhance_shader.dart';
import 'package:venera/foundation/import_tasks.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/launcher_icon.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/tray.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/pages/app_lock_setup.dart';
import 'package:venera/pages/disclaimer.dart';
import 'package:venera/pages/settings/sync_config_qr.dart';
import 'package:venera/utils/app_lock.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/platform_abi.dart';
import 'package:venera/utils/sync_config_transfer.dart';
import 'package:venera/utils/translations.dart';

part 'reader.dart';
part 'explore_settings.dart';
part 'setting_components.dart';
part 'appearance.dart';
part 'launcher_icon_settings.dart';
part 'home_layout.dart';
part 'local_favorites.dart';
part 'app.dart';
part 'about.dart';
part 'network.dart';
part 'debug.dart';
part 'settings_search.dart';

/// Settings category display names, indexed by page id. Top-level so the
/// settings search index ([_settingsSearchIndex]) can map a result back to its
/// category page. Keep in sync with [_settingsCategoryIcons] and the page
/// switch in [_SettingsPageState._buildSettingsContent].
const _settingsCategories = <String>[
  "Explore",
  "Reading",
  "Appearance",
  "Local Favorites",
  "APP",
  "Network",
  "About",
  "Debug",
];

const _settingsCategoryIcons = <IconData>[
  Icons.explore,
  Icons.book,
  Icons.color_lens,
  Icons.collections_bookmark_rounded,
  Icons.apps,
  Icons.public,
  Icons.info,
  Icons.bug_report,
];

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.initialPage = -1, super.key});

  final int initialPage;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int currentPage = -1;

  ColorScheme get colors => Theme.of(context).colorScheme;

  bool get enableTwoViews => context.width > 720;

  final _searchController = TextEditingController();

  String _searchQuery = "";

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    currentPage = widget.initialPage;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Material(child: buildBody());
  }

  Widget buildBody() {
    if (enableTwoViews) {
      return Row(
        children: [
          SizedBox(width: 280, height: double.infinity, child: buildLeft()),
          Container(
            height: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) {
                return LayoutBuilder(
                  builder: (context, constrains) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, _) {
                        var width = constrains.maxWidth;
                        var value = animation.isForwardOrCompleted
                            ? 1 - animation.value
                            : 1;
                        var left = width * value;
                        return Stack(
                          children: [
                            Positioned(
                              top: 0,
                              bottom: 0,
                              left: left,
                              width: width,
                              child: child,
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
              child: buildRight(),
            ),
          ),
        ],
      );
    } else {
      return buildLeft();
    }
  }

  Widget buildLeft() {
    return Material(
      child: Column(
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top),
          SizedBox(
            height: 56,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Tooltip(
                  message: "Back",
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: context.pop,
                  ),
                ),
                const SizedBox(width: 24),
                Text("Settings".tl, style: ts.s20),
              ],
            ),
          ),
          const SizedBox(height: 4),
          buildSearchField(),
          Expanded(
            child: _searchQuery.trim().isEmpty
                ? buildCategories()
                : _buildSettingsSearchResults(
                    context,
                    _searchQuery,
                    _openSettingsCategory,
                  ),
          ),
        ],
      ),
    );
  }

  Widget buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          isDense: true,
          hintText: "Search settings".tl,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = "");
                  },
                ),
          border: const OutlineInputBorder(),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  void _openSettingsCategory(int id) {
    if (enableTwoViews) {
      setState(() => currentPage = id);
    } else {
      context.to(() => _SettingsDetailPage(pageIndex: id));
    }
  }

  Widget buildCategories() {
    Widget buildItem(String name, int id) {
      final bool selected = id == currentPage;

      Widget content = AnimatedContainer(
        key: ValueKey(id),
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 46,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        decoration: BoxDecoration(
          color: selected ? colors.primaryContainer.toOpacity(0.36) : null,
          border: Border(
            left: BorderSide(
              color: selected ? colors.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(_settingsCategoryIcons[id]),
            const SizedBox(width: 16),
            Text(name, style: ts.s16),
            const Spacer(),
            if (selected) const Icon(Icons.arrow_right),
          ],
        ),
      );

      return Padding(
        padding: enableTwoViews
            ? const EdgeInsets.fromLTRB(8, 0, 8, 0)
            : EdgeInsets.zero,
        child: InkWell(
          onTap: () => _openSettingsCategory(id),
          child: content,
        ).paddingVertical(4),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _settingsCategories.length,
      itemBuilder: (context, index) =>
          buildItem(_settingsCategories[index].tl, index),
    );
  }

  Widget buildRight() {
    if (currentPage == -1) {
      return const SizedBox();
    }
    return Navigator(
      onGenerateRoute: (settings) {
        return PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) {
            return _buildSettingsContent(currentPage);
          },
          transitionDuration: Duration.zero,
        );
      },
    );
  }

  Widget _buildSettingsContent(int pageIndex) {
    return switch (pageIndex) {
      0 => const ExploreSettings(),
      1 => const ReaderSettings(),
      2 => const AppearanceSettings(),
      3 => const LocalFavoritesSettings(),
      4 => const AppSettings(),
      5 => const NetworkSettings(),
      6 => const AboutSettings(),
      7 => const DebugPage(),
      _ => throw UnimplementedError(),
    };
  }
}

class _SettingsDetailPage extends StatelessWidget {
  const _SettingsDetailPage({required this.pageIndex});

  final int pageIndex;

  @override
  Widget build(BuildContext context) {
    return Material(child: _buildPage());
  }

  Widget _buildPage() {
    return switch (pageIndex) {
      0 => const ExploreSettings(),
      1 => const ReaderSettings(),
      2 => const AppearanceSettings(),
      3 => const LocalFavoritesSettings(),
      4 => const AppSettings(),
      5 => const NetworkSettings(),
      6 => const AboutSettings(),
      7 => const DebugPage(),
      _ => throw UnimplementedError(),
    };
  }
}

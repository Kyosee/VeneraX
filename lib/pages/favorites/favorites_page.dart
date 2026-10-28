import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/entities/reorderable_animation_config.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/favorites_meta.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/related_source_tasks.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';

part 'favorite_actions.dart';
part 'folder_actions.dart';
part 'folder_widgets.dart';
part 'side_bar.dart';
part 'local_favorites_page.dart';
part 'local_favorites_page/actions.dart';
part 'local_favorites_page/reorder_comics_page.dart';
part 'local_favorites_page/select_update_page_num.dart';
part 'local_favorites_page/filter_dialog.dart';
part 'network_favorites_page.dart';

const _kLeftBarWidth = 280.0;

/// The folder list docks beside the content only when the content keeps at
/// least this much width; otherwise it opens as a drawer.
const _kMinDockedContentWidth = 600.0;

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

/// The local "All" entry, exposed for tests.
@visibleForTesting
const localAllFolderLabel = _localAllFolderLabel;

/// Restores the persisted favorites selection.
///
/// A stale local folder (deleted on this or another device) falls back to
/// "unselected", but the "All" entry is a sentinel rather than a real folder
/// table, so it never appears in [LocalFavoritesManager.folderNames] and must
/// be exempt from that check.
@visibleForTesting
({String? folder, bool isNetwork}) restoreFavoriteFolder(
  dynamic persisted,
  bool Function(String folder) localFolderExists,
) {
  if (persisted is! Map) return (folder: null, isNetwork: false);
  var name = persisted['name'];
  var folder = name is String ? name : null;
  var isNetwork = persisted['isNetwork'] == true;
  if (folder != null &&
      !isNetwork &&
      folder != _localAllFolderLabel &&
      !localFolderExists(folder)) {
    return (folder: null, isNetwork: false);
  }
  return (folder: folder, isNetwork: isNetwork);
}

/// Where the folder list sits for the current window width.
class _FavoritesLayout extends InheritedWidget {
  const _FavoritesLayout({
    required this.docked,
    required this.canDock,
    required super.child,
  });

  /// Shown beside the content.
  final bool docked;

  /// The window leaves room for it beside the content; when it doesn't, the
  /// list opens as a drawer instead.
  final bool canDock;

  static _FavoritesLayout? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_FavoritesLayout>();

  static bool isDocked(BuildContext context) => of(context)?.docked ?? false;

  @override
  bool updateShouldNotify(_FavoritesLayout oldWidget) =>
      docked != oldWidget.docked || canDock != oldWidget.canDock;
}

class _FavoritesPageState extends State<FavoritesPage> {
  String? folder;

  bool isNetwork = false;

  /// Local folders whose subfolders the folder list shows.
  final expandedFolders = <String>{};

  /// Hidden by the user. Only applies where the list fits beside the content;
  /// a narrow window always uses the drawer.
  bool sidebarHidden = false;

  @override
  void initState() {
    var restored = restoreFavoriteFolder(
      appdata.implicitData['favoriteFolder'],
      LocalFavoritesManager().existsFolder,
    );
    folder = restored.folder;
    isNetwork = restored.isNetwork;
    var expanded = appdata.implicitData['favoriteExpandedFolders'];
    if (expanded is List) {
      expandedFolders.addAll(expanded.whereType<String>());
    }
    sidebarHidden = appdata.implicitData['favoriteSidebarHidden'] == true;
    if (folder != null && !isNetwork) _revealFolder(folder!);
    super.initState();
  }

  void setFolder(bool isNetwork, String? folder) {
    setState(() {
      this.isNetwork = isNetwork;
      this.folder = folder;
      if (folder != null && !isNetwork) _revealFolder(folder);
    });
    appdata.implicitData['favoriteFolder'] = {
      'name': folder,
      'isNetwork': isNetwork,
    };
    _saveLayout();
  }

  /// Expands every ancestor of [folder] so the folder list shows it.
  void _revealFolder(String folder) {
    var tree = LocalFavoritesManager().folderTree;
    for (var p = tree.parentOf(folder); p != null; p = tree.parentOf(p)) {
      expandedFolders.add(p);
    }
  }

  void _saveLayout() {
    var manager = LocalFavoritesManager();
    // Keep the set while the store is down; every folder would look deleted.
    if (manager.isInitialized) {
      expandedFolders.removeWhere((f) => !manager.existsFolder(f));
    }
    appdata.implicitData['favoriteExpandedFolders'] = expandedFolders.toList();
    appdata.implicitData['favoriteSidebarHidden'] = sidebarHidden;
    appdata.writeImplicitData();
  }

  void toggleExpanded(String folder) {
    setState(() {
      if (!expandedFolders.remove(folder)) expandedFolders.add(folder);
    });
    _saveLayout();
  }

  void setSidebarHidden(bool hidden) {
    setState(() => sidebarHidden = hidden);
    _saveLayout();
  }

  /// Creates a folder under [parent] (null for the top level) and shows it in
  /// the folder list without opening it.
  Future<void> createFolder(String? parent) async {
    var created = await newFolder(parent: parent);
    if (created == null || !mounted) return;
    setState(() => _revealFolder(created));
    _saveLayout();
  }

  Future<void> renameFolder(String name) async {
    var renamed = await _showRenameFolderDialog(name);
    if (renamed == null) return;
    FavoriteFolderSort.rename(appdata.implicitData, name, renamed);
    if (expandedFolders.remove(name)) expandedFolders.add(renamed);
    if (mounted && folder == name && !isNetwork) {
      setFolder(false, renamed);
    } else {
      _saveLayout();
    }
  }

  Future<void> moveFolder(String name) async {
    if (!await _showMoveFolderDialog(name) || !mounted) return;
    setState(() => _revealFolder(name));
    _saveLayout();
  }

  Future<void> deleteFolder(String name) async {
    var parent = LocalFavoritesManager().folderTree.parentOf(name);
    var deleted = await _showDeleteFolderDialog(name);
    if (deleted == null) return;
    for (var f in deleted) {
      FavoriteFolderSort.remove(appdata.implicitData, f);
      expandedFolders.remove(f);
    }
    if (mounted && !isNetwork && deleted.contains(folder)) {
      // Back to where the folder was, rather than to nothing.
      setFolder(false, parent);
    } else {
      if (mounted) setState(() {});
      _saveLayout();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        var canDock =
            constraints.maxWidth - _kLeftBarWidth >= _kMinDockedContentWidth;
        var docked = canDock && !sidebarHidden;
        const duration = Duration(milliseconds: 200);
        return _FavoritesLayout(
          docked: docked,
          canDock: canDock,
          child: IconTheme(
            data: IconThemeData(color: context.colorScheme.onSurfaceVariant),
            child: Stack(
              children: [
                AnimatedPositioned(
                  left: docked ? 0 : -_kLeftBarWidth,
                  top: 0,
                  bottom: 0,
                  width: _kLeftBarWidth,
                  duration: duration,
                  child: _LeftBar(favPage: this),
                ),
                AnimatedPositioned(
                  top: 0,
                  left: docked ? _kLeftBarWidth : 0,
                  right: 0,
                  bottom: 0,
                  duration: duration,
                  child: buildBody(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void showFolderSelector() {
    Navigator.of(App.rootContext).push(
      PageRouteBuilder(
        barrierDismissible: true,
        fullscreenDialog: true,
        opaque: false,
        barrierColor: Colors.black.toOpacity(0.36),
        pageBuilder: (context, animation, secondary) {
          return Align(
            alignment: Alignment.centerLeft,
            child: Material(
              child: SizedBox(
                width: min(_kLeftBarWidth, context.width - 16),
                child: _LeftBar(
                  favPage: this,
                  inDrawer: true,
                  onSelected: () {
                    context.pop();
                  },
                ),
              ),
            ),
          );
        },
        transitionsBuilder: (context, animation, secondary, child) {
          var offset = Tween<Offset>(
            begin: const Offset(-1, 0),
            end: const Offset(0, 0),
          );
          return SlideTransition(
            position: offset.animate(
              CurvedAnimation(parent: animation, curve: Curves.fastOutSlowIn),
            ),
            child: child,
          );
        },
      ),
    );
  }

  /// Brings the folder list back: beside the content where it fits, as a
  /// drawer otherwise.
  void showFolders(BuildContext context) {
    if (_FavoritesLayout.of(context)?.canDock ?? false) {
      setSidebarHidden(false);
    } else {
      showFolderSelector();
    }
  }

  /// The app bar's leading button: shows the folder list unless it is docked.
  Widget folderButton(BuildContext context) {
    var layout = _FavoritesLayout.of(context);
    if (layout?.docked ?? false) return const SizedBox();
    return Tooltip(
      message: layout?.canDock ?? false ? "Show folder list".tl : "Folders".tl,
      child: IconButton(
        icon: const Icon(Icons.menu),
        color: context.colorScheme.primary,
        onPressed: () => showFolders(context),
      ),
    );
  }

  VoidCallback? onTitleTap(BuildContext context) =>
      _FavoritesLayout.isDocked(context) ? null : () => showFolders(context);

  Widget buildBody() {
    if (folder == null) {
      return _FavoritesOverview(favPage: this);
    }
    if (!isNetwork) {
      return _LocalFavoritesPage(
        folder: folder!,
        key: PageStorageKey("local_$folder"),
      );
    } else {
      var favoriteData = getFavoriteDataOrNull(folder!);
      if (favoriteData == null) {
        folder = null;
        return buildBody();
      } else {
        return NetworkFavoritePage(
          favoriteData,
          key: PageStorageKey("network_$folder"),
        );
      }
    }
  }
}

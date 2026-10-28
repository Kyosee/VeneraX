part of 'favorites_page.dart';

/// Network favorites the user enabled, in their order.
List<String> _networkFavoriteKeys() {
  var all = ComicSource.all()
      .where((e) => e.favoriteData != null)
      .map((e) => e.favoriteData!.key)
      .toSet();
  var result = <String>[];
  for (var key in appdata.settings['favorites'] as List) {
    if (all.contains(key) && !result.contains(key)) result.add(key);
  }
  return result;
}

class _LeftBar extends StatefulWidget {
  const _LeftBar({
    required this.favPage,
    this.onSelected,
    this.inDrawer = false,
  });

  final _FavoritesPageState favPage;

  final VoidCallback? onSelected;

  /// Shown as a drawer over the page rather than docked beside it.
  final bool inDrawer;

  @override
  State<_LeftBar> createState() => _LeftBarState();
}

class _LeftBarState extends State<_LeftBar> {
  _FavoritesPageState get favPage => widget.favPage;

  var networkFolders = <String>[];

  void updateFolders() {
    if (!mounted) return;
    setState(() {
      networkFolders = _networkFavoriteKeys();
    });
  }

  @override
  void initState() {
    networkFolders = _networkFavoriteKeys();
    appdata.settings.addListener(updateFolders);
    LocalFavoritesManager().addListener(updateFolders);
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    appdata.settings.removeListener(updateFolders);
    LocalFavoritesManager().removeListener(updateFolders);
  }

  /// Runs after a folder action: the drawer is a separate route, so the
  /// page's own rebuild does not reach it.
  void refresh() {
    if (mounted) setState(() {});
  }

  /// Local folders shown, top-level first, expanded ones with their children.
  List<String> visibleLocalFolders() {
    var tree = LocalFavoritesManager().folderTree;
    var rows = <String>[];
    void add(String? parent) {
      for (var f in tree.childrenOf(parent)) {
        rows.add(f);
        if (favPage.expandedFolders.contains(f)) add(f);
      }
    }

    add(null);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    var local = visibleLocalFolders();
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Column(
        children: [
          if (widget.inDrawer)
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  const CloseButton(),
                  const SizedBox(width: 8),
                  Expanded(child: Text("Folders".tl, style: ts.s18)),
                ],
              ),
            ).paddingTop(context.padding.top),
          Expanded(
            child: ListView.builder(
              key: const ValueKey('favorite_folder_list'),
              padding: widget.inDrawer
                  ? EdgeInsets.zero
                  : EdgeInsets.only(top: context.padding.top),
              itemCount: local.length + networkFolders.length + 3,
              itemBuilder: (context, index) {
                if (index == 0) return buildLocalTitle();
                index--;
                if (index == 0) return buildAllFolder();
                index--;
                if (index < local.length) return buildLocalFolder(local[index]);
                index -= local.length;
                if (index == 0) return buildNetworkTitle();
                index--;
                return buildNetworkFolder(networkFolders[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget buildLocalTitle() {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Icon(
            Icons.local_activity,
            color: context.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              "Local".tl,
              style: Theme.of(
                context,
              ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          MenuButton(
            entries: [
              MenuEntry(
                icon: Icons.add,
                text: 'Create Folder'.tl,
                onClick: () => favPage.createFolder(null).then((_) => refresh()),
              ),
              MenuEntry(
                icon: Icons.reorder,
                text: 'Sort'.tl,
                onClick: () => sortFolders().then((_) => refresh()),
              ),
            ],
          ),
          if (!widget.inDrawer)
            Tooltip(
              message: "Hide folder list".tl,
              child: IconButton(
                icon: const Icon(Icons.keyboard_double_arrow_left),
                visualDensity: VisualDensity.compact,
                onPressed: () => favPage.setSidebarHidden(true),
              ),
            ),
        ],
      ).paddingHorizontal(16),
    );
  }

  void _select(bool isNetwork, String folder) {
    if (folder == favPage.folder && isNetwork == favPage.isNetwork) return;
    favPage.setFolder(isNetwork, folder);
    widget.onSelected?.call();
  }

  /// One folder row; the selected row gets the accent bar and tint.
  Widget _row({
    required bool selected,
    required VoidCallback onTap,
    required Widget child,
    void Function(BuildContext context, Offset? position)? onMenu,
  }) {
    return Builder(
      builder: (context) {
        return InkWell(
          onTap: onTap,
          onLongPress: onMenu == null ? null : () => onMenu(context, null),
          onSecondaryTapDown: onMenu == null
              ? null
              : (d) => onMenu(context, d.globalPosition),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            decoration: BoxDecoration(
              color: selected
                  ? context.colorScheme.primaryContainer.toOpacity(0.36)
                  : null,
              border: Border(
                left: BorderSide(
                  color: selected
                      ? context.colorScheme.primary
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
            child: child,
          ),
        );
      },
    );
  }

  Widget _label(String text, bool selected) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: selected
          ? TextStyle(
              color: context.colorScheme.primary,
              fontWeight: FontWeight.w600,
            )
          : null,
    );
  }

  Widget _icon(IconData icon, bool selected) => Icon(
    icon,
    size: 20,
    color: selected ? context.colorScheme.primary : null,
  );

  Widget buildAllFolder() {
    var selected = favPage.folder == _localAllFolderLabel && !favPage.isNetwork;
    return _row(
      selected: selected,
      onTap: () => _select(false, _localAllFolderLabel),
      child: Row(
        children: [
          const SizedBox(width: 28),
          _icon(Icons.all_inbox_outlined, selected),
          const SizedBox(width: 8),
          Expanded(child: _label("All".tl, selected)),
          _CountBadge(LocalFavoritesManager().totalComics),
        ],
      ),
    );
  }

  Widget buildLocalFolder(String name) {
    var tree = LocalFavoritesManager().folderTree;
    var selected = name == favPage.folder && !favPage.isNetwork;
    var depth = tree.depthOf(name);
    var hasChildren = tree.hasChildren(name);
    var expanded = favPage.expandedFolders.contains(name);
    return _row(
      selected: selected,
      onTap: () => _select(false, name),
      onMenu: (context, position) {
        _showFolderMenu(
          context,
          favPage,
          name,
          position: position,
          then: refresh,
        );
      },
      child: Row(
        children: [
          SizedBox(width: 14.0 * (depth > 6 ? 6 : depth)),
          SizedBox(
            width: 28,
            height: 28,
            child: hasChildren
                ? IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    tooltip: expanded ? "Collapse".tl : "Expand".tl,
                    icon: Icon(
                      expanded ? Icons.expand_more : Icons.chevron_right,
                    ),
                    onPressed: () {
                      favPage.toggleExpanded(name);
                      refresh();
                    },
                  )
                : null,
          ),
          _icon(
            expanded && hasChildren ? Icons.folder_open : Icons.folder_outlined,
            selected,
          ),
          const SizedBox(width: 8),
          Expanded(child: _label(_localFolderTitle(name), selected)),
          _CountBadge(LocalFavoritesManager().folderComics(name)),
        ],
      ),
    );
  }

  Widget buildNetworkTitle() {
    return Container(
      height: 56,
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud, color: context.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Text(
            "Network".tl,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: "Manage".tl,
            onPressed: () {
              showPopUpWidget(App.rootContext, setFavoritesPagesWidget());
            },
          ),
        ],
      ).paddingHorizontal(16),
    );
  }

  Widget buildNetworkFolder(String key) {
    var data = getFavoriteDataOrNull(key);
    if (data == null) {
      return const SizedBox();
    }
    var selected = key == favPage.folder && favPage.isNetwork;
    return _row(
      selected: selected,
      onTap: () => _select(true, key),
      child: Row(
        children: [
          const SizedBox(width: 28),
          _icon(Icons.cloud_outlined, selected),
          const SizedBox(width: 8),
          Expanded(child: _label(data.title, selected)),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Text(
        count.toString(),
        style: Theme.of(context).textTheme.labelSmall,
      ),
    );
  }
}

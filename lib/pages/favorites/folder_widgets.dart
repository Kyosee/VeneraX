part of 'favorites_page.dart';

/// Grid of [_FolderCard]s, tall enough for two lines at any text scale.
SliverGridDelegate _folderGridDelegate(BuildContext context) {
  final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: 320,
    mainAxisExtent: 64 + 20 * scale,
    crossAxisSpacing: 8,
    mainAxisSpacing: 8,
  );
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.title,
    required this.onTap,
    this.cover,
    this.icon = Icons.folder_outlined,
    this.comics,
    this.subfolders = 0,
    this.onMenu,
  });

  final String title;

  final FavoriteItem? cover;

  final IconData icon;

  final int? comics;

  final int subfolders;

  final VoidCallback onTap;

  final void Function(BuildContext context, Offset? position)? onMenu;

  Widget buildCover(BuildContext context) {
    var colors = context.colorScheme;
    var image = cover == null ? null : findImageProvider(cover!);
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: image == null
          ? Icon(icon, color: colors.onSurfaceVariant)
          : AnimatedImage(
              image: image,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    var colors = context.colorScheme;
    Widget thumbnail = cover != null &&
            ComicCollectionStore.isCollectionSourceKey(cover!.sourceKey)
        // A collection's cover fills in once its members load, as on the
        // comic tiles.
        ? ListenableBuilder(
            listenable: ComicCollectionStore.changes,
            builder: (context, _) => buildCover(context),
          )
        : buildCover(context);
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu == null ? null : () => onMenu!(context, null),
        onSecondaryTapDown: onMenu == null
            ? null
            : (d) => onMenu!(context, d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              AspectRatio(
                aspectRatio: 0.72,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: thumbnail,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    _FolderStats(comics: comics, subfolders: subfolders),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderStats extends StatelessWidget {
  const _FolderStats({required this.comics, required this.subfolders});

  final int? comics;

  final int subfolders;

  @override
  Widget build(BuildContext context) {
    var color = context.colorScheme.onSurfaceVariant;
    var style = ts.s12.copyWith(color: color);
    return Row(
      children: [
        if (comics != null) ...[
          Icon(Icons.collections_bookmark_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Text(comics.toString(), style: style),
        ],
        if (subfolders > 0) ...[
          if (comics != null) const SizedBox(width: 12),
          Icon(Icons.folder_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          Text(subfolders.toString(), style: style),
        ],
      ],
    );
  }
}

/// Cover of each folder, re-read only when the folder's comic count changes.
class _FolderCovers {
  final _cache = <String, (int, FavoriteItem?)>{};

  FavoriteItem? of(String folder) {
    var manager = LocalFavoritesManager();
    var count = manager.folderComics(folder);
    var cached = _cache[folder];
    if (cached != null && cached.$1 == count) return cached.$2;
    var cover = count == 0 ? null : manager.firstComic(folder);
    _cache[folder] = (count, cover);
    return cover;
  }
}

Widget _folderCardFor(
  BuildContext context,
  _FavoritesPageState favPage,
  String folder,
  _FolderCovers covers,
) {
  var manager = LocalFavoritesManager();
  return _FolderCard(
    title: _localFolderTitle(folder),
    cover: covers.of(folder),
    comics: manager.folderComics(folder),
    subfolders: manager.folderTree.childrenOf(folder).length,
    onTap: () => favPage.setFolder(false, folder),
    onMenu: (context, position) {
      _showFolderMenu(context, favPage, folder, position: position);
    },
  );
}

String _localFolderTitle(String folder) {
  if (folder == _localAllFolderLabel) return "All".tl;
  return getFavoriteDataOrNull(folder)?.title ?? folder;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: context.colorScheme.primary,
              ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Shown when no folder is selected: every top-level folder and network
/// favorite as a card.
class _FavoritesOverview extends StatefulWidget {
  const _FavoritesOverview({required this.favPage});

  final _FavoritesPageState favPage;

  @override
  State<_FavoritesOverview> createState() => _FavoritesOverviewState();
}

class _FavoritesOverviewState extends State<_FavoritesOverview> {
  final covers = _FolderCovers();

  void update() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    LocalFavoritesManager().addListener(update);
    appdata.settings.addListener(update);
  }

  @override
  void dispose() {
    LocalFavoritesManager().removeListener(update);
    appdata.settings.removeListener(update);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var favPage = widget.favPage;
    var manager = LocalFavoritesManager();
    var roots = manager.folderTree.childrenOf(null);
    var network = _networkFavoriteKeys()
        .map(getFavoriteDataOrNull)
        .whereType<FavoriteData>()
        .toList();
    return SmoothCustomScrollView(
      scrollbarTopPadding: context.padding.top + 56,
      slivers: [
        SliverAppbar(
          style: context.width < changePoint
              ? AppbarStyle.shadow
              : AppbarStyle.blur,
          leading: favPage.folderButton(context),
          title: GestureDetector(
            onTap: favPage.onTitleTap(context),
            child: Text("Favorites".tl),
          ),
          actions: [
            Tooltip(
              message: "Create Folder".tl,
              child: IconButton(
                icon: const Icon(Icons.create_new_folder_outlined),
                onPressed: () => favPage.createFolder(null),
              ),
            ),
          ],
        ),
        SliverToBoxAdapter(child: _SectionTitle("Local".tl)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          sliver: SliverGrid(
            gridDelegate: _folderGridDelegate(context),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index == 0) {
                  return _FolderCard(
                    title: "All".tl,
                    icon: Icons.all_inbox_outlined,
                    comics: manager.totalComics,
                    onTap: () => favPage.setFolder(false, _localAllFolderLabel),
                  );
                }
                return _folderCardFor(
                  context,
                  favPage,
                  roots[index - 1],
                  covers,
                );
              },
              childCount: roots.length + 1,
            ),
          ),
        ),
        if (network.isNotEmpty) ...[
          SliverToBoxAdapter(child: _SectionTitle("Network".tl)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            sliver: SliverGrid(
              gridDelegate: _folderGridDelegate(context),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  var data = network[index];
                  return _FolderCard(
                    title: data.title,
                    icon: Icons.cloud_outlined,
                    onTap: () => favPage.setFolder(true, data.key),
                  );
                },
                childCount: network.length,
              ),
            ),
          ),
        ],
        SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom)),
      ],
    );
  }
}

/// "Parent › Child" above a subfolder's comics; each ancestor opens itself.
class _FolderBreadcrumb extends StatelessWidget {
  const _FolderBreadcrumb({required this.favPage, required this.folder});

  final _FavoritesPageState favPage;

  final String folder;

  @override
  Widget build(BuildContext context) {
    var path = LocalFavoritesManager().folderTree.pathOf(folder);
    var color = context.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < path.length; i++) ...[
            if (i > 0) Icon(Icons.chevron_right, size: 18, color: color),
            if (i < path.length - 1)
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: () => favPage.setFolder(false, path[i]),
                child: Text(path[i]),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  path[i],
                  style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

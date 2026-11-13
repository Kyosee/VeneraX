part of 'comic_page.dart';

class _FavoritePanel extends StatefulWidget {
  const _FavoritePanel({
    required this.cid,
    required this.type,
    required this.isFavorite,
    required this.onFavorite,
    required this.favoriteItem,
    this.updateTime,
  });

  final String cid;

  final ComicType type;

  /// whether the comic is in the network favorite list
  ///
  /// if null, the comic source does not support favorite or support multiple favorite lists
  final bool? isFavorite;

  final void Function(bool?, bool?) onFavorite;

  final FavoriteItem favoriteItem;

  final String? updateTime;

  @override
  State<_FavoritePanel> createState() => _FavoritePanelState();
}

class _FavoritePanelState extends State<_FavoritePanel>
    with SingleTickerProviderStateMixin {
  ComicSource? comicSource;

  late bool hasNetwork;

  late List<String> localFolders;

  late List<String> added;

  @override
  void initState() {
    comicSource = widget.type.comicSource;
    localFolders = LocalFavoritesManager().folderNames;
    added = LocalFavoritesManager().find(widget.cid, widget.type);
    hasNetwork = comicSource?.favoriteData != null && comicSource!.isLogged;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(title: Text("Favorite".tl)),
      body: ComicFavoriteList(
        cid: widget.cid,
        type: widget.type,
        isFavorite: widget.isFavorite,
        onFavorite: widget.onFavorite,
        favoriteItem: widget.favoriteItem,
        updateTime: widget.updateTime,
        comicSource: comicSource,
        hasNetwork: hasNetwork,
        localFolders: localFolders,
        added: added,
      ),
    );
  }
}

class ComicFavoriteList extends StatelessWidget {
  const ComicFavoriteList({
    super.key,
    required this.cid,
    required this.type,
    required this.isFavorite,
    required this.onFavorite,
    required this.favoriteItem,
    this.updateTime,
    required this.comicSource,
    required this.hasNetwork,
    required this.localFolders,
    required this.added,
    this.closeOnFavorite = true,
    this.favoriteId,
  });

  final String cid;
  final ComicType type;
  final bool? isFavorite;
  final void Function(bool?, bool?) onFavorite;
  final FavoriteItem favoriteItem;
  final String? updateTime;
  final ComicSource? comicSource;
  final bool hasNetwork;
  final List<String> localFolders;
  final List<String> added;
  final bool closeOnFavorite;
  final String? favoriteId;

  @override
  Widget build(BuildContext context) {
    final localFavoritesFirst = appdata.settings['localFavoritesFirst'] ?? true;
    final localSection = _LocalSection(
      cid: cid,
      type: type,
      favoriteItem: favoriteItem,
      updateTime: updateTime,
      localFolders: localFolders,
      added: added,
      closeOnFavorite: closeOnFavorite,
      onFavorite: (local) => onFavorite(local, null),
    );
    final source = comicSource;
    final networkSection =
        hasNetwork && source?.favoriteData?.addOrDelFavorite != null
        ? _NetworkSection(
            cid: cid,
            comicSource: source!,
            isFavorite: isFavorite,
            favoriteId: favoriteId,
            closeOnFavorite: closeOnFavorite,
            onFavorite: (network) => onFavorite(null, network),
          )
        : null;

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (localFavoritesFirst) localSection,
        if (networkSection != null) ...[
          if (localFavoritesFirst) const Divider(indent: 16, endIndent: 16),
          networkSection,
          if (!localFavoritesFirst) const Divider(indent: 16, endIndent: 16),
        ],
        if (!localFavoritesFirst) localSection,
      ],
    );
  }
}

class _NetworkSection extends StatefulWidget {
  const _NetworkSection({
    required this.cid,
    required this.comicSource,
    required this.isFavorite,
    required this.onFavorite,
    required this.closeOnFavorite,
    this.favoriteId,
  });

  final String cid;
  final ComicSource comicSource;
  final bool? isFavorite;
  final void Function(bool) onFavorite;
  final bool closeOnFavorite;
  final String? favoriteId;

  @override
  State<_NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<_NetworkSection> {
  Map<String, String> folders = {};
  Set<String> addedFolders = {};
  bool isLoadingFolders = true;
  bool? localIsFavorite;
  String? pendingFolder;
  String? loadError;

  @override
  void initState() {
    super.initState();
    localIsFavorite = widget.isFavorite;
    if (widget.comicSource.favoriteData!.loadFolders != null ||
        localIsFavorite == null) {
      loadFavorites();
    } else {
      isLoadingFolders = false;
    }
  }

  Future<void> loadFavorites() async {
    setState(() {
      isLoadingFolders = true;
      loadError = null;
    });
    try {
      final loadFolders = widget.comicSource.favoriteData!.loadFolders;
      if (loadFolders != null) {
        final res = await loadFolders(widget.cid);
        if (res.error) throw res.errorMessage!;
        if (!mounted) return;
        folders = res.data;
        addedFolders = res.subData is List
            ? Set<String>.from(res.subData)
            : <String>{};
        localIsFavorite = addedFolders.isNotEmpty;
      } else {
        final loadComicInfo = widget.comicSource.loadComicInfo;
        if (loadComicInfo == null) throw "Error".tl;
        final res = await loadComicInfo(widget.cid);
        if (res.error) throw res.errorMessage!;
        if (!mounted) return;
        localIsFavorite = res.data.isFavorite ?? false;
      }
    } catch (e) {
      if (!mounted) return;
      loadError = e.toString();
    }
    if (mounted) setState(() => isLoadingFolders = false);
  }

  Future<void> changeFavorite(String folderId, bool isAdded) async {
    if (pendingFolder != null) return;
    setState(() => pendingFolder = folderId);
    try {
      final res = await widget.comicSource.favoriteData!.addOrDelFavorite!(
        widget.cid,
        folderId,
        !isAdded,
        widget.favoriteId,
      );
      if (res.error) throw res.errorMessage!;
      NetworkCacheManager().clear();
      if (!mounted) return;
      setState(() {
        if (isAdded) {
          addedFolders.remove(folderId);
        } else {
          addedFolders.add(folderId);
        }
        localIsFavorite = addedFolders.isNotEmpty;
      });
      widget.onFavorite(localIsFavorite!);
      if (widget.closeOnFavorite &&
          (appdata.settings['autoCloseFavoritePanel'] ?? false)) {
        context.pop();
      }
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      if (mounted) setState(() => pendingFolder = null);
    }
  }

  Widget buildFolder(String id, String name, bool isAdded) {
    final canAdd =
        !widget.comicSource.favoriteData!.singleFolderForSingleComic ||
        addedFolders.isEmpty ||
        isAdded;
    return CheckboxListTile(
      title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
      value: isAdded,
      selected: isAdded,
      controlAffinity: ListTileControlAffinity.leading,
      secondary: pendingFolder == id
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
      onChanged: pendingFolder == null && canAdd
          ? (_) => changeFavorite(id, isAdded)
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            "Network Favorites".tl,
            style: ts.s14.copyWith(
              fontWeight: FontWeight.w600,
              color: context.colorScheme.primary,
            ),
          ),
        ),
        if (isLoadingFolders)
          const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          )
        else if (loadError != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loadError!,
                  style: TextStyle(color: context.colorScheme.error),
                ),
                TextButton.icon(
                  onPressed: loadFavorites,
                  icon: const Icon(Icons.refresh),
                  label: Text("Retry".tl),
                ),
              ],
            ),
          )
        else if (widget.comicSource.favoriteData!.loadFolders != null)
          ...folders.entries.map(
            (entry) => buildFolder(
              entry.key,
              entry.value,
              addedFolders.contains(entry.key),
            ),
          )
        else
          buildFolder('', widget.comicSource.name, localIsFavorite ?? false),
      ],
    );
  }
}

class _LocalSection extends StatefulWidget {
  const _LocalSection({
    required this.cid,
    required this.type,
    required this.favoriteItem,
    this.updateTime,
    required this.localFolders,
    required this.added,
    required this.onFavorite,
    required this.closeOnFavorite,
  });

  final String cid;
  final ComicType type;
  final FavoriteItem favoriteItem;
  final String? updateTime;
  final List<String> localFolders;
  final List<String> added;
  final void Function(bool) onFavorite;
  final bool closeOnFavorite;

  @override
  State<_LocalSection> createState() => _LocalSectionState();
}

class _LocalSectionState extends State<_LocalSection> {
  late List<String> localFolders;
  late Set<String> localAdded;

  @override
  void initState() {
    super.initState();
    localFolders = widget.localFolders;
    localAdded = widget.added.toSet();
  }

  Future<void> createFolder() async {
    await newFolder();
    if (!mounted) return;
    setState(() => localFolders = LocalFavoritesManager().folderNames);
  }

  void changeFavorite(String folder, bool isAdded) {
    final manager = LocalFavoritesManager();
    try {
      if (isAdded) {
        manager.deleteComicWithId(folder, widget.cid, widget.type);
      } else {
        manager.addComic(folder, widget.favoriteItem, null, widget.updateTime);
      }
      setState(
        () => localAdded = manager.find(widget.cid, widget.type).toSet(),
      );
      widget.onFavorite(localAdded.isNotEmpty);
      if (widget.closeOnFavorite &&
          (appdata.settings['autoCloseFavoritePanel'] ?? false)) {
        context.pop();
      }
    } catch (e) {
      if (mounted) context.showMessage(message: e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tree = LocalFavoritesManager().folderTree;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  "Local Favorites".tl,
                  style: ts.s14.copyWith(
                    fontWeight: FontWeight.w600,
                    color: context.colorScheme.primary,
                  ),
                ),
                TextButton.icon(
                  onPressed: createFolder,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text("New Folder".tl),
                ),
              ],
            ),
          ),
        ),
        ...localFolders.map((folder) {
          final isAdded = localAdded.contains(folder);
          return CheckboxListTile(
            contentPadding: EdgeInsetsDirectional.only(
              start: 16.0 + 16 * math.min(tree.depthOf(folder), 3),
              end: 16,
            ),
            title: Text(folder, maxLines: 2, overflow: TextOverflow.ellipsis),
            value: isAdded,
            selected: isAdded,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (_) => changeFavorite(folder, isAdded),
          );
        }),
        ListTile(
          leading: const Icon(Icons.create_new_folder_outlined),
          title: Text("New Folder".tl),
          onTap: createFolder,
        ),
      ],
    );
  }
}

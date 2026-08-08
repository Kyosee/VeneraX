part of 'components.dart';

/// Lets the user drop one or more comics into a collection, or start a new one.
///
/// Reachable from the list long-press menu, the swipe action, multi-select and
/// the detail page, so it takes plain [Comic]s and does its own filtering: a
/// collection can never contain another collection (chapter loading would
/// recurse), and adding a comic twice is a no-op rather than a duplicate
/// chapter run.
void showAddToCollectionDialog(BuildContext context, List<Comic> comics) {
  final eligible = comics
      .where((c) => !ComicCollectionStore.isCollectionSourceKey(c.sourceKey))
      .toList();
  if (eligible.isEmpty) {
    App.rootContext.showMessage(
      message: "A collection cannot be added to another collection".tl,
    );
    return;
  }

  showDialog(
    context: App.rootContext,
    builder: (context) => _AddToCollectionDialog(comics: eligible),
  );
}

class _AddToCollectionDialog extends StatefulWidget {
  const _AddToCollectionDialog({required this.comics});

  final List<Comic> comics;

  @override
  State<_AddToCollectionDialog> createState() => _AddToCollectionDialogState();
}

class _AddToCollectionDialogState extends State<_AddToCollectionDialog> {
  late List<ComicCollection> collections;

  /// null = creating a new collection; otherwise the target's id.
  String? targetId;

  final nameController = TextEditingController();

  CollectionDisplayMode mode = CollectionDisplayMode.flat;

  /// Folder to favorite the new collection into; null = don't favorite.
  String? favoriteFolder;

  /// Whether to un-favorite the member comics once they're in the collection.
  bool removeMembersFromFavorites = false;

  late final List<String> folders;

  bool get isCreating => targetId == null;

  @override
  void initState() {
    super.initState();
    collections = ComicCollectionStore.all();
    folders = LocalFavoritesManager().folderNames;
    nameController.text = widget.comics.first.title;
    // Defaults to the folder the first comic is already in, so the collection
    // lands beside the comics it replaces rather than in an unrelated folder.
    final existing = LocalFavoritesManager().find(
      widget.comics.first.id,
      ComicType.fromKey(widget.comics.first.sourceKey),
    );
    final firstFolder = existing.firstOrNull;
    if (firstFolder != null && folders.contains(firstFolder)) {
      favoriteFolder = firstFolder;
    }
    // Several multi-chapter comics are far more often "one volume each" than
    // "one instalment each", so preselect tabs when every member looks like a
    // volume of its own. A single comic keeps the merged default.
    if (widget.comics.length > 1) {
      mode = CollectionDisplayMode.tabs;
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  List<CollectionMember> get _members => widget.comics
      .map(
        (c) => CollectionMember(
          sourceKey: c.sourceKey,
          comicId: c.id,
          cachedTitle: c.title,
          cachedSubtitle: c.subtitle ?? '',
          cachedCover: _coverOf(c),
        ),
      )
      .toList();

  /// The member's cover in a form the image loaders accept.
  ///
  /// A local comic's `cover` is a bare file name relative to its own directory
  /// ("cover.jpg"), which would be treated as a URL if the collection borrowed
  /// it. Resolving it here means the collection can show it right away, before
  /// the first detail load rewrites the cache.
  String _coverOf(Comic c) {
    final type = ComicType.fromKey(c.sourceKey);
    if (type == ComicType.local) {
      final local = LocalManager().find(c.id, ComicType.local);
      if (local != null) return 'file://${local.coverFile.path}';
      return '';
    }
    return c.cover;
  }

  /// Removes the member comics from every local favorite folder holding them.
  void _unfavoriteMembers() {
    for (final comic in widget.comics) {
      final type = ComicType.fromKey(comic.sourceKey);
      for (final folder in LocalFavoritesManager().find(comic.id, type)) {
        LocalFavoritesManager().deleteComicWithId(folder, comic.id, type);
      }
    }
  }

  void _confirm() {
    final collection = isCreating
        ? ComicCollectionStore.create(
            name: nameController.text,
            members: _members,
            displayMode: mode,
          )
        : ComicCollectionStore.find(targetId!);
    if (collection == null) {
      context.pop();
      App.rootContext.showMessage(
        message: "This collection no longer exists".tl,
      );
      return;
    }

    var added = widget.comics.length;
    if (!isCreating) {
      added = ComicCollectionStore.addMembers(collection.id, _members);
      // An existing collection's layout is only changed when the user actually
      // moved the switch, so filing one more comic doesn't silently re-lay-out
      // a collection they already arranged.
      if (mode != collection.displayMode) {
        ComicCollectionStore.update(collection.id, displayMode: mode);
      }
    }

    // The source captures the chapter layout, so it has to be rebuilt whenever
    // membership or the mode changes.
    ComicSourceManager().refreshCollectionSources();

    // Favoriting happens after the source exists: the tile resolves its cover
    // and title through the source.
    final folder = favoriteFolder;
    if (folder != null && folders.contains(folder)) {
      final fresh = ComicCollectionStore.find(collection.id) ?? collection;
      LocalFavoritesManager().addComic(
        folder,
        FavoriteItem(
          id: fresh.id,
          name: fresh.displayName,
          // Stored raw, not resolved: a resolved local-file cover is an absolute
          // path on THIS device, and favourites travel through sync. The tile
          // re-reads the collection's cover anyway, so this is only a fallback.
          coverPath: fresh.customCover.trim().isNotEmpty
              ? fresh.customCover
              : fresh.displayCover,
          author: '',
          type: ComicType.fromKey(fresh.sourceKey),
          tags: const [],
        ),
      );
    }

    if (removeMembersFromFavorites) {
      _unfavoriteMembers();
    }

    context.pop();
    App.rootContext.showMessage(
      message: isCreating
          ? "Created @c".tlParams({'c': collection.displayName})
          : added == 0
              ? "Already in this collection".tl
              : "Added @n comics to @c".tlParams({
                  'n': added,
                  'c': collection.displayName,
                }),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ContentDialog wraps its content in IntrinsicWidth, which cannot measure a
    // scrollable of indefinite width — an unbounded child there renders with no
    // size and crashes hit-testing. Both dimensions are pinned explicitly.
    final width = (context.width - 64).clamp(280.0, 420.0);
    final height = (context.height * 0.6).clamp(280.0, 520.0);
    return ContentDialog(
      title: "Add to collection".tl,
      content: SizedBox(
        width: width,
        height: height,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _buildTargetSection(),
            const SizedBox(height: 8),
            if (isCreating) ...[
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: "Collection name".tl,
                  hintText: "Leave empty to use the first comic's title".tl,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 16),
            ],
            _buildModeSection(),
            const Divider(height: 24),
            _buildFavoriteSection(),
          ],
        ),
      ),
      actions: [
        FilledButton(onPressed: _confirm, child: Text("Confirm".tl)),
      ],
    );
  }

  Widget _buildTargetSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Target".tl, style: ts.s12.copyWith(
          color: context.colorScheme.outline,
        )),
        const SizedBox(height: 4),
        Select(
          current: isCreating
              ? "New collection".tl
              : (ComicCollectionStore.find(targetId!)?.displayName ??
                    "New collection".tl),
          values: [
            "New collection".tl,
            ...collections.map((e) => e.displayName),
          ],
          minWidth: 180,
          onTap: (i) {
            setState(() {
              if (i == 0) {
                targetId = null;
              } else {
                final picked = collections[i - 1];
                targetId = picked.id;
                mode = picked.displayMode;
              }
            });
          },
        ),
      ],
    );
  }

  Widget _buildModeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Chapter layout".tl, style: ts.s12.copyWith(
          color: context.colorScheme.outline,
        )),
        RadioGroup<CollectionDisplayMode>(
          groupValue: mode,
          onChanged: (v) => v == null ? null : setState(() => mode = v),
          child: Column(
            children: [
              RadioListTile<CollectionDisplayMode>(
                value: CollectionDisplayMode.flat,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text("Merged chapters".tl, style: ts.s14),
                subtitle: Text(
                  "One chapter list. Use when each comic is one instalment.".tl,
                  style: ts.s12,
                ),
              ),
              RadioListTile<CollectionDisplayMode>(
                value: CollectionDisplayMode.tabs,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text("Chapter tabs".tl, style: ts.s14),
                subtitle: Text(
                  "One tab per comic. Use when each comic has its own chapters."
                      .tl,
                  style: ts.s12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFavoriteSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Favorites".tl, style: ts.s12.copyWith(
          color: context.colorScheme.outline,
        )),
        const SizedBox(height: 4),
        if (folders.isEmpty)
          Text(
            "No favorite folders yet".tl,
            style: ts.s12.copyWith(color: context.colorScheme.outline),
          )
        else
          Row(
            children: [
              Expanded(
                child: Text("Add collection to".tl, style: ts.s14),
              ),
              Select(
                current: favoriteFolder ?? "Don't add".tl,
                values: ["Don't add".tl, ...folders],
                minWidth: 132,
                onTap: (i) {
                  setState(() {
                    favoriteFolder = i == 0 ? null : folders[i - 1];
                  });
                },
              ),
            ],
          ),
        const SizedBox(height: 4),
        CheckboxListTile(
          value: removeMembersFromFavorites,
          onChanged: (v) =>
              setState(() => removeMembersFromFavorites = v ?? false),
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text("Un-favorite the added comics".tl, style: ts.s14),
          subtitle: Text(
            "Removes them from favorites, keeping only the collection.".tl,
            style: ts.s12,
          ),
        ),
      ],
    );
  }
}

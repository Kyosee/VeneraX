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
  /// null = creating a new collection; otherwise the target's id.
  String? targetId;

  final nameController = TextEditingController();

  /// One tab label per comic, in [widget.comics] order. Only read in
  /// [CollectionDisplayMode.tabs]; kept alive across a mode switch so toggling
  /// back doesn't discard what the user typed.
  late final List<TextEditingController> labelControllers;

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
    folders = LocalFavoritesManager().folderNames;
    nameController.text = widget.comics.first.title;
    labelControllers = widget.comics
        .map((c) => TextEditingController(text: c.title))
        .toList();
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
    for (final c in labelControllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// A tab label is only stored when the user actually kept the tabs layout and
  /// changed the text: an untouched field equals the comic's own title, and
  /// [CollectionMember.label] already falls back to that, so storing it would
  /// freeze a title that the next detail load would otherwise refresh.
  List<CollectionMember> get _members {
    final result = <CollectionMember>[];
    for (var i = 0; i < widget.comics.length; i++) {
      final c = widget.comics[i];
      final typed = labelControllers[i].text.trim();
      result.add(
        CollectionMember(
          sourceKey: c.sourceKey,
          comicId: c.id,
          displayName:
              mode == CollectionDisplayMode.tabs && typed != c.title.trim()
              ? typed
              : '',
          cachedTitle: c.title,
          cachedSubtitle: c.subtitle ?? '',
          cachedCover: _coverOf(c),
        ),
      );
    }
    return result;
  }

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
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: context.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 480,
        height: math.min(context.height * 0.8, 640),
        child: Column(
          children: [
            MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: Appbar(
                backgroundColor: Colors.transparent,
                title: Text("Add to collection".tl),
                leading: IconButton(
                  tooltip: "Cancel".tl,
                  onPressed: context.pop,
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  _buildTargetSection(),
                  const SizedBox(height: 16),
                  if (isCreating) ...[
                    TextField(
                      controller: nameController,
                      decoration: InputDecoration(
                        labelText: "Collection name".tl,
                        hintText:
                            "Leave empty to use the first comic's title".tl,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  _buildModeSection(),
                  if (mode == CollectionDisplayMode.tabs) _buildLabelSection(),
                  const Divider(height: 24),
                  _buildFavoriteSection(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  onPressed: _confirm,
                  child: Text("Confirm".tl),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _selectTarget() async {
    FocusScope.of(context).unfocus();
    final id = await showDialog<String>(
      context: context,
      builder: (context) =>
          _CollectionPickerDialog(selectedId: targetId, comics: widget.comics),
    );
    if (!mounted || id == null) return;
    final picked = id.isEmpty ? null : ComicCollectionStore.find(id);
    if (id.isNotEmpty && picked == null) {
      context.showMessage(message: "This collection no longer exists".tl);
      return;
    }
    setState(() {
      targetId = picked?.id;
      if (picked != null) mode = picked.displayMode;
    });
  }

  Widget _buildTargetSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Target".tl,
          style: ts.s12.copyWith(color: context.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        _CollectionTargetTile(
          key: const ValueKey('collection-target'),
          collection: isCreating ? null : ComicCollectionStore.find(targetId!),
          onTap: _selectTarget,
          trailing: const Icon(Icons.unfold_more),
        ),
      ],
    );
  }

  Widget _buildModeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          "Chapter layout".tl,
          style: ts.s12.copyWith(color: context.colorScheme.outline),
        ),
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

  Widget _buildLabelSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(
          "Tab names".tl,
          style: ts.s12.copyWith(color: context.colorScheme.outline),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < widget.comics.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Which comic this field renames: once the text is edited the
                // field itself no longer identifies it.
                if (widget.comics.length > 1) ...[
                  Text(
                    widget.comics[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s12.copyWith(color: context.colorScheme.outline),
                  ),
                  const SizedBox(height: 4),
                ],
                TextField(
                  controller: labelControllers[i],
                  decoration: InputDecoration(
                    labelText: "Tab name".tl,
                    hintText: "Leave empty to use the comic's title".tl,
                    border: const OutlineInputBorder(),
                    isDense: true,
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
        Text(
          "Favorites".tl,
          style: ts.s12.copyWith(color: context.colorScheme.outline),
        ),
        const SizedBox(height: 4),
        if (folders.isEmpty)
          Text(
            "No favorite folders yet".tl,
            style: ts.s12.copyWith(color: context.colorScheme.outline),
          )
        else
          Row(
            children: [
              Expanded(child: Text("Add collection to".tl, style: ts.s14)),
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

class _CollectionPickerDialog extends StatefulWidget {
  const _CollectionPickerDialog({
    required this.selectedId,
    required this.comics,
  });

  final String? selectedId;
  final List<Comic> comics;

  @override
  State<_CollectionPickerDialog> createState() =>
      _CollectionPickerDialogState();
}

class _CollectionPickerDialogState extends State<_CollectionPickerDialog> {
  final searchController = TextEditingController();
  final scrollController = ScrollController();
  late List<ComicCollection> collections;
  late final selectedComics = widget.comics
      .map((comic) => (comic.sourceKey, comic.id))
      .toSet();
  String query = '';

  @override
  void initState() {
    super.initState();
    collections = ComicCollectionStore.all();
    ComicCollectionStore.changes.addListener(_reload);
  }

  void _reload() {
    setState(() => collections = ComicCollectionStore.all());
  }

  @override
  void dispose() {
    ComicCollectionStore.changes.removeListener(_reload);
    searchController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = collections.where((collection) {
      return query.isEmpty ||
          collection.displayName.toLowerCase().contains(query) ||
          collection.members.any(
            (member) =>
                member.label.toLowerCase().contains(query) ||
                member.cachedTitle.toLowerCase().contains(query),
          );
    }).toList();

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: context.colorScheme.surface,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 520,
        height: math.min(context.height * 0.8, 640),
        child: Column(
          children: [
            MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: Appbar(
                backgroundColor: Colors.transparent,
                title: Text("Select collection".tl),
                leading: IconButton(
                  tooltip: "Cancel".tl,
                  onPressed: context.pop,
                  icon: const Icon(Icons.close),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: AppSearchField(
                controller: searchController,
                hintText: "Search collections or comics".tl,
                onChanged: (value) {
                  setState(() => query = value.trim().toLowerCase());
                  if (scrollController.hasClients) scrollController.jumpTo(0);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  "Collections: @n".tlParams({'n': matches.length}),
                  style: ts.s12.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Scrollbar(
                controller: scrollController,
                child: ListView.separated(
                  key: const ValueKey('collection-picker-list'),
                  controller: scrollController,
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: 1 + math.max(1, matches.length),
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    if (index > 0 && matches.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          (collections.isEmpty
                                  ? "No collections yet"
                                  : "No matching collections")
                              .tl,
                          textAlign: TextAlign.center,
                        ),
                      );
                    }
                    final collection = index == 0 ? null : matches[index - 1];
                    final selected = collection?.id == widget.selectedId;
                    final included =
                        collection?.members
                            .where(
                              (member) => selectedComics.contains((
                                member.sourceKey,
                                member.comicId,
                              )),
                            )
                            .length ??
                        0;
                    return _CollectionTargetTile(
                      key: ValueKey(collection?.id ?? ''),
                      collection: collection,
                      selected: selected,
                      status: included == 0
                          ? null
                          : included == selectedComics.length
                          ? "Already in this collection".tl
                          : "Already included: @n / @total".tlParams({
                              'n': included,
                              'total': selectedComics.length,
                            }),
                      onTap: () =>
                          Navigator.of(context).pop(collection?.id ?? ''),
                      trailing: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: selected
                            ? context.colorScheme.primary
                            : context.colorScheme.outline,
                        size: 20,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectionTargetTile extends StatelessWidget {
  const _CollectionTargetTile({
    super.key,
    required this.collection,
    required this.onTap,
    required this.trailing,
    this.selected = false,
    this.status,
  });

  final ComicCollection? collection;
  final VoidCallback onTap;
  final Widget trailing;
  final bool selected;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final collection = this.collection;
    final name = collection?.displayName ?? "New collection".tl;
    final cover = collection?.displayCover ?? '';
    final placeholder = ColoredBox(
      color: context.colorScheme.secondaryContainer,
      child: Center(
        child: Icon(
          collection == null ? Icons.add : Icons.collections_bookmark_outlined,
          color: context.colorScheme.onSecondaryContainer,
        ),
      ),
    );
    final radius = BorderRadius.circular(12);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? context.colorScheme.secondaryContainer
            : context.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: selected
                ? context.colorScheme.primary
                : context.colorScheme.outlineVariant,
          ),
        ),
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    width: 44,
                    height: collection == null ? 40 : 60,
                    child: cover.isEmpty
                        ? placeholder
                        : Image(
                            image: ResizeImage(
                              CachedImageProvider(
                                cover,
                                sourceKey: collection!.sourceKey,
                                cid: collection.id,
                              ),
                              width:
                                  (44 * MediaQuery.devicePixelRatioOf(context))
                                      .ceil(),
                            ),
                            fit: BoxFit.cover,
                            excludeFromSemantics: true,
                            frameBuilder: (_, child, frame, _) =>
                                frame == null ? placeholder : child,
                            errorBuilder: (_, _, _) => placeholder,
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Tooltip(
                        message: name,
                        excludeFromSemantics: true,
                        child: Text(
                          name,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: ts.s14.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.3,
                          ),
                        ),
                      ),
                      if (collection != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          "@n comics".tlParams({
                            'n': collection.members.length,
                          }),
                          style: ts.s12.copyWith(
                            color: context.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      if (status != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          status!,
                          style: ts.s12.copyWith(
                            color: context.colorScheme.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

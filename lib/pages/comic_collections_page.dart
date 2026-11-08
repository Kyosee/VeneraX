import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/comic_collection_edit_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/guide_page.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// Deletes a collection and the traces it leaves behind.
///
/// Removing only the configuration would leave its favourite row and reading
/// history pointing at a source that no longer resolves — the row would still
/// render but open to an error, with no way to clear it from the favourites
/// screen (its "delete" acts on the comic, which is exactly what's gone).
/// Member comics and their own history are untouched.
void deleteComicCollection(ComicCollection collection) {
  final type = ComicType.fromKey(collection.sourceKey);
  for (final folder in LocalFavoritesManager().find(collection.id, type)) {
    LocalFavoritesManager().deleteComicWithId(folder, collection.id, type);
  }
  HistoryManager().remove(collection.id, type);
  ReadLaterManager().remove(collection.id, type);
  // A cover picked from a file lives in our own data directory, so deleting the
  // collection has to take it along or it stays there for good.
  try {
    final dir = Directory(
      FilePath.join(App.dataPath, ComicCollectionStore.coverDirName),
    );
    if (dir.existsSync()) {
      for (final e in dir.listSync()) {
        if (e is File && e.name.startsWith('${collection.id}_')) {
          e.deleteIgnoreError();
        }
      }
    }
  } catch (e) {
    // A leftover cover file is not worth failing the delete over.
    Log.error('ComicCollection', 'Cover cleanup failed: $e');
  }
  ComicCollectionStore.remove(collection.id);
}

/// Lists the user's comic collections: open one as a comic, edit its members,
/// reorder or delete it.
///
/// A collection groups comics that belong to one story but were published (or
/// scraped) as separate entries — volumes, parts, seasons — so they can be read
/// as one comic with one chapter list.
class ComicCollectionsPage extends StatefulWidget {
  const ComicCollectionsPage({super.key});

  @override
  State<ComicCollectionsPage> createState() => _ComicCollectionsPageState();
}

class _ComicCollectionsPageState extends State<ComicCollectionsPage>
    with SelectionMixin<ComicCollectionsPage, Comic> {
  List<ComicCollection> collections = const [];
  final searchTextController = TextEditingController();
  var keyword = '';
  var sortMode = 'manual';

  @override
  void initState() {
    super.initState();
    _reload();
    // Picks up edits made elsewhere (the detail page's tab menu, a member cache
    // filled by a background load, a sync download).
    ComicCollectionStore.changes.addListener(_reload);
  }

  @override
  void dispose() {
    ComicCollectionStore.changes.removeListener(_reload);
    searchTextController.dispose();
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      collections = ComicCollectionStore.all();
      _pruneSelection();
      if (collections.isEmpty) multiSelectMode = false;
    });
  }

  void _pruneSelection() {
    final visible = selectableItems.toSet();
    selectedItems.removeWhere((comic, _) => !visible.contains(comic));
  }

  void _enterSelectMode(Comic comic) {
    setState(() {
      multiSelectMode = true;
      selectedItems = {comic: true};
    });
  }

  /// Re-registers the native sources after any change: the built source captures
  /// the collection's layout, so a stale one would keep serving the old chapter
  /// list (or linger after a delete).
  void _applyChange() {
    ComicSourceManager().refreshCollectionSources();
    _reload();
  }

  void _open(ComicCollection collection) {
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: collection.id,
        sourceKey: collection.sourceKey,
        cover: collection.displayCover,
        title: collection.displayName,
      ),
    );
  }

  void _edit(ComicCollection collection) async {
    await context.to(
      () => ComicCollectionEditPage(collectionId: collection.id),
    );
    if (mounted) _applyChange();
  }

  void _create() {
    showInputDialog(
      context: context,
      title: "New collection".tl,
      hintText: "Collection name".tl,
      onConfirm: (value) {
        final name = value.trim();
        if (name.isEmpty) return "Please enter a name".tl;
        final collection = ComicCollectionStore.create(name: name);
        _applyChange();
        // Straight into the editor: an empty collection is useless, so the next
        // thing the user needs is the add-comics screen.
        _edit(collection);
        return null;
      },
    );
  }

  void _delete(ComicCollection collection) {
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content: "Delete collection '@n'? The comics in it are kept.".tlParams({
        "n": collection.displayName,
      }),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        deleteComicCollection(collection);
        _applyChange();
      },
    );
  }

  List<ComicCollection> get filteredCollections {
    final query = keyword.trim().toLowerCase();
    final result = collections.where((collection) {
      if (query.isEmpty) return true;
      return collection.displayName.toLowerCase().contains(query) ||
          collection.members.any(
            (member) => member.label.toLowerCase().contains(query),
          );
    }).toList();
    switch (sortMode) {
      case 'name':
        result.sort(
          (a, b) => a.displayName.toLowerCase().compareTo(
            b.displayName.toLowerCase(),
          ),
        );
        break;
      case 'count':
        result.sort((a, b) => b.members.length.compareTo(a.members.length));
        break;
      case 'created':
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
    }
    return result;
  }

  @override
  List<Comic> get selectableItems => filteredCollections
      .map(_asComic)
      .where((comic) => isBlocked(comic) == null)
      .toList();

  List<ComicCollection> get selectedCollections => filteredCollections
      .where((collection) => selectedItems.containsKey(_asComic(collection)))
      .toList();

  void _deleteSelected() {
    final selected = selectedCollections;
    if (selected.isEmpty) return;
    showConfirmDialog(
      context: context,
      title: 'Delete'.tl,
      content: 'Delete @c collections? The comics in them are kept.'.tlParams({
        'c': selected.length,
      }),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        for (final collection in selected) {
          deleteComicCollection(collection);
        }
        exitSelectMode();
        _applyChange();
        if (mounted) {
          showToast(
            context: context,
            message: 'Deleted @c items'.tlParams({'c': selected.length}),
          );
        }
      },
    );
  }

  Future<void> _addSelectedToReadLater() async {
    final comics = selectedCollections.map(_asComic).toList();
    if (comics.isEmpty) return;
    try {
      await ReadLaterManager().addComics(comics);
      if (!mounted) return;
      exitSelectMode();
      context.showMessage(message: 'Added to read later'.tl);
    } catch (error, stackTrace) {
      Log.error('ComicCollection', error, stackTrace);
      if (mounted) context.showMessage(message: 'Error'.tl);
    }
  }

  Comic _asComic(ComicCollection collection) => Comic(
    collection.displayName,
    collection.displayCover,
    collection.id,
    null,
    const ['Collection'],
    '@n comics'.tlParams({'n': collection.members.length}),
    collection.sourceKey,
    null,
    null,
  );

  String _sortLabel(String value) {
    switch (value) {
      case 'name':
        return 'Name'.tl;
      case 'count':
        return 'Comic count'.tl;
      case 'created':
        return 'Recently created'.tl;
      default:
        return 'Custom order'.tl;
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleComics = selectableItems;
    void handleBatchAction(String value) {
      switch (value) {
        case 'selectAll':
          selectAll();
          break;
        case 'deselect':
          deSelect();
          break;
        case 'invert':
          invertSelection();
          break;
        case 'delete':
          _deleteSelected();
          break;
        case 'favorite':
          final comics = selectedCollections.map(_asComic).toList();
          if (comics.isNotEmpty) addFavorite(comics);
          break;
        case 'readLater':
          _addSelectedToReadLater();
          break;
        case 'edit':
          final selected = selectedCollections;
          if (selected.length != 1) return;
          exitSelectMode();
          _edit(selected.single);
          break;
      }
    }

    final batchMenu = PopupMenuButton<String>(
      tooltip: 'Batch manage'.tl,
      icon: const Icon(Icons.more_vert),
      onSelected: handleBatchAction,
      itemBuilder: (context) => [
        PopupMenuItem(value: 'selectAll', child: Text('Select All'.tl)),
        PopupMenuItem(value: 'deselect', child: Text('Deselect'.tl)),
        PopupMenuItem(value: 'invert', child: Text('Invert Selection'.tl)),
        PopupMenuItem(
          value: 'delete',
          enabled: selectedItems.isNotEmpty,
          child: Text('Delete'.tl),
        ),
        PopupMenuItem(
          value: 'favorite',
          enabled: selectedItems.isNotEmpty,
          child: Text('Add to favorites'.tl),
        ),
        PopupMenuItem(
          value: 'readLater',
          enabled: selectedItems.isNotEmpty,
          child: Text('Read later'.tl),
        ),
        if (selectedItems.length == 1)
          PopupMenuItem(value: 'edit', child: Text('Edit'.tl)),
      ],
    );
    final selectActions = context.width < 520
        ? [batchMenu]
        : [
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: 'Select All'.tl,
              onPressed: selectAll,
            ),
            IconButton(
              icon: const Icon(Icons.flip),
              tooltip: 'Invert Selection'.tl,
              onPressed: invertSelection,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete'.tl,
              onPressed: selectedItems.isEmpty ? null : _deleteSelected,
            ),
            batchMenu,
          ];
    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && multiSelectMode) exitSelectMode();
      },
      child: Scaffold(
        appBar: Appbar(
          leading: Tooltip(
            message: multiSelectMode ? 'Cancel'.tl : 'Back'.tl,
            child: IconButton(
              icon: multiSelectMode
                  ? const Icon(Icons.close)
                  : const Icon(Icons.arrow_back),
              onPressed: multiSelectMode ? exitSelectMode : () => context.pop(),
            ),
          ),
          title: multiSelectMode
              ? Text(selectedItems.length.toString())
              : Text('Collections'.tl),
          actions: [
            if (multiSelectMode)
              ...selectActions
            else ...[
              IconButton(
                tooltip: 'Multi-Select'.tl,
                icon: const Icon(Icons.checklist),
                onPressed: visibleComics.isEmpty
                    ? null
                    : () => setState(() => multiSelectMode = true),
              ),
              PopupMenuButton<String>(
                tooltip: 'Sort'.tl,
                icon: const Icon(Icons.sort),
                initialValue: sortMode,
                onSelected: (value) => setState(() => sortMode = value),
                itemBuilder: (context) => [
                  for (final value in ['manual', 'name', 'count', 'created'])
                    PopupMenuItem(value: value, child: Text(_sortLabel(value))),
                ],
              ),
              Tooltip(
                message: 'Guide'.tl,
                child: IconButton(
                  icon: const Icon(Icons.help_outline),
                  onPressed: () =>
                      GuidePage.open(context, anchor: GuideAnchor.collections),
                ),
              ),
              Tooltip(
                message: 'New collection'.tl,
                child: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _create,
                ),
              ),
            ],
          ],
        ),
        body: SmoothCustomScrollView(
          scrollbarTopPadding: context.padding.top + 56,
          slivers: [
            if (collections.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: AppSearchField(
                    controller: searchTextController,
                    onChanged: (value) => setState(() {
                      keyword = value;
                      _pruneSelection();
                    }),
                  ),
                ),
              ),
            if (collections.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _buildEmptyState(),
              )
            else if (visibleComics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text('No matching collections'.tl, style: ts.s16),
                ),
              )
            else
              SliverGridComics(
                comics: visibleComics,
                selections: selectedItems,
                enableContextMenu: !multiSelectMode,
                onLongPressed: multiSelectMode
                    ? (comic, heroID) => toggleSelect(comic)
                    : null,
                onTap: (comic, heroID) {
                  if (multiSelectMode) {
                    toggleSelect(comic);
                    return;
                  }
                  final collection = ComicCollectionStore.find(comic.id);
                  if (collection != null) _open(collection);
                },
                menuBuilder: (comic) {
                  final collection = ComicCollectionStore.find(comic.id);
                  if (collection == null) return const [];
                  final sourceIndex = collections.indexWhere(
                    (item) => item.id == collection.id,
                  );
                  return [
                    if (!multiSelectMode)
                      MenuEntry(
                        action: MenuAction.select,
                        icon: Icons.checklist,
                        text: 'Multi-Select'.tl,
                        onClick: () => _enterSelectMode(comic),
                      ),
                    MenuEntry(
                      group: MenuGroup.organize,
                      icon: Icons.edit,
                      text: 'Edit'.tl,
                      onClick: () => _edit(collection),
                    ),
                    MenuEntry(
                      action: MenuAction.remove,
                      destructive: true,
                      icon: Icons.delete_outline,
                      text: 'Delete'.tl,
                      color: context.colorScheme.error,
                      onClick: () => _delete(collection),
                    ),
                    if (sourceIndex > 0)
                      MenuEntry(
                        group: MenuGroup.organize,
                        icon: Icons.arrow_upward,
                        text: 'Move up'.tl,
                        onClick: () {
                          ComicCollectionStore.reorder(
                            sourceIndex,
                            sourceIndex - 1,
                          );
                          _applyChange();
                        },
                      ),
                    if (sourceIndex >= 0 &&
                        sourceIndex < collections.length - 1)
                      MenuEntry(
                        group: MenuGroup.organize,
                        icon: Icons.arrow_downward,
                        text: 'Move down'.tl,
                        onClick: () {
                          ComicCollectionStore.reorder(
                            sourceIndex,
                            sourceIndex + 1,
                          );
                          _applyChange();
                        },
                      ),
                  ];
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_books_outlined,
              size: 64,
              color: context.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text("No collections yet".tl, style: ts.s16),
            const SizedBox(height: 8),
            Text(
              "Group the volumes of one story into a single comic. Long-press a comic in any list to add it."
                  .tl,
              style: ts.s14.copyWith(color: context.colorScheme.outline),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: Text("New collection".tl),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () =>
                  GuidePage.open(context, anchor: GuideAnchor.collections),
              child: Text("Guide".tl),
            ),
          ],
        ),
      ),
    );
  }
}

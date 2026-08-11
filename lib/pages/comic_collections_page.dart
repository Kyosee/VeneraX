import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_collection_edit_page.dart';
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

class _ComicCollectionsPageState extends State<ComicCollectionsPage> {
  List<ComicCollection> collections = const [];

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
    super.dispose();
  }

  void _reload() {
    if (!mounted) return;
    setState(() {
      collections = ComicCollectionStore.all();
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
      content:
          "Delete collection '@n'? The comics in it are kept.".tlParams({
            "n": collection.displayName,
          }),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        deleteComicCollection(collection);
        _applyChange();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Collections".tl),
        actions: [
          Tooltip(
            message: "Guide".tl,
            child: IconButton(
              icon: const Icon(Icons.help_outline),
              onPressed: () =>
                  GuidePage.open(context, anchor: GuideAnchor.collections),
            ),
          ),
          Tooltip(
            message: "New collection".tl,
            child: IconButton(icon: const Icon(Icons.add), onPressed: _create),
          ),
        ],
      ),
      body: collections.isEmpty
          ? _buildEmptyState()
          : ReorderableListView.builder(
              padding: EdgeInsets.fromLTRB(
                12,
                8,
                12,
                context.padding.bottom + 8,
              ),
              buildDefaultDragHandles: false,
              onReorderItem: (oldIndex, newIndex) {
                ComicCollectionStore.reorder(oldIndex, newIndex);
                _applyChange();
              },
              itemCount: collections.length,
              itemBuilder: (context, index) =>
                  _buildCard(collections[index], index),
            ),
    );
  }

  Widget _buildCard(ComicCollection collection, int index) {
    final modeText = collection.displayMode == CollectionDisplayMode.tabs
        ? "Chapter tabs".tl
        : "Merged chapters".tl;
    return Container(
      key: ValueKey(collection.id),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: context.colorScheme.outlineVariant.toOpacity(0.5),
          width: 0.6,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(collection),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
          child: Row(
            children: [
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.drag_indicator,
                    color: context.colorScheme.outline,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      collection.displayName,
                      style: ts.s16,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${"@n comics".tlParams({'n': collection.members.length})}'
                      '  ·  $modeText',
                      style: ts.s12.copyWith(
                        color: context.colorScheme.outline,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MenuButton(
                entries: [
                  MenuEntry(
                    icon: Icons.chrome_reader_mode_outlined,
                    text: "Details".tl,
                    onClick: () => _open(collection),
                  ),
                  MenuEntry(
                    icon: Icons.edit,
                    text: "Edit".tl,
                    onClick: () => _edit(collection),
                  ),
                  MenuEntry(
                    icon: Icons.delete_outline,
                    text: "Delete".tl,
                    color: context.colorScheme.error,
                    onClick: () => _delete(collection),
                  ),
                ],
              ),
            ],
          ),
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
              "Group the volumes of one story into a single comic. Long-press a comic in any list to add it.".tl,
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

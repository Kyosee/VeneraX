part of 'components.dart';

/// Lets the user drop one or more comics into a collection, or start a new one.
///
/// Reachable from the list long-press menu, the swipe action and the detail
/// page, so it takes plain [Comic]s and does its own filtering: a collection can
/// never contain another collection (chapter loading would recurse), and adding
/// a comic twice is a no-op rather than a duplicate chapter run.
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
    builder: (context) {
      return _AddToCollectionDialog(comics: eligible);
    },
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

  @override
  void initState() {
    super.initState();
    collections = ComicCollectionStore.all();
  }

  List<CollectionMember> get _members => widget.comics
      .map(
        (c) => CollectionMember(
          sourceKey: c.sourceKey,
          comicId: c.id,
          cachedTitle: c.title,
          cachedSubtitle: c.subtitle ?? '',
          cachedCover: c.cover,
        ),
      )
      .toList();

  void _addTo(ComicCollection collection) {
    final added = ComicCollectionStore.addMembers(collection.id, _members);
    // The source captures the chapter layout, so it has to be rebuilt whenever
    // membership changes or the collection would keep serving the old list.
    ComicSourceManager().refreshCollectionSources();
    context.pop();
    App.rootContext.showMessage(
      message: added == 0
          ? "Already in this collection".tl
          : "Added @n comics to @c".tlParams({
              'n': added,
              'c': collection.displayName,
            }),
    );
  }

  void _createNew() {
    // Named after the first comic by default: the common case is "these three
    // are one story", and that story's name is usually the first one's title.
    final suggested = widget.comics.first.title;
    showInputDialog(
      context: context,
      title: "New collection".tl,
      hintText: "Collection name".tl,
      initialValue: suggested,
      onConfirm: (value) {
        final collection = ComicCollectionStore.create(
          name: value.toString().trim(),
          members: _members,
        );
        ComicSourceManager().refreshCollectionSources();
        // Pops the input dialog's parent too, so the user lands back where they
        // started rather than on a stale picker.
        Navigator.of(context).pop();
        App.rootContext.showMessage(
          message: "Created @c".tlParams({'c': collection.displayName}),
        );
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Add to collection".tl,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: Text("New collection".tl),
            onTap: _createNew,
          ),
          if (collections.isNotEmpty) const Divider(height: 1),
          // Bounded so a user with many collections gets a scrollable list
          // instead of a dialog taller than the screen.
          if (collections.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (MediaQuery.of(context).size.height * 0.4).clamp(
                  120.0,
                  320.0,
                ),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: collections.length,
                itemBuilder: (context, index) {
                  final c = collections[index];
                  // Tells the user up front that tapping would be a no-op.
                  final already = widget.comics.every(
                    (comic) => c.contains(comic.sourceKey, comic.id),
                  );
                  return ListTile(
                    title: Text(
                      c.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      "@n comics".tlParams({'n': c.members.length}),
                    ),
                    trailing: already
                        ? Icon(
                            Icons.check,
                            color: context.colorScheme.primary,
                          )
                        : null,
                    onTap: already ? null : () => _addTo(c),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

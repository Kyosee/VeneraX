import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

class ReadLaterPage extends StatefulWidget {
  const ReadLaterPage({super.key});

  @override
  State<ReadLaterPage> createState() => _ReadLaterPageState();
}

class _ReadLaterPageState extends State<ReadLaterPage>
    with SelectionMixin<ReadLaterPage, ReadLaterItem> {
  @override
  void initState() {
    ReadLaterManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    ReadLaterManager().removeListener(onUpdate);
    searchTextController.dispose();
    super.dispose();
  }

  void onUpdate() {
    if (!mounted) return;
    setState(() {
      comics = ReadLaterManager().getAll();
      if (multiSelectMode) {
        selectedItems.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedItems.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  var comics = ReadLaterManager().getAll();
  var controller = FlyoutController();
  var searchTextController = TextEditingController();
  var keyword = "";

  @override
  List<ReadLaterItem> get selectableItems => filteredComics;

  List<ReadLaterItem> get filteredComics {
    return comics.where((comic) {
      var kw = keyword.trim().toLowerCase();
      if (kw.isEmpty) {
        return true;
      }
      return comic.title.toLowerCase().contains(kw) ||
          (comic.subtitle?.toLowerCase().contains(kw) ?? false) ||
          sourceLabel(comic.sourceKey).toLowerCase().contains(kw);
    }).toList();
  }

  String sourceLabel(String sourceKey) {
    if (sourceKey == 'local') {
      return 'Local'.tl;
    }
    if (sourceKey.startsWith('Unknown:')) {
      return sourceKey;
    }
    return ComicSource.find(sourceKey)?.name ?? sourceKey;
  }

  void _removeWithConfirm(List<ReadLaterItem> items) {
    if (items.isEmpty) {
      return;
    }
    showConfirmDialog(
      context: context,
      title: "Delete".tl,
      content: "Delete @c items?".tlParams({"c": items.length}),
      btnColor: context.colorScheme.error,
      onConfirm: () {
        var removed = List<ReadLaterItem>.from(items);
        setState(() {
          multiSelectMode = false;
          selectedItems.clear();
        });
        ReadLaterManager().removeMultiple(removed);
        if (mounted) {
          showToast(
            context: context,
            message: "Deleted @c items".tlParams({"c": removed.length}),
            trailing: TextButton(
              onPressed: () {
                ReadLaterManager().addMultiple(removed);
              },
              child: Text("Undo".tl),
            ),
          );
        }
      },
    );
  }

  void _removeSingle(ReadLaterItem comic) {
    ReadLaterManager().remove(comic.id, comic.type);
  }

  /// Swipe-delete: removes the item (which also clears its read-later status,
  /// since the status is derived from the table) and offers an undo.
  void _removeSwipe(ReadLaterItem comic) {
    var removed = comic;
    ReadLaterManager().remove(removed.id, removed.type);
    if (mounted) {
      showToast(
        context: context,
        message: "Deleted @c items".tlParams({"c": 1}),
        trailing: TextButton(
          onPressed: () {
            ReadLaterManager().addItem(removed);
          },
          child: Text("Undo".tl),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedItems.isEmpty
            ? null
            : () => _removeWithConfirm(
                List<ReadLaterItem>.from(selectedItems.keys),
              ),
      ),
      MenuButton(
        entries: [
          MenuEntry(
            icon: Icons.favorite_border,
            text: "Add to favorites".tl,
            onClick: () {
              if (selectedItems.isEmpty) return;
              addFavorite(List<ReadLaterItem>.from(selectedItems.keys));
            },
          ),
        ],
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear Read Later'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear Read Later'.tl,
              content: Text(
                'Are you sure you want to clear your read later list?'.tl,
              ),
              actions: [
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    ReadLaterManager().clearAll();
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          exitSelectMode();
        }
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          scrollbar: true,
          scrollbarTopPadding: context.padding.top + 56,
          slivers: [
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      exitSelectMode();
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedItems.length.toString())
                  : Text('Read Later'.tl),
              actions: multiSelectMode ? selectActions : normalActions,
            ),
            if (!multiSelectMode)
              SliverToBoxAdapter(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: TextField(
                    decoration: InputDecoration(
                      icon: const Icon(Icons.search),
                      hintText: "Search".tl,
                      border: InputBorder.none,
                      suffixIcon: keyword.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                setState(() {
                                  keyword = "";
                                  searchTextController.clear();
                                });
                              },
                            ),
                    ),
                    controller: searchTextController,
                    onChanged: (value) {
                      setState(() {
                        keyword = value;
                        selectedItems.removeWhere(
                          (comic, _) => !filteredComics.contains(comic),
                        );
                      });
                    },
                  ),
                ),
              ),
            if (filteredComics.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    comics.isEmpty ? "No items".tl : "No matching items".tl,
                    style: ts.s16,
                  ),
                ),
              )
            else
              SliverGridComics(
                comics: filteredComics,
                selections: selectedItems,
                onLongPressed: null,
                swipeActionBuilder: multiSelectMode
                    ? null
                    : (c) => (
                          start: null,
                          end: SwipePane(
                            dismissOnFullSwipe: true,
                            onFullSwipe: () =>
                                _removeSwipe(c as ReadLaterItem),
                            actions: [
                              SwipeAction(
                                icon: Icons.delete_outline,
                                label: 'Delete'.tl,
                                onPressed: () =>
                                    _removeSwipe(c as ReadLaterItem),
                              ),
                            ],
                          ),
                        ),
                onTap: multiSelectMode
                    ? (c, heroID) {
                        toggleSelect(c as ReadLaterItem);
                      }
                    : null,
                badgeBuilder: (c) {
                  return ComicSource.find(c.sourceKey)?.name;
                },
                menuBuilder: (c) {
                  return [
                    MenuEntry(
                      icon: Icons.favorite_border,
                      text: 'Add to favorites'.tl,
                      onClick: () {
                        addFavorite([c as ReadLaterItem]);
                      },
                    ),
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: 'Remove'.tl,
                      color: context.colorScheme.error,
                      onClick: () {
                        _removeSingle(c as ReadLaterItem);
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
}





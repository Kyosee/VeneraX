part of 'components.dart';

/// Shared multi-select state machine for grid/list pages.
///
/// Owns the [multiSelectMode] flag and the [selectedItems] map (keyed by the
/// page's own item type; the value is always `true`, the map is used as a set
/// to stay compatible with [SliverGridComics.selections]). Pages provide
/// [selectableItems] — the currently visible/filtered subset a "select all"
/// should range over — and get the toggle/select-all/invert/exit actions for
/// free. Build methods keep referencing [multiSelectMode]/[selectedItems]
/// directly, so adopting this mixin is mostly deleting the old local copy.
mixin SelectionMixin<T extends StatefulWidget, K extends Object> on State<T> {
  bool multiSelectMode = false;

  Map<K, bool> selectedItems = {};

  /// Items a "Select All" / "Invert Selection" should cover — usually the
  /// filtered or visible subset, not the full backing list.
  List<K> get selectableItems;

  void selectAll() {
    setState(() {
      selectedItems = {for (final item in selectableItems) item: true};
    });
  }

  void deSelect() {
    setState(() {
      selectedItems.clear();
    });
  }

  void invertSelection() {
    setState(() {
      for (final item in selectableItems) {
        if (selectedItems.remove(item) == null) {
          selectedItems[item] = true;
        }
      }
      selectedItems.removeWhere((_, selected) => !selected);
    });
  }

  /// Toggle one item while selecting; leaves multi-select mode once nothing is
  /// selected (matches the long-standing per-page behavior).
  void toggleSelect(K item) {
    setState(() {
      if (selectedItems.remove(item) == null) {
        selectedItems[item] = true;
      }
      if (selectedItems.isEmpty) {
        multiSelectMode = false;
      }
    });
  }

  /// Leave multi-select mode and drop the current selection.
  void exitSelectMode() {
    setState(() {
      multiSelectMode = false;
      selectedItems.clear();
    });
  }
}

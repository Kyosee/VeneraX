/// Parent/child layout of the local favorite folders.
///
/// Folders stay flat tables named after the folder; the layout is a side table
/// of child → parent links. A link whose parent is gone (renamed or deleted by
/// a version without nesting), or that would close a loop, is ignored, so the
/// folder simply shows at the top level instead of disappearing.
class FavoriteFolderTree {
  FavoriteFolderTree._(
    this.ordered,
    this._parents,
    this._children,
    this._depths,
  ) : _index = {for (var i = 0; i < ordered.length; i++) ordered[i]: i};

  static final empty = FavoriteFolderTree.build(const [], const {});

  /// Every folder, each followed by its subfolders (pre-order).
  final List<String> ordered;

  final Map<String, String> _parents;
  final Map<String?, List<String>> _children;
  final Map<String, int> _depths;
  final Map<String, int> _index;

  /// [folders] in stored order, which is also the order among siblings.
  /// [links] maps a folder to its parent.
  factory FavoriteFolderTree.build(
    List<String> folders,
    Map<String, String> links,
  ) {
    final known = folders.toSet();
    final parents = <String, String>{};
    for (final folder in known) {
      final parent = links[folder];
      if (parent != null && parent != folder && known.contains(parent)) {
        parents[folder] = parent;
      }
    }
    // Cut every loop at its first member in stored order.
    for (final folder in known) {
      final seen = <String>{};
      var current = parents[folder];
      while (current != null && seen.add(current)) {
        if (current == folder) {
          parents.remove(folder);
          break;
        }
        current = parents[current];
      }
    }
    final children = <String?, List<String>>{};
    for (final folder in known) {
      (children[parents[folder]] ??= []).add(folder);
    }
    final ordered = <String>[];
    final depths = <String, int>{};
    void visit(String folder, int depth) {
      ordered.add(folder);
      depths[folder] = depth;
      for (final child in children[folder] ?? const <String>[]) {
        visit(child, depth + 1);
      }
    }

    for (final root in children[null] ?? const <String>[]) {
      visit(root, 0);
    }
    return FavoriteFolderTree._(
      List.unmodifiable(ordered),
      parents,
      {for (final e in children.entries) e.key: List.unmodifiable(e.value)},
      depths,
    );
  }

  bool contains(String folder) => _index.containsKey(folder);

  String? parentOf(String folder) => _parents[folder];

  /// Direct subfolders of [folder]; null lists the top level.
  List<String> childrenOf(String? folder) => _children[folder] ?? const [];

  bool hasChildren(String folder) => _children[folder]?.isNotEmpty ?? false;

  int depthOf(String folder) => _depths[folder] ?? 0;

  /// Subfolders of [folder] at every depth, in display order.
  List<String> descendantsOf(String folder) {
    final start = _index[folder];
    if (start == null) return const [];
    final depth = _depths[folder]!;
    var end = start + 1;
    while (end < ordered.length && _depths[ordered[end]]! > depth) {
      end++;
    }
    return ordered.sublist(start + 1, end);
  }

  /// [folder] and its ancestors, outermost first.
  List<String> pathOf(String folder) {
    if (!contains(folder)) return const [];
    final path = [folder];
    for (var p = _parents[folder]; p != null; p = _parents[p]) {
      path.add(p);
    }
    return path.reversed.toList();
  }

  /// Whether [folder] may move under [parent] (null for the top level). A
  /// folder can't move into itself or one of its own subfolders.
  bool canMove(String folder, String? parent) {
    if (!contains(folder)) return false;
    if (parent == null) return true;
    if (!contains(parent)) return false;
    for (String? p = parent; p != null; p = _parents[p]) {
      if (p == folder) return false;
    }
    return true;
  }

  /// A modifiable copy of every child list, keyed by parent.
  Map<String?, List<String>> childLists() => {
    for (final e in _children.entries) e.key: [...e.value],
  };

  /// Pre-order of [children], starting from the top level.
  static List<String> flatten(Map<String?, List<String>> children) {
    final result = <String>[];
    final seen = <String>{};
    void visit(String? folder) {
      for (final child in children[folder] ?? const <String>[]) {
        if (seen.add(child)) {
          result.add(child);
          visit(child);
        }
      }
    }

    visit(null);
    return result;
  }
}

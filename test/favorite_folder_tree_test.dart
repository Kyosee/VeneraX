import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/favorite_folder_tree.dart';

void main() {
  test('lists every folder before its subfolders, in stored order', () {
    var tree = FavoriteFolderTree.build(
      ['A', 'B', 'A1', 'A2', 'A1x'],
      {'A1': 'A', 'A2': 'A', 'A1x': 'A1'},
    );
    expect(tree.ordered, ['A', 'A1', 'A1x', 'A2', 'B']);
    expect(tree.childrenOf(null), ['A', 'B']);
    expect(tree.childrenOf('A'), ['A1', 'A2']);
    expect(tree.depthOf('A1x'), 2);
    expect(tree.parentOf('A'), isNull);
    expect(tree.hasChildren('A2'), isFalse);
  });

  test('a link to a missing parent or to itself is ignored', () {
    var tree = FavoriteFolderTree.build(
      ['A', 'B'],
      {'A': 'gone', 'B': 'B', 'gone': 'A'},
    );
    expect(tree.ordered, ['A', 'B']);
    expect(tree.parentOf('A'), isNull);
    expect(tree.parentOf('B'), isNull);
    expect(tree.contains('gone'), isFalse);
  });

  test('a loop is cut at its first folder in stored order', () {
    var tree = FavoriteFolderTree.build(
      ['X', 'A', 'B', 'C'],
      {'A': 'B', 'B': 'A', 'C': 'A'},
    );
    expect(tree.parentOf('A'), isNull);
    expect(tree.parentOf('B'), 'A');
    expect(tree.parentOf('C'), 'A');
    expect(tree.ordered, ['X', 'A', 'B', 'C']);

    var longer = FavoriteFolderTree.build(
      ['C', 'A', 'B'],
      {'A': 'B', 'B': 'C', 'C': 'A'},
    );
    expect(longer.ordered, ['C', 'B', 'A']);
    expect(longer.depthOf('A'), 2);
  });

  test('descendants, paths and allowed moves', () {
    var tree = FavoriteFolderTree.build(
      ['A', 'B', 'A1', 'A1x'],
      {'A1': 'A', 'A1x': 'A1'},
    );
    expect(tree.descendantsOf('A'), ['A1', 'A1x']);
    expect(tree.descendantsOf('B'), isEmpty);
    expect(tree.descendantsOf('missing'), isEmpty);
    expect(tree.pathOf('A1x'), ['A', 'A1', 'A1x']);
    expect(tree.canMove('A', 'A'), isFalse);
    expect(tree.canMove('A', 'A1x'), isFalse);
    expect(tree.canMove('A1x', 'B'), isTrue);
    expect(tree.canMove('A1', null), isTrue);
    expect(tree.canMove('A1', 'missing'), isFalse);
  });

  test('flatten walks child lists from the top level', () {
    var tree = FavoriteFolderTree.build(['A', 'B', 'A1'], {'A1': 'A'});
    var children = tree.childLists();
    children[null]!.remove('B');
    (children['A1'] ??= []).add('B');
    expect(FavoriteFolderTree.flatten(children), ['A', 'A1', 'B']);
    // The tree itself is untouched.
    expect(tree.childrenOf(null), ['A', 'B']);
  });
}

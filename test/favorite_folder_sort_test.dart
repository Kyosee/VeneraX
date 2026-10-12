import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/favorites/favorites_page.dart';

/// #247: the sort choice was one global value shared by every folder.
void main() {
  group('FavoriteFolderSort', () {
    test('a folder without an override follows the global value', () {
      var data = <String, dynamic>{FavoriteFolderSort.globalKey: 'name'};
      expect(FavoriteFolderSort.read(data, 'A'), LocalSortType.name);
      expect(FavoriteFolderSort.read({}, 'A'), LocalSortType.defaultSort);
    });

    test('folders keep independent sort choices', () {
      var data = <String, dynamic>{FavoriteFolderSort.globalKey: 'name'};
      FavoriteFolderSort.setFolder(data, 'A', LocalSortType.name);
      FavoriteFolderSort.setFolder(data, 'B', LocalSortType.lastRead);
      FavoriteFolderSort.setFolder(
        data,
        localAllFolderLabel,
        LocalSortType.timeDesc,
      );
      expect(FavoriteFolderSort.read(data, 'A'), LocalSortType.name);
      expect(FavoriteFolderSort.read(data, 'B'), LocalSortType.lastRead);
      expect(
        FavoriteFolderSort.read(data, localAllFolderLabel),
        LocalSortType.timeDesc,
      );
      expect(FavoriteFolderSort.read(data, 'C'), LocalSortType.name);
    });

    test('applying to all folders drops every override', () {
      var data = <String, dynamic>{};
      FavoriteFolderSort.setFolder(data, 'A', LocalSortType.name);
      FavoriteFolderSort.setGlobal(data, LocalSortType.author);
      expect(FavoriteFolderSort.read(data, 'A'), LocalSortType.author);
      expect(FavoriteFolderSort.read(data, 'B'), LocalSortType.author);
    });

    test('rename moves the override, delete clears it', () {
      var data = <String, dynamic>{};
      FavoriteFolderSort.setFolder(data, 'A', LocalSortType.lastRead);
      expect(FavoriteFolderSort.rename(data, 'A', 'A2'), isTrue);
      expect(FavoriteFolderSort.read(data, 'A2'), LocalSortType.lastRead);
      expect(FavoriteFolderSort.read(data, 'A'), LocalSortType.defaultSort);
      expect(FavoriteFolderSort.rename(data, 'X', 'Y'), isFalse);

      expect(FavoriteFolderSort.remove(data, 'A2'), isTrue);
      expect(FavoriteFolderSort.read(data, 'A2'), LocalSortType.defaultSort);
      expect(FavoriteFolderSort.remove(data, 'A2'), isFalse);
    });

    test('accepts a non-String-keyed map loaded from storage', () {
      var data = <String, dynamic>{
        FavoriteFolderSort.folderKey: <dynamic, dynamic>{'A': 'name_desc'},
      };
      expect(FavoriteFolderSort.read(data, 'A'), LocalSortType.nameDesc);
      FavoriteFolderSort.setFolder(data, 'B', LocalSortType.timeAsc);
      expect(FavoriteFolderSort.read(data, 'A'), LocalSortType.nameDesc);
      expect(FavoriteFolderSort.read(data, 'B'), LocalSortType.timeAsc);
    });
  });
}

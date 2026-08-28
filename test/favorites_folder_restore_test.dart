import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/favorites/favorites_page.dart';

/// Regression guard: selecting the local "All" folder, then leaving the
/// favorites tab (its state is disposed — the nav pane builds only the current
/// page) or restarting the app came back as "Unselected".
///
/// The restore path validated the persisted name against
/// `LocalFavoritesManager.folderNames`, but "All" is the sentinel
/// `^_^[%local_all%]^_^` rather than a real folder table, so it is never in that
/// list and the guard cleared it every time. User-created folders survived
/// because they do exist there.
void main() {
  bool Function(String) exists(Set<String> folders) => folders.contains;

  group('restoreFavoriteFolder', () {
    test('keeps the local "All" sentinel even though it is not a real folder', () {
      var restored = restoreFavoriteFolder(
        {'name': localAllFolderLabel, 'isNetwork': false},
        exists({'Reading'}),
      );
      expect(restored.folder, localAllFolderLabel);
      expect(restored.isNetwork, isFalse);
    });

    test('keeps an existing user folder', () {
      var restored = restoreFavoriteFolder(
        {'name': 'Reading', 'isNetwork': false},
        exists({'Reading'}),
      );
      expect(restored.folder, 'Reading');
      expect(restored.isNetwork, isFalse);
    });

    test('drops a local folder that no longer exists', () {
      var restored = restoreFavoriteFolder(
        {'name': 'Deleted', 'isNetwork': false},
        exists({'Reading'}),
      );
      expect(restored.folder, isNull);
      expect(restored.isNetwork, isFalse);
    });

    test('keeps a network folder without consulting local folders', () {
      var restored = restoreFavoriteFolder(
        {'name': 'some_source', 'isNetwork': true},
        (_) => fail('local folders must not be consulted for network folders'),
      );
      expect(restored.folder, 'some_source');
      expect(restored.isNetwork, isTrue);
    });

    test('nothing persisted yet', () {
      var restored = restoreFavoriteFolder(null, exists({'Reading'}));
      expect(restored.folder, isNull);
      expect(restored.isNetwork, isFalse);
    });

    test('missing isNetwork defaults to local', () {
      var restored = restoreFavoriteFolder(
        {'name': localAllFolderLabel},
        exists(const {}),
      );
      expect(restored.folder, localAllFolderLabel);
      expect(restored.isNetwork, isFalse);
    });

    test('a malformed entry falls back instead of throwing', () {
      var restored = restoreFavoriteFolder(
        {'name': 123, 'isNetwork': 'yes'},
        exists({'Reading'}),
      );
      expect(restored.folder, isNull);
      expect(restored.isNetwork, isFalse);
    });
  });
}

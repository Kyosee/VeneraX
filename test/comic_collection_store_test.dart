import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/collection_source.dart';

/// Covers the parts of the collection model that need no settings storage:
/// payload sanitising, the name/cover fallbacks and the source-key predicate.
/// Reading or writing the store itself would hit real file IO, so it is left to
/// manual verification (same policy as the WebDAV library store tests).
void main() {
  group('isCollectionSourceKey', () {
    test('recognises only collection keys', () {
      expect(
        ComicCollectionStore.isCollectionSourceKey('comic_collection_ab12'),
        isTrue,
      );
      expect(ComicCollectionStore.isCollectionSourceKey('local'), isFalse);
      expect(
        ComicCollectionStore.isCollectionSourceKey('webdav_library_ab12'),
        isFalse,
      );
      expect(ComicCollectionStore.isCollectionSourceKey(null), isFalse);
    });
  });

  group('ComicCollection.fromJson', () {
    Map<String, dynamic> member(String source, String id) => {
      'sourceKey': source,
      'comicId': id,
    };

    test('drops a nested collection member', () {
      // A collection inside a collection would recurse on chapter load. The add
      // path rejects it, but settings travel between devices and a hand-edited
      // or foreign payload could still carry one.
      final c = ComicCollection.fromJson({
        'id': 'x',
        'sourceKey': 'comic_collection_x',
        'members': [
          member('jm', '1'),
          member('comic_collection_other', 'y'),
          member('local', '2'),
        ],
      });
      expect(c.members.map((e) => e.sourceKey), ['jm', 'local']);
    });

    test('drops duplicates and blanks', () {
      final c = ComicCollection.fromJson({
        'id': 'x',
        'members': [
          member('jm', '1'),
          member('jm', '1'),
          member('', '1'),
          member('jm', ''),
          member('jm', '2'),
        ],
      });
      expect(c.members.map((e) => e.refKey), ['jm/1', 'jm/2']);
    });

    test('keeps the same comic id from two different sources', () {
      // Sources allocate ids independently, so identity is the pair.
      final c = ComicCollection.fromJson({
        'id': 'x',
        'members': [member('a', '1'), member('b', '1')],
      });
      expect(c.members.length, 2);
    });

    test('derives a source key when an older payload lacks one', () {
      final c = ComicCollection.fromJson({'id': 'ab12', 'members': []});
      expect(c.sourceKey, 'comic_collection_ab12');
    });

    test('defaults to flat mode for an unknown or missing mode', () {
      expect(
        ComicCollection.fromJson({'id': 'x'}).displayMode,
        CollectionDisplayMode.flat,
      );
      expect(
        ComicCollection.fromJson({'id': 'x', 'displayMode': 'nonsense'})
            .displayMode,
        CollectionDisplayMode.flat,
      );
      expect(
        ComicCollection.fromJson({'id': 'x', 'displayMode': 'tabs'})
            .displayMode,
        CollectionDisplayMode.tabs,
      );
    });

    test('survives a payload with no member list at all', () {
      final c = ComicCollection.fromJson({'id': 'x', 'members': 'garbage'});
      expect(c.members, isEmpty);
    });

    test('hands out a mutable member list even when empty', () {
      // The store edits members in place before writing back; a const literal
      // here threw "Cannot add to an unmodifiable list" on the first edit.
      final c = ComicCollection.fromJson({'id': 'x'});
      expect(
        () => c.members.add(
          CollectionMember(sourceKey: 's', comicId: '1'),
        ),
        returnsNormally,
      );
      expect(() => c.members.removeAt(0), returnsNormally);
    });

    test('round-trips through json', () {
      final original = ComicCollection.fromJson({
        'id': 'x',
        'sourceKey': 'comic_collection_x',
        'name': 'Trilogy',
        'customCover': 'https://example.com/c.jpg',
        'displayMode': 'tabs',
        'members': [
          {
            'sourceKey': 'jm',
            'comicId': '1',
            'displayName': 'Part 1',
            'cachedTitle': 'T1',
            'cachedCover': 'c1',
          },
        ],
        'createdAt': 1234,
      });
      final copy = ComicCollection.fromJson(original.toJson());
      expect(copy.id, 'x');
      expect(copy.sourceKey, 'comic_collection_x');
      expect(copy.name, 'Trilogy');
      expect(copy.customCover, 'https://example.com/c.jpg');
      expect(copy.displayMode, CollectionDisplayMode.tabs);
      expect(copy.members.single.displayName, 'Part 1');
      expect(copy.members.single.cachedTitle, 'T1');
      expect(copy.createdAt.millisecondsSinceEpoch, 1234);
    });
  });

  group('display fallbacks', () {
    ComicCollection build({
      String name = '',
      String cover = '',
      List<Map<String, dynamic>> members = const [],
    }) => ComicCollection.fromJson({
      'id': 'x',
      'name': name,
      'customCover': cover,
      'members': members,
    });

    test('name falls back to the first member with a cached title', () {
      final c = build(
        members: [
          {'sourceKey': 'a', 'comicId': '1'},
          {'sourceKey': 'b', 'comicId': '2', 'cachedTitle': 'Second'},
        ],
      );
      expect(c.displayName, 'Second');
    });

    test('a user-set name wins over member titles', () {
      final c = build(
        name: '  Mine  ',
        members: [
          {'sourceKey': 'a', 'comicId': '1', 'cachedTitle': 'Theirs'},
        ],
      );
      expect(c.displayName, 'Mine');
    });

    test('cover falls back to the first member that has one', () {
      final c = build(
        members: [
          {'sourceKey': 'a', 'comicId': '1'},
          {'sourceKey': 'b', 'comicId': '2', 'cachedCover': 'cover-b'},
        ],
      );
      expect(c.displayCover, 'cover-b');
      // Image loading needs to know whose auth headers to use for that cover.
      expect(c.coverOwner?.sourceKey, 'b');
    });

    test('a user-set cover is loaded plainly, with no owner', () {
      final c = build(
        cover: 'mine.jpg',
        members: [
          {'sourceKey': 'a', 'comicId': '1', 'cachedCover': 'theirs.jpg'},
        ],
      );
      expect(c.displayCover, 'mine.jpg');
      expect(c.coverOwner, isNull);
    });

    test('an empty collection still renders', () {
      final c = build();
      expect(c.displayName, 'x');
      expect(c.displayCover, '');
      expect(c.coverOwner, isNull);
    });
  });

  group('cover resolution', () {
    test('reports the borrowing member so its auth headers can be used', () {
      final c = ComicCollection.fromJson({
        'id': 'x',
        'members': [
          {'sourceKey': 'webdav_library_a', 'comicId': '1'},
          {
            'sourceKey': 'webdav_library_b',
            'comicId': '2',
            'cachedCover': 'http://b/c.jpg',
          },
        ],
      });
      expect(c.displayCover, 'http://b/c.jpg');
      expect(c.coverOwner?.sourceKey, 'webdav_library_b');
    });

    test('is empty while no member has ever loaded', () {
      // This is the state a collection is in when it gets favourited before
      // being opened; the tile warms it rather than showing a blank forever.
      final c = ComicCollection.fromJson({
        'id': 'x',
        'members': [
          {'sourceKey': 's', 'comicId': '1'},
        ],
      });
      expect(c.displayCover, '');
      expect(c.coverOwner, isNull);
      expect(c.members, isNotEmpty);
    });
  });

  group('collectionUpdateSortKey', () {
    test('orders single-digit months and days correctly', () {
      // The collection reports the latest member update time so follow-updates
      // reacts to a new chapter in any member. Raw string compare would put
      // "2026-9-1" after "2026-10-1" and freeze the collection's date.
      final sep = collectionUpdateSortKey('2026-9-1');
      final oct = collectionUpdateSortKey('2026-10-1');
      expect(sep.compareTo(oct), lessThan(0));
      expect(
        collectionUpdateSortKey('2026-3-9')
            .compareTo(collectionUpdateSortKey('2026-3-10')),
        lessThan(0),
      );
      expect(
        collectionUpdateSortKey('2025-12-31')
            .compareTo(collectionUpdateSortKey('2026-1-1')),
        lessThan(0),
      );
    });

    test('leaves an unexpected shape untouched rather than mangling it', () {
      expect(collectionUpdateSortKey('garbage'), 'garbage');
      expect(collectionUpdateSortKey('2026-01'), '2026-01');
    });
  });

  group('CollectionMember.label', () {
    test('prefers the user label, then the cached title, then the id', () {
      expect(
        CollectionMember(
          sourceKey: 's',
          comicId: 'the-id',
          displayName: ' Vol 1 ',
          cachedTitle: 'Title',
        ).label,
        'Vol 1',
      );
      expect(
        CollectionMember(
          sourceKey: 's',
          comicId: 'the-id',
          cachedTitle: 'Title',
        ).label,
        'Title',
      );
      expect(CollectionMember(sourceKey: 's', comicId: 'the-id').label,
          'the-id');
    });
  });
}

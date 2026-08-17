import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/webdav_library_store.dart';

void main() {
  group('stableWebdavLibraryId', () {
    test('is deterministic for the same address/account/folder', () {
      expect(
        stableWebdavLibraryId('https://nas.example.com/dav', 'me', '/comics'),
        stableWebdavLibraryId('https://nas.example.com/dav', 'me', '/comics'),
      );
    });

    test('normalizes case and trailing slashes so two devices converge', () {
      final canonical = stableWebdavLibraryId(
        'https://nas.example.com/dav',
        'me',
        '/comics',
      );
      expect(
        stableWebdavLibraryId('https://NAS.Example.com/dav/', 'me', '/comics/'),
        canonical,
      );
      expect(
        stableWebdavLibraryId(
          '  https://nas.example.com/dav  ',
          ' me ',
          ' comics ',
        ),
        canonical,
      );
    });

    test('differs per address, per account and per folder', () {
      final base = stableWebdavLibraryId('https://a.example/dav', 'me', '/c');
      expect(
        stableWebdavLibraryId('https://b.example/dav', 'me', '/c'),
        isNot(base),
      );
      // Same server, different account: separate libraries on purpose, since
      // the two accounts may see entirely different folders.
      expect(
        stableWebdavLibraryId('https://a.example/dav', 'you', '/c'),
        isNot(base),
      );
      expect(
        stableWebdavLibraryId('https://a.example/dav', 'me', '/other'),
        isNot(base),
      );
    });
  });

  group('defaultWebdavLibraryName', () {
    test('uses the host when no folder is set', () {
      expect(
        defaultWebdavLibraryName('https://nas.example.com/dav', ''),
        'nas.example.com',
      );
    });

    test('appends the folder so two collections on one server differ', () {
      expect(
        defaultWebdavLibraryName('https://nas.example.com/dav', '/manga'),
        'nas.example.com/manga',
      );
      expect(
        defaultWebdavLibraryName('https://nas.example.com/dav', 'comics/'),
        'nas.example.com/comics',
      );
    });

    test('falls back to the raw text and never returns empty', () {
      expect(defaultWebdavLibraryName('not a url', ''), 'not a url');
      expect(defaultWebdavLibraryName('', ''), 'WebDAV');
    });
  });

  group('allocateWebdavLibrarySourceKey', () {
    test('derives a fresh key from the id by default', () {
      final key = allocateWebdavLibrarySourceKey(const [], 'abc123');
      expect(key, '${WebdavLibraryStore.sourceKeyPrefix}abc123');
    });

    test('does not hand out the pre-upgrade key to an unrelated library', () {
      // That key carries the old library's reading history and favourites.
      // Giving it to the next library added after the original was deleted
      // would make the old server's entries resurface against the new one.
      expect(
        allocateWebdavLibrarySourceKey(const [], 'abc123'),
        isNot(WebdavLibraryStore.legacySourceKey),
      );
      expect(
        allocateWebdavLibrarySourceKey(const [
          '${WebdavLibraryStore.sourceKeyPrefix}other',
        ], 'abc123'),
        isNot(WebdavLibraryStore.legacySourceKey),
      );
    });

    test('adopts the pre-upgrade key only when asked and it is free', () {
      // Saving the implicit sync-derived library is the one case: it is the very
      // library those records describe, so it must keep their key.
      expect(
        allocateWebdavLibrarySourceKey(
          const [],
          'abc123',
          adoptLegacyKey: true,
        ),
        WebdavLibraryStore.legacySourceKey,
      );
      expect(
        allocateWebdavLibrarySourceKey(
          const [WebdavLibraryStore.legacySourceKey],
          'abc123',
          adoptLegacyKey: true,
        ),
        isNot(WebdavLibraryStore.legacySourceKey),
      );
    });

    test('never hands out a key that is already taken', () {
      final taken = [
        WebdavLibraryStore.legacySourceKey,
        '${WebdavLibraryStore.sourceKeyPrefix}abc123',
        '${WebdavLibraryStore.sourceKeyPrefix}abc1232',
      ];
      final key = allocateWebdavLibrarySourceKey(taken, 'abc123');
      expect(taken.contains(key), isFalse);
      final adopting = allocateWebdavLibrarySourceKey(
        taken,
        'abc123',
        adoptLegacyKey: true,
      );
      expect(taken.contains(adopting), isFalse);
    });
  });

  group('isLibrarySourceKey', () {
    test('matches both the pre-upgrade key and generated ones', () {
      expect(
        WebdavLibraryStore.isLibrarySourceKey(
          WebdavLibraryStore.legacySourceKey,
        ),
        isTrue,
      );
      expect(
        WebdavLibraryStore.isLibrarySourceKey(
          '${WebdavLibraryStore.sourceKeyPrefix}abc123',
        ),
        isTrue,
      );
    });

    test('does not match a script source', () {
      // These keys drive whether a source is hidden from source management, so
      // a false positive would make a user's own source disappear from it.
      expect(WebdavLibraryStore.isLibrarySourceKey('some_source'), isFalse);
      expect(WebdavLibraryStore.isLibrarySourceKey('webdav'), isFalse);
    });
  });

  group('webdavLibraryFromLegacySetting', () {
    test('carries the old single-library config over unchanged', () {
      final c = webdavLibraryFromLegacySetting([
        'https://nas.example.com/dav',
        'me',
        'secret',
        '/comics',
      ]);
      expect(c, isNotNull);
      expect(c!.url, 'https://nas.example.com/dav');
      expect(c.user, 'me');
      expect(c.pass, 'secret');
      expect(c.root, '/comics');
      // Must keep the old key, or everything recorded against it is stranded.
      expect(c.sourceKey, WebdavLibraryStore.legacySourceKey);
    });

    test('accepts a config that never had a folder', () {
      final c = webdavLibraryFromLegacySetting([
        'https://nas.example.com/dav',
        'me',
        'secret',
      ]);
      expect(c, isNotNull);
      expect(c!.root, '');
      expect(c.rootPath, '/');
    });

    test('yields nothing for an unset or malformed value', () {
      expect(webdavLibraryFromLegacySetting(null), isNull);
      expect(webdavLibraryFromLegacySetting(const []), isNull);
      expect(webdavLibraryFromLegacySetting(const ['', '', '']), isNull);
      expect(webdavLibraryFromLegacySetting('not a list'), isNull);
      expect(webdavLibraryFromLegacySetting(const [1, 2, 3]), isNull);
    });
  });

  group('WebdavLibraryConfig', () {
    test('round-trips through JSON', () {
      final c = WebdavLibraryConfig(
        id: 'abc123',
        sourceKey: 'webdav_library_abc123',
        name: 'Home NAS',
        url: 'https://nas.example.com/dav',
        user: 'me',
        pass: 'secret',
        root: '/comics',
        enabled: false,
        detectLinkedFolders: true,
      );
      final back = WebdavLibraryConfig.fromJson(c.toJson());
      expect(back.id, c.id);
      expect(back.sourceKey, c.sourceKey);
      expect(back.name, c.name);
      expect(back.url, c.url);
      expect(back.user, c.user);
      expect(back.pass, c.pass);
      expect(back.root, c.root);
      expect(back.enabled, isFalse);
      expect(back.detectLinkedFolders, isTrue);
    });

    test('a record without a stored source key falls back to the old one', () {
      final back = WebdavLibraryConfig.fromJson({
        'url': 'https://nas.example.com/dav',
        'user': 'me',
        'pass': 'secret',
        'root': '',
      });
      expect(back.sourceKey, WebdavLibraryStore.legacySourceKey);
      expect(back.enabled, isTrue);
      expect(back.detectLinkedFolders, isFalse);
    });

    test('rootPath always names a directory', () {
      WebdavLibraryConfig withRoot(String root) => WebdavLibraryConfig(
        id: 'i',
        sourceKey: 'k',
        name: '',
        url: 'https://x/dav',
        user: '',
        pass: '',
        root: root,
      );
      expect(withRoot('').rootPath, '/');
      expect(withRoot('   ').rootPath, '/');
      expect(withRoot('comics').rootPath, '/comics/');
      expect(withRoot('/comics').rootPath, '/comics/');
      expect(withRoot('/comics/').rootPath, '/comics/');
    });

    test('displayName falls back to a derived name when unnamed', () {
      final c = WebdavLibraryConfig(
        id: 'i',
        sourceKey: 'k',
        name: '   ',
        url: 'https://nas.example.com/dav',
        user: '',
        pass: '',
        root: '/manga',
      );
      expect(c.displayName, 'nas.example.com/manga');
    });

    test(
      'copyWith keeps the id and source key even when the address moves',
      () {
        // A server that changed hostname must stay the same library, or its
        // reading history would be stranded behind a key nothing resolves to.
        final c = WebdavLibraryConfig(
          id: 'abc123',
          sourceKey: 'webdav_library_abc123',
          name: 'Home',
          url: 'https://old.example/dav',
          user: 'me',
          pass: 'secret',
          root: '',
        );
        final moved = c.copyWith(url: 'https://new.example/dav');
        expect(moved.id, 'abc123');
        expect(moved.sourceKey, 'webdav_library_abc123');
        expect(moved.url, 'https://new.example/dav');
        expect(moved.detectLinkedFolders, isFalse);
      },
    );
  });
}

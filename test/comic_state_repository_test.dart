import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';

void main() {
  setUpAll(() {
    if (Platform.isWindows) {
      open.overrideFor(
        OperatingSystem.windows,
        () => DynamicLibrary.open('winsqlite3.dll'),
      );
    }
  });

  test('creates stable canonical identity for local and remote comics', () {
    final repository = ComicStateRepository();

    final local = repository.identityFor('local', 'abc');
    final remote = repository.identityFor('picacg', 'abc');
    final unknown = repository.identityFor('Unknown:999', 'abc');

    expect(local.comicId, 'local:abc');
    expect(local.isLocal, isTrue);
    expect(remote.comicId, 'remote:picacg:abc');
    expect(remote.isLocal, isFalse);
    expect(unknown.comicId, 'legacy:999:abc');
    expect(unknown.type.value, 999);
  });

  test(
    'mirrors remote comic metadata into canonical domain database',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'venera_domain_repo_',
      );
      final domain = DomainDatabase();

      try {
        await domain.init(tempDir.path);
        final repository = ComicStateRepository(domain: domain);
        final comic = Comic(
          'Title',
          'cover.jpg',
          'remote-id',
          'Sub',
          const ['genre:Action', 'status:连载中'],
          'Desc',
          'picacg',
          null,
          'zh',
        );

        final comicId = repository.mirrorComic(comic);
        final rows = domain.db.select(
          '''
        SELECT c.title, c.subtitle, c.description, c.status, s.platform_id
        FROM comics c
        JOIN comic_sources s ON s.comic_id = c.comic_id
        WHERE c.comic_id = ?;
        ''',
          [comicId],
        );

        expect(comicId, 'remote:picacg:remote-id');
        expect(rows.single['title'], 'Title');
        expect(rows.single['subtitle'], 'Sub');
        expect(rows.single['description'], 'Desc');
        expect(rows.single['status'], '连载中');
        expect(rows.single['platform_id'], 'remote:picacg');

        final display = repository.displayInfoFor(comic);
        expect(display.title, 'Title');
        expect(display.author, 'Sub');
        expect(display.status, '连载中');
        expect(display.tags, contains('genre:Action'));
        expect(display.tags, isNot(contains('status:连载中')));
      } finally {
        domain.close();
        tempDir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'comic display status is serialization status, not update read state',
    () {
      const repository = ComicStateRepository();
      final favorite = FavoriteItem(
        id: 'fav-id',
        name: 'Favorite',
        coverPath: 'cover.jpg',
        author: 'Author',
        type: ComicType.fromKey('picacg'),
        tags: const ['status:连载中', 'genre:Drama'],
      );
      final updateInfo = FavoriteItemWithUpdateInfo(
        favorite,
        '2026-05-11',
        true,
        null,
      );

      final display = repository.displayInfoFor(updateInfo);

      expect(display.status, '连载中');
      expect(display.updateTime, '2026-05-11');
      expect(display.hasNewUpdate, isTrue);
      expect(display.status, isNot('Unread'));
    },
  );
}

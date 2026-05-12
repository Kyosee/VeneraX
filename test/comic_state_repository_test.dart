import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/domain_database.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';

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

  test('related sources include the current comic source by default', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_related_self_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final comic = Comic(
        'Title',
        'cover.jpg',
        'self-id',
        'Author',
        const ['status:连载中'],
        'Desc',
        'picacg',
        null,
        'zh',
      );

      final links = repository.relatedSourcesFor(comic);

      expect(links, hasLength(1));
      expect(links.single.comicId, 'remote:picacg:self-id');
      expect(links.single.sourceComicId, 'self-id');
      expect(links.single.status, 'accepted');
      expect(links.single.sourceName, 'picacg');
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

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

  test('chapter progress uses mirrored chapter titles', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_chapters_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final staleComic = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'chapters': {for (var i = 1; i <= 8; i++) '$i': '第$i話'},
        'sourceKey': 'picacg',
        'comicId': 'comic-id',
      });
      final comic = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'chapters': {
          '1': '第1.1話',
          '2': '第1.2話',
          '3': '第2.1話',
          '4': '第2.2話',
          '5': '第2.3話',
          '6': '第11話',
        },
        'sourceKey': 'picacg',
        'comicId': 'comic-id',
      });
      repository.mirrorComicDetails(staleComic);
      repository.mirrorComicDetails(comic);

      final progress = repository.chapterProgressFor(
        Comic(
          'Title',
          'cover.jpg',
          'comic-id',
          'Author',
          const [],
          '第8話',
          'picacg',
          null,
          null,
        ),
        History.fromModel(model: comic, ep: 5, page: 11),
      );

      expect(progress.currentTitle, '第2.3話');
      expect(progress.latestTitle, '第11話');
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('chapter progress does not synthesize chapter numbers', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_no_chapters_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final details = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'sourceKey': 'picacg',
        'comicId': 'comic-id',
      });
      final comic = Comic(
        'Title',
        'cover.jpg',
        'comic-id',
        'Author',
        const [],
        '',
        'picacg',
        null,
        null,
      );
      repository.mirrorComic(comic);

      final progress = repository.chapterProgressFor(
        comic,
        History.fromModel(model: details, ep: 8, page: 1),
      );

      expect(progress.currentTitle, isNull);
      expect(progress.latestTitle, isNull);
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });

  test('chapter progress falls back to saved latest chapter title', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'venera_domain_latest_fallback_',
    );
    final domain = DomainDatabase();

    try {
      await domain.init(tempDir.path);
      final repository = ComicStateRepository(domain: domain);
      final details = ComicDetails.fromJson({
        'title': 'Title',
        'subtitle': 'Author',
        'cover': 'cover.jpg',
        'description': '',
        'tags': <String, List<String>>{},
        'sourceKey': 'picacg',
        'comicId': 'comic-id',
      });
      final favorite = FavoriteItem(
        id: 'comic-id',
        name: 'Title',
        coverPath: 'cover.jpg',
        author: 'Author',
        type: ComicType.fromKey('picacg'),
        tags: const [],
      );
      final updateInfo = FavoriteItemWithUpdateInfo(
        favorite,
        '第11話',
        true,
        null,
      );

      final progress = repository.chapterProgressFor(
        updateInfo,
        History.fromModel(model: details, ep: 8, page: 1),
      );

      expect(progress.currentTitle, isNull);
      expect(progress.latestTitle, '第11話');
    } finally {
      domain.close();
      tempDir.deleteSync(recursive: true);
    }
  });
}

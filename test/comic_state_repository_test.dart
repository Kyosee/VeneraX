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
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/source_platform.dart';
import 'package:venera/utils/translations.dart';

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
    final remote = repository.identityFor('source_a', 'abc');
    final unknown = repository.identityFor('Unknown:999', 'abc');

    expect(local.comicId, 'local:abc');
    expect(local.isLocal, isTrue);
    expect(remote.comicId, 'remote:source_a:abc');
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
          'source_a',
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

        expect(comicId, 'remote:source_a:remote-id');
        expect(rows.single['title'], 'Title');
        expect(rows.single['subtitle'], 'Sub');
        expect(rows.single['description'], 'Desc');
        expect(rows.single['status'], '连载中');
        expect(rows.single['platform_id'], 'remote:source_a');

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
    'local comic display tags use the current local comic after refresh',
    () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'venera_domain_local_tags_',
      );
      final domain = DomainDatabase();

      try {
        await domain.init(tempDir.path);
        domain.ensureComicSource(
          platform: SourcePlatformResolver.fromSourceKey('local'),
          sourceComicId: 'local-id',
          title: 'Title',
          tags: const ['genre:old', 'genre:Same'],
        );
        final repository = ComicStateRepository(domain: domain);
        final localComic = LocalComic(
          id: 'local-id',
          title: 'Title',
          subtitle: '',
          tags: const ['new', 'Same'],
          directory: tempDir.path,
          chapters: null,
          cover: 'cover.jpg',
          comicType: ComicType.local,
          downloadedChapters: const [],
          createdAt: DateTime(2026),
        );

        final display = repository.displayInfoFor(localComic);

        expect(display.tags, ['new', 'Same']);
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
        'source_a',
        null,
        'zh',
      );

      final links = repository.relatedSourcesFor(comic);

      expect(links, hasLength(1));
      expect(links.single.comicId, 'remote:source_a:self-id');
      expect(links.single.sourceComicId, 'self-id');
      expect(links.single.status, 'accepted');
      expect(links.single.sourceName, 'source_a');
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
        type: ComicType.fromKey('source_a'),
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
        'sourceKey': 'source_a',
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
        'sourceKey': 'source_a',
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
          'source_a',
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

  test(
    'chapter parser preserves grouped tabs when flat entries also exist',
    () {
      final chapters = ComicChapters.fromJson({
        '单行本': {'v1': '第一卷'},
        '连载版': {'c1': '第1话'},
        '2': '第2话',
      });

      expect(chapters.isGrouped, isTrue);
      expect(chapters.groups, containsAll(['单行本', '连载版', '默认']));
      expect(chapters.groupCount, 3);
      expect(chapters.titleAt(1, group: 1), '第一卷');
      expect(chapters.titleAt(1, group: 2), '第1话');
      expect(chapters.titleAt(1, group: 3), '第2话');
    },
  );

  test('chapter progress resolves grouped history chapter title', () {
    const repository = ComicStateRepository();
    final comic = ComicDetails.fromJson({
      'title': 'Title',
      'subtitle': 'Author',
      'cover': 'cover.jpg',
      'description': '',
      'tags': <String, List<String>>{},
      'chapters': {
        '单行本': {'v1': '第一卷'},
        '连载版': {'c1': '第1话', 'c2': '第2话'},
      },
      'sourceKey': 'source_a',
      'comicId': 'comic-id',
    });

    final progress = repository.chapterProgressFromDetails(
      comic,
      History.fromModel(model: comic, ep: 2, page: 7, group: 2),
    );

    expect(progress.currentTitle, '第2话');
    expect(progress.latestTitle, '第2话');
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
        'sourceKey': 'source_a',
        'comicId': 'comic-id',
      });
      final comic = Comic(
        'Title',
        'cover.jpg',
        'comic-id',
        'Author',
        const [],
        '',
        'source_a',
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
        'sourceKey': 'source_a',
        'comicId': 'comic-id',
      });
      final favorite = FavoriteItem(
        id: 'comic-id',
        name: 'Title',
        coverPath: 'cover.jpg',
        author: 'Author',
        type: ComicType.fromKey('source_a'),
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

  group('quick page count', () {
    Comic comicWith({int? maxPage, List<String>? tags}) => Comic(
      'Title',
      'cover.jpg',
      'id',
      'Author',
      tags,
      'Desc',
      'source_a',
      maxPage,
      'zh',
    );

    test('prefers maxPage over tags', () {
      const repository = ComicStateRepository();
      expect(
        repository.quickPageCountFor(
          comicWith(maxPage: 42, tags: const ['pages:99']),
        ),
        '42',
      );
    });

    test('falls back to a page count tag across namespaces', () {
      const repository = ComicStateRepository();
      expect(repository.quickPageCountFor(comicWith(tags: const ['pages:31'])), '31');
      expect(repository.quickPageCountFor(comicWith(tags: const ['Page: 7'])), '7');
      expect(repository.quickPageCountFor(comicWith(tags: const ['页数:18'])), '18');
      expect(repository.quickPageCountFor(comicWith(tags: const ['頁數:25'])), '25');
    });

    test('ignores a non-positive maxPage and unrelated tags', () {
      const repository = ComicStateRepository();
      expect(repository.quickPageCountFor(comicWith(maxPage: 0)), isNull);
      expect(
        repository.quickPageCountFor(comicWith(tags: const ['author:someone'])),
        isNull,
      );
      expect(repository.quickPageCountFor(comicWith(tags: const [])), isNull);
      expect(repository.quickPageCountFor(comicWith()), isNull);
    });

    test('a zero maxPage still falls back to a tag', () {
      const repository = ComicStateRepository();
      expect(
        repository.quickPageCountFor(
          comicWith(maxPage: 0, tags: const ['pages:12']),
        ),
        '12',
      );
    });
  });

  group('local comic mirror owns its metadata', () {
    // History.description goes through .tl.
    setUpAll(() => AppTranslation.translations = {});

    LocalComic localComic(
      String id,
      Directory dir, {
      required String title,
      String subtitle = '',
    }) {
      return LocalComic(
        id: id,
        title: title,
        subtitle: subtitle,
        tags: const [],
        // Absolute, so baseDir does not need LocalManager.path.
        directory: dir.path,
        chapters: null,
        cover: 'ch1/01.jpg',
        comicType: ComicType.local,
        downloadedChapters: const [],
        createdAt: DateTime(2026),
      );
    }

    // Issue #316: a comic without an author showed the author of the comic
    // that held its id before.
    test('re-mirroring replaces what an earlier comic with the id left', () async {
      final tempDir = Directory.systemTemp.createTempSync('venera_local_mirror_');
      final domain = DomainDatabase();

      try {
        await domain.init(tempDir.path);
        final repository = ComicStateRepository(domain: domain);
        final comicId = repository.mirrorLocalComic(
          localComic('1', tempDir, title: 'Old Title', subtitle: 'Old Author'),
        );
        // Opening the details page snapshots the comic into its own work.
        domain.ensureWorkForComic(comicId: comicId);

        final current = localComic('1', tempDir, title: 'New Title');
        repository.mirrorLocalComic(current);

        final base = domain.getComicBaseInfo(comicId)!;
        expect(base.title, 'New Title');
        expect(base.author, isNull);
        final link = domain.getRelatedSources(comicId).single;
        expect(link.comicTitle, 'New Title');
        expect(link.comicAuthor, isNull);
        expect(repository.displayInfoFor(current).author, isNull);
        final history = History.fromModel(model: current, ep: 1, page: 1);
        expect(repository.displayInfoFor(history).author, isNull);
      } finally {
        domain.close();
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a downloaded comic keeps metadata from its source page', () async {
      final tempDir = Directory.systemTemp.createTempSync('venera_download_mirror_');
      final domain = DomainDatabase();

      try {
        await domain.init(tempDir.path);
        final repository = ComicStateRepository(domain: domain);
        final comicId = repository.mirrorComic(
          Comic(
            'Title',
            'https://example.com/cover.jpg',
            'remote-id',
            'Source Author',
            const ['status:连载中'],
            '',
            'Unknown:123',
            null,
            null,
          ),
        );

        repository.mirrorLocalComic(
          LocalComic(
            id: 'remote-id',
            title: 'Title',
            subtitle: '',
            tags: const [],
            directory: tempDir.path,
            chapters: null,
            cover: 'cover.jpg',
            comicType: const ComicType(123),
            downloadedChapters: const [],
            createdAt: DateTime(2026),
          ),
        );

        final base = domain.getComicBaseInfo(comicId)!;
        expect(base.author, 'Source Author');
        expect(base.status, '连载中');
      } finally {
        domain.close();
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}

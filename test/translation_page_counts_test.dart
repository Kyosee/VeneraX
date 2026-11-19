import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/translations.dart';

const _chapter = TranslationChapterIdentity(
  scopePrefix: 'pageTranslation@2@ja>zh@src@comic@ch1@',
  sourceKey: 'src',
  comicId: 'comic',
  chapterId: 'ch1',
  sourceLang: 'ja',
  targetLang: 'zh',
  comicTitle: 'Comic',
  chapterTitle: 'Chapter 1',
);
const _page = 'pageTranslation@2@ja>zh@src@comic@ch1@p1@';
const _localPage = 'pageTranslation@2@auto>zh@src@comic@ch1@p1@';

List<TranslatedRegion> _regions(String text) => [
  TranslatedRegion(
    rect: IntRect(1, 2, 30, 40),
    text: text,
    backgroundColor: 0xFFFFFFFF,
    textColor: 0xFF000000,
    lineHeight: 12,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String oldDataPath;
  late String oldCachePath;
  late bool oldBackground;
  late TranslationStore store;

  setUp(() async {
    oldDataPath = App.dataPath;
    oldCachePath = App.cachePath;
    oldBackground = App.isBackgroundTask;
    root = await Directory.systemTemp.createTemp('venerax-page-counts-');
    App.dataPath = (await Directory('${root.path}/local').create()).path;
    App.cachePath = (await Directory('${root.path}/cache').create()).path;
    App.isBackgroundTask = true;
    store = TranslationStore();
    await store.init();
  });

  tearDown(() async {
    store.close();
    App.dataPath = oldDataPath;
    App.cachePath = oldCachePath;
    App.isBackgroundTask = oldBackground;
    await root.delete(recursive: true);
  });

  // A foreign database can contain invalid totals or predate their table.
  String source(
    String name, {
    List<(String, String, String, int, int)>? totals = const [],
    Map<String, String> pages = const {},
  }) {
    final path = '${root.path}/$name.db';
    final db = sqlite3.open(path);
    try {
      db.execute('''
        create table translated_page (
          cache_key text primary key, regions text, time int);
      ''');
      for (final page in pages.entries) {
        db.execute('insert into translated_page values (?, ?, ?);', [
          page.key,
          jsonEncode(
            _regions(page.value).map((region) => region.toJson()).toList(),
          ),
          100,
        ]);
      }
      if (totals != null) {
        db.execute('''
          create table chapter_page_count (
            source_key text not null, comic_id text not null,
            chapter_id text not null, total_pages int not null,
            updated_at int not null,
            primary key (source_key, comic_id, chapter_id));
        ''');
        for (final (key, comic, chapter, count, time) in totals) {
          db.execute('insert into chapter_page_count values (?, ?, ?, ?, ?);', [
            key,
            comic,
            chapter,
            count,
            time,
          ]);
        }
      }
    } finally {
      db.dispose();
    }
    return path;
  }

  test(
    'totals persist by source, comic and chapter without inflating saved pages',
    () async {
      store.recordChapterPageCount('src', 'comic', 'ch1', 20, updatedAt: 100);
      store.recordChapterPageCount('src', 'comic', 'ch2', 30, updatedAt: 100);
      store.recordChapterPageCount('other', 'comic', 'ch1', 40, updatedAt: 100);
      store.recordChapterPageCount('src', 'other', 'ch1', 50);
      expect(store.count, 0);
      expect(store.chapters, isEmpty);

      store.put(_page, _regions('Saved text'), chapter: _chapter);
      expect(store.hasTranslationsForComic('src', 'comic'), isTrue);
      expect(store.hasTranslationsForComic('other', 'comic'), isFalse);
      store.close();
      await store.init();

      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 20, 'ch2': 30});
      expect(store.chapterPageCounts('other', 'comic'), {'ch1': 40});
      expect(store.chapterPageCounts('src', 'other'), {'ch1': 50});
      expect(store.chapterPageCounts('missing', 'comic'), isEmpty);
      expect(store.count, 1);
      expect(store.countByPrefix(_chapter.scopePrefix), 1);
      expect(store.chapters.single.pageCount, 1);
      expect(store.comics.single.pageCount, 1);
      expect(store.get(_page)!.single.text, 'Saved text');
    },
  );

  test(
    'only positive totals are recorded and newer counts may grow or shrink',
    () {
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 20, updatedAt: 200),
        isTrue,
      );
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 99, updatedAt: 100),
        isFalse,
      );
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 20});
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 30, updatedAt: 300),
        isTrue,
      );
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 30});
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 12, updatedAt: 400),
        isTrue,
      );
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 0, updatedAt: 600),
        isFalse,
      );
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', -1, updatedAt: 700),
        isFalse,
      );
      expect(store.recordChapterPageCount('src', 'comic', 'zero', 0), isFalse);
      expect(
        store.recordChapterPageCount('src', 'comic', 'negative', -1),
        isFalse,
      );
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 12});
      // Ignoring an invalid total must not advance the stored timestamp.
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 10, updatedAt: 500),
        isTrue,
      );
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 10});
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 10, updatedAt: 800),
        isFalse,
      );
      // An unchanged fresh listing still outranks an older different count.
      expect(
        store.recordChapterPageCount('src', 'comic', 'ch1', 99, updatedAt: 750),
        isFalse,
      );
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 10});
      expect(store.count, 0);
    },
  );

  test('merge uses timestamps for both larger and smaller totals', () async {
    for (final chapter in ['grows', 'shrinks', 'kept']) {
      store.recordChapterPageCount('src', 'comic', chapter, 20, updatedAt: 200);
    }
    final incoming = source(
      'incoming',
      totals: [
        ('src', 'comic', 'grows', 30, 300),
        ('src', 'comic', 'shrinks', 12, 300),
        ('src', 'comic', 'kept', 99, 100),
        ('src', 'comic', 'new', 50, 300),
      ],
    );

    expect((await store.mergeFrom(incoming)).applied, 0);
    expect(store.chapterPageCounts('src', 'comic'), {
      'grows': 30,
      'shrinks': 12,
      'kept': 20,
      'new': 50,
    });
    await store.mergeFrom(
      source(
        'stale',
        totals: [
          ('src', 'comic', 'grows', 5, 250),
          ('src', 'comic', 'shrinks', 80, 250),
        ],
      ),
    );
    expect(store.chapterPageCounts('src', 'comic'), {
      'grows': 30,
      'shrinks': 12,
      'kept': 20,
      'new': 50,
    });
    expect(store.count, 0);
    expect(store.chapters, isEmpty);
  });

  test(
    'merge ignores zero and negative totals without dropping translations',
    () async {
      store.recordChapterPageCount('src', 'comic', 'ch1', 20, updatedAt: 200);
      store.recordChapterPageCount('src', 'comic', 'ch2', 30, updatedAt: 200);
      final result = await store.mergeFrom(
        source(
          'invalid',
          totals: [
            ('src', 'comic', 'ch1', 0, 400),
            ('src', 'comic', 'ch2', -1, 400),
            ('src', 'comic', 'zero', 0, 400),
          ],
          pages: {_page: 'Imported text'},
        ),
      );

      expect(result.applied, 1);
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 20, 'ch2': 30});
      expect(store.get(_page)!.single.text, 'Imported text');
      expect(store.count, 1);
      expect(store.chapters.single.pageCount, 1);
      await store.mergeFrom(
        source(
          'valid',
          totals: [
            ('src', 'comic', 'ch1', 15, 300),
            ('src', 'comic', 'ch2', 25, 300),
          ],
        ),
      );
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 15, 'ch2': 25});
    },
  );

  test(
    'merging an old database without totals preserves known counts',
    () async {
      store.recordChapterPageCount('src', 'comic', 'ch1', 20, updatedAt: 200);
      const otherPage = 'pageTranslation@2@ja>zh@src@comic@ch2@p1@';
      final legacy = source(
        'legacy',
        totals: null,
        pages: {_page: 'Legacy chapter 1', otherPage: 'Legacy chapter 2'},
      );

      expect((await store.mergeFrom(legacy)).applied, 2);
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 20});
      expect(store.get(_page)!.single.text, 'Legacy chapter 1');
      expect(store.get(otherPage)!.single.text, 'Legacy chapter 2');
      expect(store.count, 2);
      expect(
        store.chapters.map((chapter) => chapter.pageCount),
        everyElement(1),
      );
    },
  );

  test(
    'language mapping moves translations but keeps page-count identities',
    () async {
      final incoming = source(
        'language',
        totals: [
          ('src', 'comic', 'ch1', 20, 100),
          ('other', 'comic', 'ch1', 30, 100),
        ],
        pages: {_page: 'Mapped text'},
      );

      await store.mergeFrom(incoming, languageFor: (_, _) => 'auto');

      expect(store.get(_page), isNull);
      expect(store.get(_localPage)!.single.text, 'Mapped text');
      expect(store.chapters.single.identity.sourceLang, 'auto');
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 20});
      expect(store.chapterPageCounts('other', 'comic'), {'ch1': 30});
      expect(store.count, 1);
      expect(store.chapters.single.pageCount, 1);
    },
  );

  test(
    'translation-only export and import carry totals and saved text',
    () async {
      await AppTranslation.init();
      await appdata.init();
      final settings = {
        for (final key in [
          'comicSpecificSettings',
          'deviceSpecificSettings',
          'imageTranslationSource',
          'imageTranslationTarget',
        ])
          key: appdata.settings[key],
      };
      final implicitData = Map<String, dynamic>.from(appdata.implicitData);
      addTearDown(() {
        for (final entry in settings.entries) {
          appdata.settings[entry.key] = entry.value;
        }
        appdata.implicitData
          ..clear()
          ..addAll(implicitData);
      });
      appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
      appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
      appdata.settings['imageTranslationSource'] = 'auto';
      appdata.settings['imageTranslationTarget'] = 'zh';
      appdata.implicitData.clear();
      store.recordChapterPageCount('src', 'comic', 'ch1', 20, updatedAt: 200);
      store.recordChapterPageCount('src', 'comic', 'ch2', 30, updatedAt: 200);
      final regions = _regions('Preserved translation');
      store.put(_page, regions, chapter: _chapter);

      final exported = await exportTranslations();
      expect(exported, isNotNull);
      final archive = ZipDecoder().decodeBytes(exported!.readAsBytesSync());
      expect(archive.findFile('image_translation.db'), isNotNull);
      final manifest = jsonDecode(
        utf8.decode(archive.findFile(translationExportMarker)!.content),
      );
      expect(manifest['type'], 'translations');
      expect(manifest['pages'], 1);

      store.close();
      App.dataPath = (await Directory('${root.path}/recipient').create()).path;
      await store.init();
      expect(store.count, 0);
      expect(store.chapterPageCounts('src', 'comic'), isEmpty);
      store.recordChapterPageCount(
        'local-source',
        'kept',
        'ch1',
        17,
        updatedAt: 300,
      );
      final outcome = await importAppData(exported);

      expect(outcome.translationsOnly, isTrue);
      expect(outcome.translatedPages, 1);
      expect(store.chapterPageCounts('src', 'comic'), {'ch1': 20, 'ch2': 30});
      expect(store.chapterPageCounts('local-source', 'kept'), {'ch1': 17});
      expect(store.get(_page), isNull);
      expect(
        store.get(_localPage)!.map((region) => region.toJson()),
        regions.map((region) => region.toJson()),
      );
      expect(store.count, 1);
      expect(store.chapters.single.pageCount, 1);
      expect(store.chapters.single.identity.comicTitle, 'Comic');
    },
  );
}

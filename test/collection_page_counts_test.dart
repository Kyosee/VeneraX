import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_chapter_id.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_source/collection_source.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sourceKey = 'collection_page_counts_fixture';
  const remoteId = 'remote-member';
  const localId = 'native-member';
  const collectionId = 'page-counts';
  const collectionKey = 'comic_collection_$collectionId';
  final requests = <(String, String?)>[];
  final remoteChapter = encodeCollectionChapterId(
    sourceKey: sourceKey,
    comicId: remoteId,
    chapterId: '',
  );
  final localChapter = encodeCollectionChapterId(
    sourceKey: 'local',
    comicId: localId,
    chapterId: '',
  );
  late Directory root;
  late String originalDataPath;
  late String originalCachePath;
  late TargetPlatform? originalPlatform;

  Future<void> addLocalPages(String id, ComicType type, int count) async {
    final directory = await Directory('${root.path}/$id').create();
    for (var i = 1; i <= count; i++) {
      await File('${directory.path}/$i.png').writeAsBytes([i]);
    }
    await LocalManager().add(
      LocalComic(
        id: id,
        title: id,
        subtitle: '',
        tags: const [],
        directory: directory.path,
        chapters: null,
        cover: '',
        comicType: type,
        downloadedChapters: const [],
        createdAt: DateTime.utc(2026),
      ),
    );
  }

  setUpAll(() async {
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    originalPlatform = debugDefaultTargetPlatformOverride;
    root = await Directory.systemTemp.createTemp('collection-page-counts-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    await TranslationStore().init();

    ComicSourceManager().add(
      ComicSource(
        'Page count fixture',
        sourceKey,
        null, // account
        null, // categoryData
        null, // categoryComicsData
        null, // favoriteData
        const [], // explorePages
        null, // searchPageData
        null, // settings
        (id) async => Res(
          ComicDetails.fromJson({
            'title': id,
            'cover': '',
            'comicId': id,
            'sourceKey': sourceKey,
            'tags': <String, List<String>>{},
          }),
        ),
        null, // loadComicThumbnail
        (id, ep) async {
          requests.add((id, ep));
          return const Res(['source-page-1', 'source-page-2', 'source-page-3']);
        },
        null, // getImageLoadingConfig
        null, // getThumbnailLoadingConfig
        '', // filePath
        '', // url
        '1', // version
        null, // commentsLoader
        null, // sendCommentFunc
        null, // chapterCommentsLoader
        null, // sendChapterCommentFunc
        null, // likeOrUnlikeComic
        null, // voteCommentFunc
        null, // likeCommentFunc
        null, // idMatcher
        null, // translations
        null, // handleClickTagEvent
        null, // onTagSuggestionSelected
        null, // linkHandler
        false, // enableTagsSuggestions
        false, // enableTagsTranslate
        null, // starRatingFunc
        null, // archiveDownloader
      ),
    );
    await addLocalPages(remoteId, ComicType.fromKey(sourceKey), 1);
    await addLocalPages(localId, ComicType.local, 2);
    final collection = ComicCollection(
      id: collectionId,
      sourceKey: collectionKey,
      name: 'Page count collection',
      members: [
        CollectionMember(
          sourceKey: sourceKey,
          comicId: remoteId,
          cachedTitle: remoteId,
        ),
      ],
      createdAt: DateTime.utc(2026),
    );
    appdata.settings[ComicCollectionStore.settingsKey] = [collection.toJson()];
    ComicSourceManager().add(buildComicCollectionSource(collection));
    // Exercise the mobile chapter menu after desktop-only local path setup.
    debugDefaultTargetPlatformOverride = originalPlatform;
  });

  tearDownAll(() async {
    ComicSourceManager().remove(collectionKey);
    ComicSourceManager().remove(sourceKey);
    await appdata.saveData(false);
    TranslationStore().close();
    ComicDetailsCache().close();
    LocalManager().close();
    JsEngine().dispose();
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    debugDefaultTargetPlatformOverride = originalPlatform;
    await root.delete(recursive: true);
  });

  testWidgets('workspace fetches the full member list under collection identity', (
    tester,
  ) async {
    final store = TranslationStore();
    final chapter = TranslationChapterIdentity(
      scopePrefix:
          'pageTranslation@2@auto>zh@$collectionKey@$collectionId@$remoteChapter@',
      sourceKey: collectionKey,
      comicId: collectionId,
      chapterId: remoteChapter,
      sourceLang: 'auto',
      targetLang: 'zh',
      comicTitle: 'Page count collection',
      chapterTitle: 'Remote chapter',
    );
    store.put('${chapter.scopePrefix}p1@', const [], chapter: chapter);
    final cached = await tester.runAsync(
      () => loadCollectionPages(collectionId, remoteChapter),
    );
    expect(cached!.error, isFalse);
    expect(cached.data, hasLength(1));
    expect(cached.data.single, startsWith('file://'));
    expect(requests, isEmpty);
    expect(store.chapterPageCounts(collectionKey, collectionId), isEmpty);
    expect(store.chapterPageCounts(sourceKey, remoteId), isEmpty);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => openTranslatedChaptersPage(
                context,
                store.comics.single,
              ),
              child: const Text('Open chapters'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open chapters'));
    await tester.pumpAndSettle();
    expect(find.text('1 pages saved · Total unknown'), findsOneWidget);
    expect(requests, isEmpty);
    await tester.tap(find.byKey(ValueKey('translation-menu-$remoteChapter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fetch page count'));
    await tester.pumpAndSettle();

    expect(requests, [(remoteId, null)]);
    expect(store.chapterPageCounts(collectionKey, collectionId), {
      remoteChapter: 3,
    });
    expect(store.chaptersFor(collectionKey, collectionId).single.pageCount, 1);
    expect(store.count, 1);
    expect(find.text('1/3 pages saved'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('preferNetwork keeps native local members readable', () async {
    requests.clear();
    final collection = ComicCollectionStore.find(collectionId)!;
    collection.members.add(
      CollectionMember(sourceKey: 'local', comicId: localId),
    );
    appdata.settings[ComicCollectionStore.settingsKey] = [collection.toJson()];
    final result = await loadCollectionPages(
      collectionId,
      localChapter,
      preferNetwork: true,
    );
    expect(result.error, isFalse);
    expect(result.data, hasLength(2));
    expect(result.data, everyElement(startsWith('file://')));
    expect(requests, isEmpty);
    expect(TranslationStore().chapterPageCounts('local', localId), {'0': 2});
    final download = await loadCollectionPages(
      collectionId,
      localChapter,
      forDownload: true,
      preferNetwork: true,
    );
    expect(download.error, isTrue);
  });
}

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_chapter_id.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/collection_source.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sourceKey = 'collection_download_test';
  const collectionId = 'download_test';
  late Directory directory;
  late String originalDataPath;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp(
      'venera-collection-test-',
    );
    originalDataPath = App.dataPath;
    App.dataPath = directory.path;
    await appdata.init();
    await AppTranslation.init();
  });

  tearDownAll(() async {
    await LocalManager().saveCurrentDownloadingTasks();
    await appdata.saveData(false);
    App.dataPath = originalDataPath;
    await directory.delete(recursive: true);
  });

  tearDown(() {
    ComicSourceManager().remove(sourceKey);
    ComicSourceManager().remove('comic_collection_$collectionId');
  });

  Future<void> expectRecoveredMember({
    Map<String, String>? memberChapters = const {'missing-chapter': 'Chapter'},
    bool grouped = false,
    bool selected = false,
    bool retry = false,
  }) async {
    var memberAvailable = false;
    final infoRequests = <String>[];
    final pageRequests = <(String, String?)>[];
    final requested = Completer<void>();
    late ImagesDownloadTask task;
    final source = ComicSource(
      'Collection download test',
      sourceKey,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      (id) async {
        infoRequests.add(id);
        if (id == 'unselected' || (id == 'missing' && !memberAvailable)) {
          return const Res.error('Member details unavailable');
        }
        return Res(
          ComicDetails.fromJson({
            'title': id,
            'cover': 'https://example.com/cover.png',
            'comicId': id,
            'sourceKey': sourceKey,
            'tags': <String, List<String>>{},
            'chapters': id == 'missing'
                ? memberChapters
                : <String, String>{'$id-chapter': 'Chapter'},
          }),
        );
      },
      null,
      (id, ep) async {
        pageRequests.add((id, ep));
        task.pause();
        if (!requested.isCompleted) requested.complete();
        return const Res(<String>[]);
      },
      null,
      null,
      '',
      '',
      '1.0.0',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
    ComicSourceManager().add(source);
    appdata.settings[ComicCollectionStore.settingsKey] = [
      {
        'id': collectionId,
        'displayMode': grouped ? 'tabs' : 'flat',
        'members': [
          for (final id in ['ready', 'missing', if (selected) 'unselected'])
            {'sourceKey': sourceKey, 'comicId': id},
        ],
      },
    ];
    final collection = ComicCollectionStore.find(collectionId)!;
    final collectionSource = buildComicCollectionSource(collection);
    ComicSourceManager().add(collectionSource);
    final partial = (await loadCollectionInfo(collectionId)).data;
    final readyChapter = partial.chapters!.ids.first;
    final missingChapter = partial.chapters!.ids.firstWhere(
      (key) => decodeCollectionChapterId(key)!.comicId == 'missing',
    );
    expect(decodeCollectionChapterId(missingChapter)!.chapterId, isEmpty);
    infoRequests.clear();

    // Restore a task that already finished the first member before failing.
    final saved =
        ImagesDownloadTask(
          source: collectionSource,
          comicId: collectionId,
          comic: partial,
          chapters: selected ? [readyChapter, missingChapter] : null,
        ).toJson()..addAll({
          'path': directory.path,
          'cover': 'file://${directory.path}/cover.png',
          'images': {
            readyChapter: ['downloaded-image'],
          },
          'chapter': 1,
          'downloadedCount': 1,
          'totalCount': 1,
          'totalChapters': 2,
        });
    task = ImagesDownloadTask.fromJson(saved)!;
    addTearDown(task.pause);
    final failed = Completer<void>();
    task.addListener(() {
      if (task.isError && !failed.isCompleted) failed.complete();
    });
    memberAvailable = !retry;
    task.resume();
    if (retry) {
      await failed.future.timeout(const Duration(seconds: 6));
      expect(pageRequests, isEmpty);
      expect(task.message, contains('Member details unavailable'));
      expect(task.toJson()['chapter'], 1);
      expect(task.comic!.chapters!.ids, partial.chapters!.ids);
      memberAvailable = true;
      task.resume();
    }
    await requested.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);

    expect(pageRequests, [
      for (final chapter in memberChapters?.keys ?? <String?>[null])
        ('missing', chapter),
    ]);
    expect(infoRequests, everyElement('missing'));
    expect(task.toJson()['chapter'], 1);
    expect(task.toJson()['downloadedCount'], 1);
    expect(task.toJson()['images'], {
      readyChapter: ['downloaded-image'],
    });
    final resolvedKeys = [
      for (final chapter in memberChapters?.keys ?? [''])
        encodeCollectionChapterId(
          sourceKey: sourceKey,
          comicId: 'missing',
          chapterId: chapter,
        ),
    ];
    expect(task.toJson()['totalChapters'], 1 + resolvedKeys.length);
    expect(task.chapters, selected ? [readyChapter, ...resolvedKeys] : null);
    if (grouped) {
      expect(task.comic!.chapters!.groups, [
        'ready',
        'missing',
        if (selected) 'unselected',
      ]);
      expect(task.comic!.chapters!.getGroup('missing').keys, resolvedKeys);
    }
    final restored = ImagesDownloadTask.fromJson(task.toJson())!;
    expect(restored.chapters, task.chapters);
    expect(restored.comic!.chapters!.toJson(), task.comic!.chapters!.toJson());
  }

  test('resumed collection resolves a failed member before loading pages', () {
    return expectRecoveredMember();
  });

  test('recovered member expands into every original chapter', () {
    return expectRecoveredMember(
      memberChapters: {'part/1': 'First', 'part:2': 'Second'},
    );
  });

  test(
    'selected grouped chapters expand without loading unselected members',
    () {
      return expectRecoveredMember(
        memberChapters: {'part/1': 'First', 'part:2': 'Second'},
        grouped: true,
        selected: true,
      );
    },
  );

  test('genuine single-chapter members retain a null chapter argument', () {
    return expectRecoveredMember(memberChapters: null);
  });

  test('unavailable metadata preserves progress and can recover on retry', () {
    return expectRecoveredMember(retry: true);
  });
}

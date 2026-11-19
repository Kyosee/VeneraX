import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/reading_widget.dart';
import 'package:venera/utils/translations.dart';

LocalComic _comic(String id, String title, Directory root) => LocalComic(
  id: id,
  title: title,
  subtitle: '',
  tags: const [],
  directory: '${root.path}/$id',
  chapters: null,
  cover: 'cover.jpg',
  comicType: ComicType.local,
  downloadedChapters: const [],
  createdAt: DateTime(2026, 11, 1),
);

History _record(String id, String title, DateTime time, {int page = 1}) =>
    History.fromMap({
      'type': ComicType.local.value,
      'time': time.millisecondsSinceEpoch,
      'title': title,
      'subtitle': '',
      'cover': 'cover.jpg',
      'ep': 1,
      'page': page,
      'id': id,
      'readEpisode': const <String>[],
      'max_page': null,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    root = Directory.systemTemp.createTempSync('local-history-synced-copy-');
    App.dataPath = root.path;
    App.cachePath = '${root.path}/cache';
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    debugDefaultTargetPlatformOverride = null;
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    HistoryManager().close();
    LocalManager().close();
    JsEngine().dispose();
    debugDefaultTargetPlatformOverride = null;
    root.deleteSync(recursive: true);
  });

  test('a record from another device opens and resumes this copy', () async {
    await LocalManager().add(_comic('200', 'Synced title', root), '200');
    HistoryManager().addHistory(
      _record('100', 'Synced title', DateTime(2026, 11, 10), page: 82),
    );

    expect(LocalManager().findSyncedCopy('100', 'Synced title')?.id, '200');
    final resumed = HistoryManager().find('200', ComicType.local);
    expect(resumed?.id, '100');
    expect(resumed?.page, 82);

    final state = ComicStateRepository(
      localManager: LocalManager(),
      historyManager: HistoryManager(),
      favoritesManager: LocalFavoritesManager(),
    ).load('local', '100');
    expect(state.localComic?.id, '200');
    expect(state.history?.id, '100');
  });

  test('the newer of the two records carries the reading state', () async {
    await LocalManager().add(_comic('201', 'Both read', root), '201');
    HistoryManager().addHistory(
      _record('101', 'Both read', DateTime(2026, 11, 10), page: 5),
    );
    HistoryManager().addHistory(
      _record('201', 'Both read', DateTime(2026, 11, 12), page: 9),
    );
    expect(HistoryManager().find('201', ComicType.local)?.page, 9);

    HistoryManager().addHistory(
      _record('101', 'Both read', DateTime(2026, 11, 14), page: 30),
    );
    expect(HistoryManager().find('201', ComicType.local)?.page, 30);
    expect(LocalManager().getComics(LocalSortType.lastRead).first.id, '201');
  });

  test('local widgets rank reading before the full library order', () async {
    final manager = LocalManager();
    final originalSort = manager.sortType;
    try {
      for (var i = 0; i < 24; i++) {
        await manager.add(
          _comic('widget-$i', 'Widget ${i.toString().padLeft(2, '0')}', root),
          'widget-$i',
        );
      }
      manager.sortType = LocalSortType.nameDesc;
      HistoryManager().addHistory(
        _record('widget-0', 'Widget 00', DateTime(2026, 11, 20)),
      );
      HistoryManager().addHistory(
        _record('widget-1', 'Widget 01', DateTime(2026, 11, 19)),
      );
      final comics = await readingWidgetLocalComics();
      expect(comics.take(2).map((c) => c.id), ['widget-0', 'widget-1']);
      expect(
        comics
            .where((c) => c.id.startsWith('widget-'))
            .skip(2)
            .map((c) => c.id),
        [for (var i = 23; i >= 2; i--) 'widget-$i'],
      );
    } finally {
      manager.sortType = originalSort;
    }
  });

  test('comic settings made on another device apply to this copy', () async {
    const key = 'readerScreenPicNumberForLandscape';
    final settings = appdata.settings;
    final entries = settings['comicSpecificSettings'] as Map;
    await LocalManager().add(_comic('206', 'Set elsewhere', root), '206');
    HistoryManager().addHistory(
      _record('106', 'Set elsewhere', DateTime(2026, 11, 10)),
    );
    settings.setEnabledComicSpecificSettings('106', 'local', true);
    settings.setReaderSetting('106', 'local', key, 2);
    expect(settings.isComicSpecificSettingsEnabled('206', 'local'), isFalse);

    expect(HistoryManager().syncedLocalIds('206'), ['106']);
    settings.shareSyncedComicSettings('206', 'local', ['106']);
    expect(settings.isComicSpecificSettingsEnabled('206', 'local'), isTrue);
    expect(settings.getReaderSetting('206', 'local', key), 2);
    // Edits go to the entry the other device reads.
    settings.setReaderSetting('206', 'local', key, 1);
    expect(entries['106@local'][key], 1);
    expect(entries.containsKey('206@local'), isFalse);
    settings.resetComicReaderSettings('206@local');
    expect(entries.containsKey('106@local'), isFalse);

    // Settings this copy enabled itself stay its own.
    settings.setEnabledComicSpecificSettings('107', 'local', true);
    settings.setReaderSetting('107', 'local', key, 2);
    settings.setEnabledComicSpecificSettings('207', 'local', true);
    settings.shareSyncedComicSettings('207', 'local', ['107']);
    expect(settings.getReaderSetting('207', 'local', key), isNot(2));
    entries
      ..remove('107@local')
      ..remove('207@local');
  });

  test('ambiguous titles and ids in use here are never paired', () async {
    await LocalManager().add(_comic('202', 'Same title', root), '202');
    await LocalManager().add(_comic('203', 'Same title', root), '203');
    HistoryManager().addHistory(
      _record('102', 'Same title', DateTime(2026, 11, 10)),
    );
    expect(LocalManager().findSyncedCopy('102', 'Same title'), isNull);
    expect(HistoryManager().find('202', ComicType.local), isNull);

    await LocalManager().add(_comic('204', 'Mine', root), '204');
    await LocalManager().add(_comic('205', 'Other', root), '205');
    HistoryManager().addHistory(_record('205', 'Mine', DateTime(2026, 11, 10)));
    expect(LocalManager().findSyncedCopy('205', 'Mine'), isNull);
    expect(HistoryManager().find('204', ComicType.local), isNull);
  });
}

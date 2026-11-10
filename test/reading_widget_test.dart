import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/reading_widget.dart';
import 'package:venera/utils/reading_widget_route.dart';
import 'package:venera/utils/translations.dart';

History history(String id, {int type = 0}) => History.fromMap({
  'id': id,
  'type': type,
  'title': 'Title $id',
  'subtitle': '',
  'cover': 'https://example.invalid/cover?token=private',
  'time': 1,
  'ep': 2,
  'page': 7,
  'readEpisode': <String>[],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final snapshots = <Map<String, dynamic>>[];
  var active = true;
  var reads = 0;
  Map<String, dynamic> latest([
    ReadingWidgetKind kind = ReadingWidgetKind.history,
  ]) => snapshots.lastWhere((snapshot) => snapshot['kind'] == kind.name);

  setUpAll(AppTranslation.init);
  setUp(() {
    directory = Directory.systemTemp.createTempSync('venera_widget_');
    App.dataPath = directory.path;
    appdata.settings['language'] = 'en-US';
    appdata.settings['authorizationRequired'] = false;
    snapshots.clear();
    active = true;
    reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(readingWidgetChannel, (call) async {
          if (call.method == 'hasWidgets') return active;
          expect(call.method, 'update');
          snapshots.add(
            jsonDecode(call.arguments as String) as Map<String, dynamic>,
          );
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(readingWidgetChannel, null);
    appdata.settings['authorizationRequired'] = false;
    directory.deleteSync(recursive: true);
  });

  ReadingWidgetService service(
    List<History> records, {
    bool Function(Comic)? visible,
    Future<Uint8List> Function(Comic)? load,
  }) => ReadingWidgetService(
    recent: () => records,
    visible: visible ?? (_) => true,
    coverBytes:
        load ??
        (_) async {
          reads++;
          return Uint8List(0);
        },
  );

  test(
    'native snapshot excludes filtered records and private remote metadata',
    () async {
      final records = List.generate(10, (index) => history('$index'));
      await service(records, visible: (h) => h.id != '0').refresh();
      final items = latest()['items'] as List;
      expect(items.map((item) => item['id']), ['1', '2', '3', '4', '5', '6']);
      expect(items.first['progress'], contains('7'));
      expect(jsonEncode(snapshots), isNot(contains('token=private')));
      expect(jsonEncode(snapshots), isNot(contains('example.invalid')));
      expect(reads, 6);
    },
  );

  test(
    'warms only two covers for a first card when no widgets exist',
    () async {
      active = false;
      await service([
        history('one'),
        history('two'),
        history('three'),
      ]).refresh();
      expect(latest()['items'], hasLength(3));
      expect(reads, 2);
    },
  );

  test(
    'chapter progress stays compact and preserves non-default groups',
    () async {
      final record = history('progress')..maxPage = 20;
      await service([record]).refresh();
      var item = (latest()['items'] as List).single as Map;
      expect(item['progress'], 'Ch. 2 · 7/20');
      expect(item['pageProgress'], 35);
      record.group = 3;
      record.page = 25;
      await service([record]).refresh();
      item = (latest()['items'] as List).single as Map;
      expect(item['progress'], contains('Group 3'));
      expect(item['pageProgress'], 100);
      record.maxPage = null;
      await service([record]).refresh();
      item = (latest()['items'] as List).single as Map;
      expect(item['pageProgress'], -1);
    },
  );

  test('app lock never reads history or fetches covers', () async {
    appdata.settings['authorizationRequired'] = true;
    await ReadingWidgetService(
      recent: () => throw StateError('Private database accessed'),
      following: () => throw StateError('Private favorites accessed'),
      local: () => throw StateError('Private library accessed'),
      coverBytes: (_) => throw StateError('Private cover accessed'),
    ).refresh();
    expect(snapshots, hasLength(4));
    expect(
      snapshots.every((snapshot) => (snapshot['items'] as List).isEmpty),
      isTrue,
    );
    expect(latest()['emptyText'], 'Open VeneraX to view comics');
  });

  test(
    'locking during a cover load cannot republish private content',
    () async {
      final loading = Completer<Uint8List>();
      final started = Completer<void>();
      final publisher = service(
        [history('secret')],
        load: (_) {
          started.complete();
          return loading.future;
        },
      );
      final first = publisher.refresh();
      await started.future;
      appdata.settings['authorizationRequired'] = true;
      await publisher.refresh();
      final lastPublicWrite = snapshots.length;
      loading.complete(Uint8List(0));
      await first;
      expect(snapshots.length, lastPublicWrite);
      expect(latest()['items'], isEmpty);
    },
  );

  test(
    'clearing history while a cover loads cannot restore a deleted entry',
    () async {
      final records = [history('removed')];
      final loading = Completer<Uint8List>();
      final started = Completer<void>();
      final publisher = service(
        records,
        load: (_) {
          started.complete();
          return loading.future;
        },
      );
      final first = publisher.refresh();
      await started.future;
      records.clear();
      await publisher.refresh();
      loading.complete(Uint8List(0));
      await first;
      expect(latest()['items'], isEmpty);
    },
  );

  test(
    'widget link preserves source identity and encoded comic identifiers',
    () {
      final record = history('书/one?x=1&y=2+#', type: 98234);
      expect(
        resolveReadingWidgetLink(Uri.parse(readingWidgetComicUri(record))),
        (kind: ReadingWidgetKind.history, id: record.id, type: 98234),
      );
      expect(resolveReadingWidgetLink(Uri.parse(readingWidgetHistoryUri)), (
        kind: ReadingWidgetKind.history,
        id: null,
        type: null,
      ));
    },
  );

  test(
    'a fresh process reuses saved thumbnails without requiring the network',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawColor(const ui.Color(0xff446688), ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(12, 18);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final bytes = png.buffer.asUint8List(
        png.offsetInBytes,
        png.lengthInBytes,
      );
      image.dispose();
      picture.dispose();
      final records = [history('offline')];
      await service(records, load: (_) async => bytes).refresh();
      final path = (latest()['items'] as List).single['coverPath'] as String;
      expect(path, isNotEmpty);
      expect(File(path).existsSync(), isTrue);
      snapshots.clear();
      var networkCalls = 0;
      await service(
        records,
        load: (_) async {
          networkCalls++;
          throw StateError('Offline');
        },
      ).refresh();
      expect(networkCalls, 0);
      expect((snapshots.first['items'] as List).single['coverPath'], path);
      expect(File(path).existsSync(), isTrue);
    },
  );

  test('malformed or unrelated links never become widget navigation', () {
    for (final link in [
      'https://reading-widget/history',
      'venerax://other/history',
      'venerax://reading-widget:80/history',
      'venerax://user@reading-widget/history',
      'venerax://reading-widget/history?id=one',
      'venerax://reading-widget/read?id=one&type=abc',
      'venerax://reading-widget/read?id=&type=0',
      'venerax://reading-widget/read?id=one&id=two&type=0',
      'venerax://reading-widget/read?id=one&type=0&path=/private/file',
      'venerax://reading-widget/read?id=one&type=0#fragment',
    ]) {
      expect(resolveReadingWidgetLink(Uri.parse(link)), isNull, reason: link);
    }
  });

  test(
    'background follow refresh leaves other kinds and cached covers intact',
    () async {
      final cover = File(
        '${directory.path}/reading_widget_covers/retained.png',
      );
      cover.parent.createSync();
      cover.writeAsBytesSync([1]);
      await ReadingWidgetService(
        recent: () => throw StateError('History is unavailable in this worker'),
        local: () =>
            throw StateError('Local library is unavailable in this worker'),
        following: () => [],
        coverBytes: (_) =>
            throw StateError('Background must not fetch thumbnails'),
      ).refresh(
        kinds: const [ReadingWidgetKind.following, ReadingWidgetKind.updates],
        loadCovers: false,
      );
      expect(snapshots.map((snapshot) => snapshot['kind']), [
        'following',
        'updates',
      ]);
      expect(cover.existsSync(), isTrue);
    },
  );

  test(
    'four kinds keep their own contents, destinations and check status',
    () async {
      active = false;
      FavoriteItemWithUpdateInfo followed(
        String id,
        bool updated,
        int checked,
      ) => FavoriteItemWithUpdateInfo(
        FavoriteItem(
          id: id,
          name: id,
          coverPath: '',
          author: '',
          type: const ComicType(42),
          tags: [],
        ),
        '2026-11-10',
        updated,
        checked,
      );
      final followedItems = [
        followed('new', true, 1000),
        followed('read', false, 2000),
      ];
      File('${directory.path}/page.png').writeAsBytesSync([1]);
      final downloaded = LocalComic(
        id: 'offline',
        title: 'Offline',
        subtitle: '',
        tags: [],
        directory: directory.path,
        chapters: null,
        cover: 'page.png',
        comicType: ComicType.local,
        downloadedChapters: [],
        createdAt: DateTime(2026),
      );
      final publisher = ReadingWidgetService(
        recent: () => [history('recent')],
        following: () => followedItems,
        local: () => [downloaded],
        visible: (_) => true,
        coverBytes: (_) async => Uint8List(0),
      );
      await publisher.refresh();
      expect((latest()['items'] as List).map((item) => item['id']), ['recent']);
      expect(
        (latest(ReadingWidgetKind.following)['items'] as List).map(
          (item) => item['id'],
        ),
        ['new', 'read'],
      );
      expect(
        (latest(ReadingWidgetKind.updates)['items'] as List).map(
          (item) => item['id'],
        ),
        ['new'],
      );
      expect(
        (latest(ReadingWidgetKind.local)['items'] as List).map(
          (item) => item['id'],
        ),
        ['offline'],
      );
      for (final kind in ReadingWidgetKind.values) {
        final item = (latest(kind)['items'] as List).first;
        expect(resolveReadingWidgetLink(Uri.parse(item['uri'])), (
          kind: kind,
          id: item['id'],
          type: item['type'],
        ));
        expect(
          resolveReadingWidgetLink(
            Uri.parse('venerax://reading-widget/${kind.name}'),
          ),
          (kind: kind, id: null, type: null),
        );
      }
      final previousCheck = latest(ReadingWidgetKind.updates)['subtitle'];
      followedItems[0].hasNewUpdate = false;
      followedItems[0].lastCheckTime = 100000;
      await publisher.refresh();
      expect(latest(ReadingWidgetKind.updates)['items'], isEmpty);
      expect(
        latest(ReadingWidgetKind.updates)['subtitle'],
        isNot(previousCheck),
      );
      expect(latest(ReadingWidgetKind.following)['items'], hasLength(2));
    },
  );
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
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
    bool Function(History)? visible,
    Future<Uint8List> Function(History)? load,
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
      final items = snapshots.last['items'] as List;
      expect(items.map((item) => item['id']), ['1', '2', '3', '4', '5', '6']);
      expect(items.first['progress'], contains('7'));
      expect(jsonEncode(snapshots), isNot(contains('token=private')));
      expect(jsonEncode(snapshots), isNot(contains('example.invalid')));
      expect(reads, 6);
    },
  );

  test(
    'keeps a text snapshot without loading covers when no widgets exist',
    () async {
      active = false;
      await service([history('one')]).refresh();
      expect(snapshots, hasLength(1));
      expect(snapshots.single['items'], hasLength(1));
      expect(reads, 0);
    },
  );

  test('app lock never reads history or fetches covers', () async {
    appdata.settings['authorizationRequired'] = true;
    await ReadingWidgetService(
      recent: () => throw StateError('Private database accessed'),
      coverBytes: (_) => throw StateError('Private cover accessed'),
    ).refresh();
    expect(snapshots.single['items'], isEmpty);
    expect(
      snapshots.single['emptyText'],
      'Open VeneraX to view reading history',
    );
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
      expect(snapshots.last['items'], isEmpty);
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
      expect(snapshots.last['items'], isEmpty);
    },
  );

  test(
    'widget link preserves source identity and encoded comic identifiers',
    () {
      final record = history('书/one?x=1&y=2+#', type: 98234);
      expect(
        resolveReadingWidgetLink(Uri.parse(readingWidgetComicUri(record))),
        (id: record.id, type: 98234),
      );
      expect(resolveReadingWidgetLink(Uri.parse(readingWidgetHistoryUri)), (
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
      final path =
          (snapshots.last['items'] as List).single['coverPath'] as String;
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
}

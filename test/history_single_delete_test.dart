import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/utils/translations.dart';

const _setting = 'clearReadingProgressOnSingleHistoryDelete';
final _readAt = DateTime(2026, 11, 11, 10);

History _history({String id = 'target', int type = 0, int page = 2}) =>
    History.fromMap({
      'id': id,
      'type': type,
      'title': '$id-$type',
      'subtitle': '',
      'cover': 'https://example.invalid/$id-$type.jpg',
      'time': _readAt.millisecondsSinceEpoch,
      'ep': 3,
      'page': page,
      'readEpisode': '1,2,3',
      'max_page': 26,
    });

Future<void> _showHistory(WidgetTester tester) async {
  for (final history in HistoryManager().getAll()) {
    final pixels = await tester.runAsync(
      () => createTestImage(width: 20, height: 30),
    );
    PaintingBinding.instance.imageCache.putIfAbsent(
      findImageProvider(history)!,
      () => OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: pixels!)),
      ),
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: const OverlayWidget(HistoryPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _deleteFromMenu(WidgetTester tester, History history) async {
  final tile = tester
      .widgetList<ComicTile>(find.byType(ComicTile))
      .firstWhere((tile) => tile.comic == history);
  tile.menuOptions!.firstWhere((entry) => entry.text == 'Remove').onClick();
  await tester.pumpAndSettle();
  await tester.tap(find.text('Confirm'));
  // Let the history write queue leave the widget test's fake-async zone.
  await tester.runAsync(() async {});
  await tester.pumpAndSettle();
}

void main() {
  late Directory directory;
  late String originalDataPath;
  late String originalCachePath;
  late Map<String, dynamic> originalSettings;
  late HistoryManager manager;
  HistoryManager? originalHistoryManager;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  setUp(() async {
    originalHistoryManager = HistoryManager.cache;
    manager = HistoryManager.create();
    HistoryManager.cache = manager;
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    originalSettings = Map<String, dynamic>.from(appdata.toJson()['settings']);
    directory = Directory.systemTemp.createTempSync('venera-single-history-');
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    appdata.implicitData['image_favorites_cache_key_fix_v1'] = true;
    appdata.settings['language'] = 'en-US';
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings[_setting] = false;
    await manager.init();
  });

  tearDown(() {
    manager.close();
    HistoryManager.cache = originalHistoryManager;
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    (appdata.toJson()['settings'] as Map<String, dynamic>)
      ..clear()
      ..addAll(originalSettings);
    PaintingBinding.instance.imageCache.clear();
    directory.deleteSync(recursive: true);
  });

  test('late maintenance cannot recreate deleted reading progress', () {
    final history = _history();
    manager.addHistory(history);
    manager.remove(history.id, history.type);

    history.cover = 'https://example.invalid/refreshed.jpg';
    manager.updateHistoryKeepingVisibility(history);

    expect(manager.find(history.id, history.type), isNull);
    expect(manager.getAll(), isEmpty);
  });

  test('clearing progress waits for all earlier reader saves', () async {
    manager.addHistory(_history());
    final firstSave = manager.addHistoryAsync(_history(page: 10));
    final secondSave = manager.addHistoryAsync(_history(page: 20));
    final deletion = manager.clearReadingProgress('target', ComicType.local);

    await Future.wait([firstSave, secondSave, deletion]);

    expect(manager.find('target', ComicType.local), isNull);
    expect(manager.getAll(), isEmpty);

    await manager.addHistoryAsync(_history(page: 1)..readEpisode = {'1'});
    expect(manager.find('target', ComicType.local)!.page, 1);
    expect(manager.find('target', ComicType.local)!.readEpisode, {'1'});
  });

  for (final clearProgress in [false, true]) {
    testWidgets(
      'single menu deletion clears progress only when $clearProgress',
      (tester) async {
        appdata.settings[_setting] = clearProgress;
        final target = _history();
        final otherSource = _history(type: 7);
        manager.addHistory(target);
        manager.addHistory(otherSource);
        manager.recordReadingDuration(
          id: target.id,
          type: target.type,
          title: target.title,
          subtitle: target.subtitle,
          cover: target.cover,
          startedAt: _readAt,
          duration: const Duration(minutes: 5),
        );
        await _showHistory(tester);

        await _deleteFromMenu(tester, target);

        expect(manager.getAll(), [otherSource]);
        final saved = manager.find(target.id, target.type);
        if (clearProgress) {
          expect(saved, isNull);
        } else {
          expect(saved!.page, 2);
          expect(saved.readEpisode, {'1', '2', '3'});
        }
        expect(manager.find(otherSource.id, otherSource.type)!.page, 2);
        expect(
          manager.getReadingStatistics(now: _readAt).total,
          const Duration(minutes: 5),
        );

        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(manager.find(target.id, target.type)!.page, 2);
        expect(manager.find(target.id, target.type)!.ep, 3);
        expect(manager.find(target.id, target.type)!.readEpisode, {
          '1',
          '2',
          '3',
        });

        await tester.pump(const Duration(seconds: 3));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('undo restores the latest save after the confirmation opened', (
    tester,
  ) async {
    appdata.settings[_setting] = true;
    final target = _history();
    manager.addHistory(target);
    await _showHistory(tester);
    final tile = tester.widget<ComicTile>(find.byType(ComicTile));
    tile.menuOptions!.firstWhere((entry) => entry.text == 'Remove').onClick();
    await tester.pumpAndSettle();

    await tester.runAsync(
      () => manager.addHistoryAsync(
        _history(page: 20)
          ..ep = 4
          ..readEpisode = {'1', '2', '3', '4'},
      ),
    );
    await tester.tap(find.text('Confirm'));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();
    expect(manager.find(target.id, target.type), isNull);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    final restored = manager.find(target.id, target.type)!;
    expect(restored.page, 20);
    expect(restored.ep, 4);
    expect(restored.readEpisode, {'1', '2', '3', '4'});
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final clearProgress in [false, true]) {
    testWidgets('single swipe respects the progress setting $clearProgress', (
      tester,
    ) async {
      appdata.settings[_setting] = clearProgress;
      final target = _history();
      manager.addHistory(target);
      await _showHistory(tester);

      final tile = find.byType(SwipeActionTile);
      final width = tester.getSize(tile).width;
      await tester.dragFrom(
        tester.getCenter(tile) + Offset(width * .4, 0),
        Offset(-width * .8, 0),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.runAsync(() async {});
      await tester.pumpAndSettle();

      expect(manager.getAll(), isEmpty);
      if (clearProgress) {
        expect(manager.find(target.id, target.type), isNull);
      } else {
        expect(manager.find(target.id, target.type)!.page, 2);
      }
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(manager.find(target.id, target.type)!.page, 2);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('batch deletion keeps progress with the setting enabled', (
    tester,
  ) async {
    appdata.settings[_setting] = true;
    final first = _history();
    final second = _history(id: 'other');
    manager.addHistory(first);
    manager.addHistory(second);
    await _showHistory(tester);

    await tester.tap(find.byTooltip('Multi-Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(first.title));
    await tester.tap(find.text(second.title));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.runAsync(() async {});
    await tester.pumpAndSettle();

    expect(manager.getAll(), isEmpty);
    expect(manager.find(first.id, first.type)!.page, 2);
    expect(manager.find(second.id, second.type)!.readEpisode, {'1', '2', '3'});
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual clear keeps progress with the setting enabled', (
    tester,
  ) async {
    appdata.settings[_setting] = true;
    final target = _history();
    manager.addHistory(target);
    await _showHistory(tester);

    tester
        .widgetList<MenuButton>(find.byType(MenuButton))
        .expand((button) => button.entries)
        .firstWhere((entry) => entry.text == 'Clear History')
        .onClick();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(manager.getAll(), isEmpty);
    expect(manager.find(target.id, target.type)!.page, 2);
    expect(manager.find(target.id, target.type)!.readEpisode, {'1', '2', '3'});
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('open history page updates swipe policy after changing setting', (
    tester,
  ) async {
    manager.addHistory(_history());
    await _showHistory(tester);
    final tile = find.byType(SwipeActionTile);
    expect(
      tester.widget<SwipeActionTile>(tile).endPane!.keepItemOnFullSwipe,
      isFalse,
    );

    appdata.settings[_setting] = true;
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwipeActionTile>(tile).endPane!.keepItemOnFullSwipe,
      isTrue,
    );

    appdata.settings[_setting] = false;
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwipeActionTile>(tile).endPane!.keepItemOnFullSwipe,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('automatic cleanup keeps progress with the setting enabled', () {
    appdata.settings[_setting] = true;
    final target = _history()..time = DateTime(2000);
    manager.addHistory(target);

    expect(manager.cleanHistoryOlderThan(const Duration(days: 1)), 1);

    expect(manager.getAll(), isEmpty);
    expect(manager.find(target.id, target.type)!.page, 2);
    expect(manager.find(target.id, target.type)!.readEpisode, {'1', '2', '3'});
  });
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory directory;
  late String originalDataPath;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    directory = Directory.systemTemp.createTempSync('venera-home-hero-');
    originalDataPath = App.dataPath;
    App.dataPath = directory.path;
    await HistoryManager().init();
    await ReadLaterManager().init();
  });

  tearDownAll(() {
    ReadLaterManager().close();
    HistoryManager().close();
    App.dataPath = originalDataPath;
    directory.deleteSync(recursive: true);
  });

  setUp(() async {
    appdata.settings['language'] = 'en-US';
    appdata.settings['homeSections'] = [
      for (final section in kHomeSections)
        {
          'id': section.id,
          'visible': ['history', 'readLater'].contains(section.id),
        },
    ];
    await ReadLaterManager().clearAll();
    for (final history in HistoryManager().getAll()) {
      HistoryManager().remove(history.id, history.type);
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  for (final sourceTypes in [
    [123],
    [123, 456],
  ]) {
    testWidgets(
      'home covers survive navigation with ${sourceTypes.length} sources',
      (tester) async {
        final histories = [
          for (final type in sourceTypes)
            History.fromMap({
              'id': 'shared-comic-id',
              'type': type,
              'title': 'History cover $type',
              'cover': 'https://example.invalid/$type.png',
              'time': DateTime.now().millisecondsSinceEpoch,
              'ep': 1,
              'page': 2,
            }),
        ];
        final readLater = [
          for (final history in histories)
            ReadLaterItem(
              id: history.id,
              title: history.title,
              cover: history.cover,
              type: history.type,
              time: history.time,
            ),
        ];
        for (final history in histories) {
          HistoryManager().addHistory(history);
        }
        // Cache decoded images so the test exercises rendering without HTTP.
        for (final comic in <Comic>[...histories, ...readLater]) {
          final provider = findImageProvider(comic)!;
          final pixels = await tester.runAsync(
            () => createTestImage(width: 20, height: 30),
          );
          PaintingBinding.instance.imageCache.putIfAbsent(
            provider,
            () => OneFrameImageStreamCompleter(
              SynchronousFuture(ImageInfo(image: pixels!)),
            ),
          );
        }
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: HomePage()),
          ),
        );
        await tester.pumpAndSettle();
        await ReadLaterManager().addMultiple(readLater);
        await tester.pumpAndSettle();
        expect(
          find.byType(SimpleComicTile),
          findsNWidgets(histories.length * 2),
        );

        for (final index in [0, histories.length]) {
          final hero = tester.widget<Hero>(find.byType(Hero).at(index));
          final tile = tester.widget<SimpleComicTile>(
            find.byType(SimpleComicTile).at(index),
          );
          navigatorKey.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: Hero(
                  tag: hero.tag,
                  child: AnimatedImage(image: findImageProvider(tile.comic)!),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          navigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(
            find.descendant(
              of: find.byType(SimpleComicTile),
              matching: find.byType(RawImage),
            ),
            findsNWidgets(histories.length * 2),
          );
        }

        await ReadLaterManager().clearAll();
        await tester.pumpAndSettle();
        expect(find.byType(SimpleComicTile), findsNWidgets(histories.length));
        for (final history in histories) {
          final saved = HistoryManager().find(history.id, history.type)!;
          expect(saved.cover, history.cover);
          expect(saved.page, 2);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

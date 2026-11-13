import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/random_comic_draw.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/random_comic_scope.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/pages/random_comic_draw_dialog.dart';
import 'package:venera/utils/translations.dart';

late String _coverPath;

FavoriteItem _comic(String id, {int type = 123, String? title}) => FavoriteItem(
  id: id,
  name: title ?? 'Comic $id ($type)',
  coverPath: _coverPath,
  author: 'Test author',
  type: ComicType(type),
  tags: const [],
);

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 500 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(ready(), isTrue, reason: 'The dialog must finish its pending work');
}

Future<void> _drain(WidgetTester tester, Future<void> work) async {
  var done = false;
  unawaited(work.then((_) => done = true));
  await _waitUntil(tester, () => done);
}

Future<void> _drainDatabase(WidgetTester tester) async {
  // Keep the gateway tail outside the widget clock for the next test.
  late Future<void> work;
  await tester.runAsync(() async {
    work = DatabaseGateway.instance.runExclusive(() async {});
  });
  await _drain(tester, work);
}

bool _enabled(WidgetTester tester, String key) {
  final finder = _key(key);
  if (finder.evaluate().isEmpty) return false;
  return tester.widget<ButtonStyleButton>(finder).onPressed != null;
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.pump();
  await tester.tap(_key(key));
  await tester.pump();
}

Future<Completer<FavoriteItem?>> _open(
  WidgetTester tester, {
  bool disableAnimations = false,
  double textScale = 1,
  bool waitReady = true,
}) async {
  final result = Completer<FavoriteItem?>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open-draw'),
            onPressed: () {
              showRandomComicDrawDialog(context).then(result.complete);
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, 'open-draw');
  if (waitReady) {
    await _waitUntil(tester, () => _enabled(tester, 'draw-button'));
    await tester.pumpAndSettle();
  }
  return result;
}

List<String> _titles(WidgetTester tester, List<FavoriteItem> comics) => [
  for (final comic in comics)
    if (find.text(comic.title).evaluate().isNotEmpty) comic.title,
];

Future<void> _draw(WidgetTester tester, {bool revealAll = false}) async {
  await _tap(tester, 'draw-button');
  if (revealAll) {
    await _waitUntil(tester, () => _enabled(tester, 'draw-reveal-all'));
    await _tap(tester, 'draw-reveal-all');
  }
  await _waitUntil(tester, () => _enabled(tester, 'draw-read'));
  await tester.pumpAndSettle();
}

double? _progress(WidgetTester tester) {
  final indicator = find.descendant(
    of: _key('draw-round-progress'),
    matching: find.byType(LinearProgressIndicator),
    matchRoot: true,
  );
  return tester.widget<LinearProgressIndicator>(indicator).value;
}

void _drawTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
      await _drain(tester, appdata.writeImplicitData());
      await _drain(tester, appdata.saveData(false));
      await _drainDatabase(tester);
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('missing remembered folder never reaches the dropdown value', (
    tester,
  ) async {
    const rememberedFolder = '默认收藏';
    const folders = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DropdownButtonFormField<String?>(
            initialValue: randomComicAvailableFolder(rememberedFolder, folders),
            items: const [
              DropdownMenuItem<String?>(value: null, child: Text('全部收藏')),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  test('available remembered folder is retained', () {
    expect(randomComicAvailableFolder('默认收藏', const ['默认收藏', '稍后看']), '默认收藏');
  });

  test('reading status is restored by its stored name', () {
    expect(
      randomComicReadingScopeFromName('completed'),
      RandomComicReadingScope.completed,
    );
    expect(
      randomComicReadingScopeFromName('removed-value'),
      RandomComicReadingScope.all,
    );
  });

  group('real favorites draw dialog', () {
    final favorites = LocalFavoritesManager();
    final history = HistoryManager();
    final readLater = ReadLaterManager();
    final originalDataPath = App.dataPath;
    final originalCachePath = App.cachePath;
    late Directory temp;

    setUpAll(() async {
      temp = Directory.systemTemp.createTempSync('random-comic-dialog-');
      App.dataPath = temp.path;
      App.cachePath = '${temp.path}/cache';
      await AppTranslation.init();
      await appdata.init();
      appdata.settings['language'] = 'en-US';
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.indigo, BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(40, 60);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final cover = File('${temp.path}/cover.png');
      await cover.writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
      picture.dispose();
      _coverPath = 'file://${cover.path}';
      await history.init();
      await favorites.init();
      await readLater.init();
      await appdata.saveData(false);
      await DatabaseGateway.instance.runExclusive(() async {});
    });

    setUp(() async {
      for (final folder in favorites.folderNames.toList()) {
        if (favorites.existsFolder(folder)) favorites.deleteFolder(folder);
      }
      favorites.createFolder('A');
      favorites.createFolder('B');
      for (final item in history.getAll()) {
        history.remove(item.id, item.type);
      }
      await readLater.clearAll();
      appdata.implicitData.removeWhere(
        (key, _) => key.startsWith('random_comic_'),
      );
      await appdata.writeImplicitData();
      await DatabaseGateway.instance.runExclusive(() async {});
    });

    tearDownAll(() async {
      await appdata.writeImplicitData();
      await appdata.saveData(false);
      await DatabaseGateway.instance.runExclusive(() async {});
      readLater.close();
      favorites.close();
      history.close();
      App.dataPath = originalDataPath;
      App.cachePath = originalCachePath;
      final parent = Directory.systemTemp.absolute.path;
      if (!temp.absolute.path.startsWith('$parent${Platform.pathSeparator}')) {
        throw StateError('Test directory must remain inside system temp');
      }
      await temp.delete(recursive: true);
    });

    void seed(List<FavoriteItem> comics, [String folder = 'A']) {
      for (final comic in comics) {
        expect(favorites.addComic(folder, comic), isTrue);
      }
    }

    Future<void> selectFolder(WidgetTester tester, String folder) async {
      await _tap(tester, 'draw-folder');
      await tester.pumpAndSettle();
      await tester.tap(find.text(folder).last);
      await tester.pump();
      await _waitUntil(tester, () => _enabled(tester, 'draw-button'));
      await tester.pumpAndSettle();
    }

    _drawTest('single draw returns the real favorite', (tester) async {
      final comic = _comic('only');
      seed([comic]);
      final result = await _open(tester);
      await _draw(tester);
      expect(_titles(tester, [comic]), [comic.title]);
      expect(_key('draw-card-1'), findsNothing);
      await _tap(tester, 'draw-read');
      expect(await result.future, comic);
    });

    _drawTest('three cards reveal individually and return the selected comic', (
      tester,
    ) async {
      final comics = List.generate(3, (index) => _comic('$index'));
      seed(comics);
      final result = await _open(tester);
      await _tap(tester, 'draw-mode-three');
      await _tap(tester, 'draw-button');
      await _waitUntil(tester, () => _enabled(tester, 'draw-reveal-all'));
      await tester.pumpAndSettle();
      expect(_titles(tester, comics), isEmpty);
      for (var i = 0; i < 3; i++) {
        await _tap(tester, 'draw-card-$i');
        await tester.pumpAndSettle();
        expect(_titles(tester, comics), hasLength(i + 1));
      }
      final selectedTitle = tester
          .widget<Text>(
            find
                .descendant(
                  of: _key('draw-card-2'),
                  matching: find.byType(Text),
                )
                .first,
          )
          .data;
      await _tap(tester, 'draw-card-2');
      await _tap(tester, 'draw-read');
      expect((await result.future)?.title, selectedTitle);
    });

    _drawTest(
      'rounds deduplicate folders, preserve types and draw only the remainder',
      (tester) async {
        final comics = [
          _comic('same'),
          _comic('second'),
          _comic('third'),
          _comic('same', type: 456),
        ];
        seed(comics);
        seed([comics.first], 'B');
        appdata.implicitData['random_comic_draw_count'] = 3;
        await _open(tester);
        await _draw(tester, revealAll: true);
        final first = _titles(tester, comics).toSet();
        expect(first, hasLength(3));
        expect(_progress(tester), closeTo(3 / 4, 0.0001));
        await _draw(tester, revealAll: true);
        final remainder = _titles(tester, comics).toSet();
        expect(remainder, hasLength(1));
        expect(first.intersection(remainder), isEmpty);
        expect(
          first.union(remainder),
          comics.map((comic) => comic.title).toSet(),
        );
        expect(_key('draw-card-1'), findsNothing);
        expect(_progress(tester), 1);
        await _draw(tester, revealAll: true);
        expect(_titles(tester, comics), hasLength(3));
        expect(_progress(tester), closeTo(3 / 4, 0.0001));
      },
    );

    _drawTest(
      'double tap consumes one draw and changing mode keeps exclusions',
      (tester) async {
        final comics = List.generate(4, (index) => _comic('$index'));
        seed(comics);
        await _open(tester);
        await tester.tap(_key('draw-button'));
        await tester.tap(_key('draw-button'));
        await tester.pump();
        await _waitUntil(tester, () => _enabled(tester, 'draw-read'));
        await tester.pumpAndSettle();
        final first = _titles(tester, comics).single;
        expect(_progress(tester), 0.25);
        await _tap(tester, 'draw-mode-three');
        await _draw(tester, revealAll: true);
        expect(_titles(tester, comics), hasLength(3));
        expect(_titles(tester, comics), isNot(contains(first)));
        expect(_progress(tester), 1);
      },
    );

    for (final reducedMotion in [false, true]) {
      _drawTest(
        reducedMotion
            ? 'reduced motion reveals all cards automatically'
            : 'quick reveal preference reveals all cards automatically',
        (tester) async {
          final comics = List.generate(3, (index) => _comic('$index'));
          seed(comics);
          appdata.implicitData['random_comic_draw_count'] = 3;
          appdata.implicitData['random_comic_quick_reveal'] = !reducedMotion;
          await _open(tester, disableAnimations: reducedMotion);
          await _draw(tester);
          expect(_titles(tester, comics), hasLength(3));
          expect(_enabled(tester, 'draw-read'), isTrue);
          expect(tester.takeException(), isNull);
        },
      );
    }

    _drawTest(
      'preferences restore and stale folder or reading values fall back',
      (tester) async {
        final first = _comic('first');
        final completed = _comic('completed');
        seed([first]);
        seed([completed], 'B');
        history.addHistory(
          History.fromMap({
            'id': completed.id,
            'type': completed.type.value,
            'title': completed.title,
            'ep': 1,
            'page': 10,
            'max_page': 10,
          }),
        );
        appdata.implicitData.addAll({
          'random_comic_selection_folder': 'B',
          'random_comic_reading_scope': 'completed',
          'random_comic_draw_count': 3,
          'random_comic_quick_reveal': true,
        });
        final result = await _open(tester);
        await _tap(tester, 'draw-scope-toggle');
        expect(
          tester.state<FormFieldState<String?>>(_key('draw-folder')).value,
          'B',
        );
        expect(
          tester
              .state<FormFieldState<RandomComicReadingScope>>(
                _key('draw-reading-scope'),
              )
              .value,
          RandomComicReadingScope.completed,
        );
        await _draw(tester);
        expect(_titles(tester, [first, completed]), [completed.title]);
        await _tap(tester, 'draw-read');
        expect(await result.future, completed);
        await tester.pumpAndSettle();
        appdata.implicitData.addAll({
          'random_comic_selection_folder': 'Deleted folder',
          'random_comic_reading_scope': 'removed-value',
          'random_comic_draw_count': 2,
        });
        await _open(tester);
        await _tap(tester, 'draw-scope-toggle');
        expect(
          tester.state<FormFieldState<String?>>(_key('draw-folder')).value,
          isNull,
        );
        expect(
          tester
              .state<FormFieldState<RandomComicReadingScope>>(
                _key('draw-reading-scope'),
              )
              .value,
          RandomComicReadingScope.all,
        );
        await _draw(tester);
        expect(_titles(tester, [first, completed]), hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );

    _drawTest('folder changes reset the round and persist the selection', (
      tester,
    ) async {
      final comics = [_comic('a1'), _comic('a2')];
      final other = _comic('b');
      seed(comics);
      seed([other], 'B');
      appdata.implicitData['random_comic_selection_folder'] = 'A';
      appdata.implicitData['random_comic_quick_reveal'] = true;
      await _open(tester);
      await _draw(tester);
      expect(_progress(tester), 0.5);
      await _tap(tester, 'draw-scope-toggle');
      await selectFolder(tester, 'B');
      expect(_progress(tester), 0);
      expect(appdata.implicitData['random_comic_selection_folder'], 'B');
      await _draw(tester);
      expect(_titles(tester, [...comics, other]), [other.title]);
      await selectFolder(tester, 'A');
      await _tap(tester, 'draw-mode-three');
      await _draw(tester);
      expect(_titles(tester, comics), hasLength(2));
      expect(appdata.implicitData['random_comic_draw_count'], 3);
      expect(_progress(tester), 1);
    });

    _drawTest(
      'read later adds and removes an uninstalled source without changing its type',
      (tester) async {
        final comic = _comic('orphan', type: 123);
        seed([comic]);
        await _open(tester);
        await _draw(tester);
        await _tap(tester, 'draw-read-later');
        await tester.pumpAndSettle();
        expect(readLater.isExist(comic.id, comic.type), isTrue);
        expect(readLater.getAll().single.type, const ComicType(123));
        expect(readLater.isExist(comic.id, const ComicType(0)), isFalse);
        await _tap(tester, 'draw-read-later');
        await tester.pumpAndSettle();
        expect(readLater.getAll(), isEmpty);
      },
    );

    _drawTest('320px layout remains usable with large text and three cards', (
      tester,
    ) async {
      final comics = List.generate(
        3,
        (index) => _comic(
          '$index',
          title: 'A very long comic title for narrow screens $index',
        ),
      );
      seed(comics);
      tester.view.physicalSize = const Size(320, 640);
      appdata.implicitData['random_comic_draw_count'] = 3;
      appdata.implicitData['random_comic_quick_reveal'] = true;
      final result = await _open(tester, textScale: 2);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'draw-scope-toggle');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _draw(tester);
      expect(tester.takeException(), isNull);
      await _tap(tester, 'draw-read');
      expect(await result.future, isIn(comics));
    });

    _drawTest(
      'drawing keeps dialog and stage sizes stable, including the last partial hand',
      (tester) async {
        seed(List.generate(5, (index) => _comic('$index')));
        appdata.implicitData['random_comic_quick_reveal'] = true;
        await _open(tester);
        final dialog = tester.getRect(find.byType(Dialog));
        final singleStage = tester.getSize(find.byType(RandomComicDrawStage));
        await _draw(tester);
        expect(tester.getRect(find.byType(Dialog)), dialog);
        expect(tester.getSize(find.byType(RandomComicDrawStage)), singleStage);
        await _tap(tester, 'draw-mode-three');
        await tester.pumpAndSettle();
        final threeStage = tester.getSize(find.byType(RandomComicDrawStage));
        await _draw(tester);
        expect(_key('draw-card-2'), findsOneWidget);
        expect(tester.getRect(find.byType(Dialog)), dialog);
        expect(tester.getSize(find.byType(RandomComicDrawStage)), threeStage);
        await _draw(tester);
        expect(_key('draw-card-1'), findsNothing);
        expect(tester.getRect(find.byType(Dialog)), dialog);
        expect(tester.getSize(find.byType(RandomComicDrawStage)), threeStage);
      },
    );

    _drawTest(
      'closing during loading or drawing leaves no asynchronous error',
      (tester) async {
        seed(List.generate(3, (index) => _comic('$index')));
        var result = await _open(tester, waitReady: false);
        App.rootNavigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(await result.future, isNull);
        await _drainDatabase(tester);
        expect(tester.takeException(), isNull);
        result = await _open(tester);
        await _tap(tester, 'draw-button');
        await tester.pump(const Duration(milliseconds: 40));
        App.rootNavigatorKey.currentState!.pop();
        await tester.pump(const Duration(seconds: 3));
        expect(await result.future, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  });
}

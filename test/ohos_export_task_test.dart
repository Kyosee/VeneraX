import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/export_tasks.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart' show IO;
import 'package:xml/xml.dart';

typedef _SavedFile = ({String name, String path, Uint8List bytes});

Future<void> _until(
  bool Function() condition, {
  String Function()? describe,
}) async {
  final elapsed = Stopwatch()..start();
  while (!condition()) {
    if (elapsed.elapsed > const Duration(seconds: 10)) {
      throw TimeoutException(
        describe?.call() ?? 'Export did not reach the expected state',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<Uint8List> _png(ui.Color color) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(2, 3);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ohos = TargetPlatform.values.where((value) => value.name == 'ohos');
  // Use the same mobile save channel on the upstream SDK without an OHOS enum.
  final dialogPlatform = ohos.firstOrNull ?? TargetPlatform.iOS;
  final expectedNames = [
    '同名漫画.epub',
    ohos.isNotEmpty ? '同名漫画 (2).epub' : '同名漫画.epub',
  ];
  const channel = MethodChannel('flutter_file_dialog');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('legacy export records keep directory mode', () {
    final task = ExportTask(
      id: 'legacy',
      folderPath: '/existing/export',
      format: ExportFormat.epub,
      comics: const [],
      createdAt: DateTime.utc(2026),
    );
    final legacy = task.toJson()..remove('saveWithDialog');
    final restored = ExportTask.fromJson(legacy);
    expect(restored.saveWithDialog, isFalse);
    expect(restored.folderPath, '/existing/export');
  });

  group(
    'comic export with system save dialogs',
    () {
      late Directory root;
      late ExportTaskManager manager;
      late String previousDataPath;
      late String previousCachePath;
      late TargetPlatform? previousTarget;
      late bool previousMuted;
      final comics = <LocalComic>[];
      final pages = <Uint8List>[];
      final saved = <_SavedFile>[];
      Future<Object?> Function(int index)? respond;

      setUpAll(() async {
        previousDataPath = App.dataPath;
        previousCachePath = App.cachePath;
        previousTarget = debugDefaultTargetPlatformOverride;
        previousMuted = Log.isMuted;
        debugDefaultTargetPlatformOverride =
            ohos.firstOrNull ?? TargetPlatform.windows;
        Log.isMuted = true;
        if (Platform.isWindows) {
          open.overrideFor(
            OperatingSystem.windows,
            () => DynamicLibrary.open('winsqlite3.dll'),
          );
        }
        root = await Directory.systemTemp.createTemp('venerax-ohos-export-');
        App.dataPath = root.path;
        App.cachePath = (await Directory('${root.path}/cache').create()).path;
        await appdata.init();
        await JsEngine().init();
        await ComicSourceManager().init();
        await LocalManager().init();
        manager = ExportTaskManager.instance;
        for (var index = 0; index < 2; index++) {
          final directory = await Directory(
            '${LocalManager().path}/comic_$index',
          ).create();
          final bytes = await _png(
            index == 0
                ? const ui.Color(0xff123456)
                : const ui.Color(0xffabcdef),
          );
          pages.add(bytes);
          await File('${directory.path}/cover.png').writeAsBytes(bytes);
          await File('${directory.path}/1.png').writeAsBytes(bytes);
          final comic = LocalComic(
            id: 'export_$index',
            title: '同名漫画',
            subtitle: 'Author $index',
            tags: const [],
            directory: 'comic_$index',
            chapters: null,
            cover: 'cover.png',
            comicType: ComicType.local,
            downloadedChapters: const [],
            createdAt: DateTime.utc(2026),
          );
          await LocalManager().add(comic);
          comics.add(comic);
        }
        debugDefaultTargetPlatformOverride = dialogPlatform;
      });

      setUp(() {
        expect(App.isMobile, isTrue);
        expect(manager.currentTasks, isEmpty);
        saved.clear();
        respond = null;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'saveFile');
          final args = Map<String, dynamic>.from(call.arguments as Map);
          final file = File(args['sourceFilePath'] as String);
          expect(file.existsSync(), isTrue);
          expect(file.path, startsWith(App.cachePath));
          saved.add((
            name: App.isOhos
                ? args['fileName'] as String
                : file.uri.pathSegments.last,
            path: file.path,
            bytes: await file.readAsBytes(),
          ));
          final index = saved.length - 1;
          return respond != null
              ? await respond!(index)
              : 'file:///documents/${Uri.encodeComponent(saved[index].name)}';
        });
      });

      tearDown(() async {
        for (final task in manager.currentTasks.toList()) {
          manager.cancel(task.id);
        }
        await _until(() => manager.currentTasks.isEmpty);
        await _until(() => !IO.isSelectingFiles);
        messenger.setMockMethodCallHandler(channel, null);
        await appdata.saveData(false);
      });

      tearDownAll(() async {
        await appdata.saveData(false);
        LocalManager().close();
        JsEngine().dispose();
        await root.delete(recursive: true);
        App.dataPath = previousDataPath;
        App.cachePath = previousCachePath;
        debugDefaultTargetPlatformOverride = previousTarget;
        Log.isMuted = previousMuted;
      });

      ExportTask start() => manager.startExport(
        folderPath: '',
        format: ExportFormat.epub,
        comics: comics,
        saveWithDialog: true,
      )!;

      Future<void> settled(
        ExportTask task, {
        Set<String> missingComicIds = const {},
      }) async {
        await _until(
          () => !task.isActive && manager.historyTasks.contains(task),
          describe: () =>
              'Task ${task.status}, saved ${saved.length}, '
              'done ${task.done}, failed ${task.failedCount}',
        );
        await _until(
          () => !Directory(
            '${App.cachePath}/export_task/${task.id}',
          ).existsSync(),
          describe: () =>
              'Task ${task.status} left its cache directory: '
              '${Directory('${App.cachePath}/export_task/${task.id}').listSync()}',
        );
        expect(manager.currentTasks, isNot(contains(task)));
        expect(task.finishedAt, isNotNull);
        for (var index = 0; index < comics.length; index++) {
          expect(
            await File('${comics[index].baseDir}/1.png').readAsBytes(),
            pages[index],
          );
          expect(
            LocalManager().find(comics[index].id, ComicType.local),
            missingComicIds.contains(comics[index].id) ? isNull : isNotNull,
          );
        }
      }

      void expectEpub(_SavedFile output, int comicIndex) {
        final archive = ZipDecoder().decodeBytes(output.bytes, verify: true);
        expect(
          utf8.decode(archive.findFile('mimetype')!.content),
          'application/epub+zip',
        );
        final metadata = XmlDocument.parse(
          utf8.decode(archive.findFile('content.opf')!.content),
        );
        expect(
          metadata.findAllElements('dc:title').single.innerText,
          comics[comicIndex].title,
        );
        expect(
          metadata.findAllElements('dc:creator').single.innerText,
          comics[comicIndex].subtitle,
        );
        for (final item in metadata.findAllElements('item')) {
          expect(archive.findFile(item.getAttribute('href')!), isNotNull);
        }
        expect(metadata.findAllElements('itemref').length, 1);
        expect(
          archive.findFile('OEBPS/images/cover.png')!.content,
          pages[comicIndex],
        );
        expect(
          archive.findFile('OEBPS/images/img0.png')!.content,
          pages[comicIndex],
        );
        final chapter = XmlDocument.parse(
          utf8.decode(archive.findFile('OEBPS/0.html')!.content),
        );
        expect(
          chapter.findAllElements('img').single.getAttribute('src'),
          'images/img0.png',
        );
      }

      test(
        'same-named comics save sequentially with expected names and real EPUB contents',
        () async {
          final firstSave = Completer<Object?>();
          respond = (index) async => index == 0
              ? await firstSave.future
              : 'file:///documents/second.epub';
          final task = start();
          try {
            await _until(() => saved.length == 1);
            expect(task.status, ExportTaskStatus.running);
            expect(task.done, 0);
            expect(File(saved.single.path).existsSync(), isTrue);
          } finally {
            firstSave.complete('file:///documents/first.epub');
          }
          await settled(task);
          expect(task.status, ExportTaskStatus.completed);
          expect(task.done, 2);
          expect(task.failedCount, 0);
          expect(saved.map((output) => output.name), expectedNames);
          expectEpub(saved[0], 0);
          expectEpub(saved[1], 1);
          expect(
            saved.every((output) => !File(output.path).existsSync()),
            isTrue,
          );
        },
      );

      test(
        'the second save remains selecting after the first save delay expires',
        () async {
          final secondSave = Completer<Object?>();
          respond = (index) async => index == 0
              ? 'file:///documents/first.epub'
              : await secondSave.future;
          final task = start();
          try {
            await _until(() => saved.length == 2);
            expect(task.status, ExportTaskStatus.running);
            expect(task.done, 1);
            expect(IO.isSelectingFiles, isTrue);
            await Future<void>.delayed(const Duration(milliseconds: 175));
            expect(IO.isSelectingFiles, isTrue);
            expect(task.status, ExportTaskStatus.running);
            expect(File(saved.last.path).existsSync(), isTrue);
          } finally {
            secondSave.complete('file:///documents/second.epub');
          }
          await settled(task);
          expect(task.status, ExportTaskStatus.completed);
          expect(saved.map((output) => output.name), expectedNames);
          expectEpub(saved[0], 0);
          expectEpub(saved[1], 1);
        },
      );

      test(
        'canceling the first save stops the queue without marking an export done',
        () async {
          respond = (_) async => null;
          final task = start();
          await settled(task);
          expect(task.status, ExportTaskStatus.canceled);
          expect(task.doneKeys, isEmpty);
          expect(task.failedCount, 0);
          expect(saved, hasLength(1));
          expectEpub(saved.single, 0);
        },
      );

      for (final merged in [false, true]) {
        test(
          'canceling during the final save remains canceled (merged: $merged)',
          () async {
            final finalSave = Completer<Object?>();
            final saveCount = merged ? 1 : comics.length;
            respond = (index) async => index == saveCount - 1
                ? await finalSave.future
                : 'file:///documents/first.epub';
            final task = manager.startExport(
              folderPath: '',
              format: merged ? ExportFormat.veneraComics : ExportFormat.epub,
              comics: comics,
              merged: merged,
              saveWithDialog: true,
            )!;
            try {
              await _until(() => saved.length == saveCount);
              expect(task.status, ExportTaskStatus.running);
              manager.cancel(task.id);
            } finally {
              finalSave.complete('file:///documents/saved');
            }
            await settled(task);
            expect(task.status, ExportTaskStatus.canceled);
            expect(task.failedCount, 0);
            expect(task.done, comics.length);
            expect(saved, hasLength(saveCount));
            expect(
              saved.every((output) => !File(output.path).existsSync()),
              isTrue,
            );
          },
        );
      }

      test(
        'a failed first save stops the queue and does not count as exported',
        () async {
          respond = (_) async => throw PlatformException(
            code: 'WRITE_DENIED',
            message: 'Target cannot be written',
          );
          final task = start();
          await settled(task);
          expect(task.status, ExportTaskStatus.failed);
          expect(task.doneKeys, isEmpty);
          expect(task.failedCount, 1);
          expect(task.error, contains('WRITE_DENIED'));
          expect(saved, hasLength(1));
        },
      );

      test(
        'a later save failure preserves prior success but cannot complete the task',
        () async {
          respond = (index) async {
            if (index == 0) return 'file:///documents/first.epub';
            throw PlatformException(code: 'WRITE_DENIED');
          };
          final task = start();
          await settled(task);
          expect(task.status, ExportTaskStatus.failed);
          expect(task.doneKeys, {'${comics[0].id}_${ComicType.local.value}'});
          expect(task.failedCount, 1);
          expect(task.error, contains('WRITE_DENIED'));
          expect(saved, hasLength(2));
        },
      );

      test(
        'a comic removed before its turn fails instead of reporting all exported',
        () async {
          respond = (index) async {
            if (index == 0) LocalManager().removeComic(comics[1]);
            return 'file:///documents/first.epub';
          };
          final task = start();
          try {
            await settled(task, missingComicIds: {comics[1].id});
            expect(task.status, ExportTaskStatus.failed);
            expect(task.doneKeys, {'${comics[0].id}_${ComicType.local.value}'});
            expect(task.failedCount, 1);
            expect(saved, hasLength(1));
            expectEpub(saved.single, 0);
          } finally {
            await LocalManager().add(comics[1]);
          }
        },
      );

      test(
        'an immediate resume from the paused notification starts after cleanup',
        () async {
          var resumed = false;
          bool? cacheExistedAtPause;
          void resumeOnPause() {
            final paused = manager.currentTasks
                .where((candidate) => candidate.isPaused)
                .firstOrNull;
            if (paused == null || resumed) return;
            resumed = true;
            cacheExistedAtPause = Directory(
              '${App.cachePath}/export_task/${paused.id}',
            ).existsSync();
            manager.resume(paused.id);
          }

          respond = (index) async {
            if (index == 0) manager.pause(manager.currentTasks.single.id);
            return 'file:///documents/saved_$index.epub';
          };
          manager.addListener(resumeOnPause);
          try {
            final task = start();
            await settled(task);
            expect(resumed, isTrue);
            expect(cacheExistedAtPause, isFalse);
            expect(task.status, ExportTaskStatus.completed);
            expect(task.done, 2);
            expect(task.failedCount, 0);
            expect(
              manager.historyTasks.where((entry) => entry.id == task.id),
              hasLength(1),
            );
            expect(saved.map((output) => output.name), expectedNames);
            expectEpub(saved[0], 0);
            expectEpub(saved[1], 1);
          } finally {
            manager.removeListener(resumeOnPause);
          }
        },
      );

      test(
        'a serialized paused task keeps dialog mode and resumes only the unsaved comic',
        () async {
          respond = (index) async {
            if (index == 0) manager.pause(manager.currentTasks.single.id);
            return 'file:///documents/saved_$index.epub';
          };
          final task = start();
          await _until(() => task.isPaused);
          await _until(
            () => !Directory(
              '${App.cachePath}/export_task/${task.id}',
            ).existsSync(),
          );
          expect(saved, hasLength(1));
          expect(task.done, 1);
          final record =
              (appdata.implicitData['export_task_current'] as List).single;
          final restored = ExportTask.fromJson(
            Map<String, dynamic>.from(jsonDecode(jsonEncode(record)) as Map),
          );
          expect(restored.saveWithDialog, isTrue);
          expect(restored.folderPath, isEmpty);
          expect(restored.isPaused, isTrue);
          expect(restored.doneKeys, task.doneKeys);
          manager.currentTasks
            ..clear()
            ..add(restored);
          manager.resume(restored.id);
          await settled(restored);
          expect(restored.status, ExportTaskStatus.completed);
          expect(restored.done, 2);
          expect(saved.map((output) => output.name), expectedNames);
          expectEpub(saved[0], 0);
          expectEpub(saved[1], 1);
        },
      );
    },
  );
}

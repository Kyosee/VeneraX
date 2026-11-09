import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/venera_comics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory cache;
  late String previousDataPath;
  late String previousCachePath;
  late TargetPlatform? previousTarget;
  var fixtureNumber = 0;
  final pages = <Uint8List>[];

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('venera-comics-export-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    App.dataPath = root.path;
    App.cachePath = root.path;
    await appdata.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    for (final color in [
      const ui.Color(0xff123456),
      const ui.Color(0xffabcdef),
    ]) {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(2, 3);
      try {
        pages.add(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
      } finally {
        image.dispose();
        picture.dispose();
      }
    }
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    LocalManager().close();
    JsEngine().dispose();
    await root.delete(recursive: true);
    App.dataPath = previousDataPath;
    App.cachePath = previousCachePath;
    debugDefaultTargetPlatformOverride = previousTarget;
  });

  setUp(() async {
    cache = await Directory(root.path).createTemp('cache-');
    App.cachePath = cache.path;
  });

  Future<LocalComic> fixture({bool chapters = false}) async {
    final id = 'export_${fixtureNumber++}';
    final directory = await Directory('${root.path}/$id').create();
    final pageDirectory = chapters
        ? await Directory('${directory.path}/chapter_1').create()
        : directory;
    for (var page = 0; page < pages.length; page++) {
      await File(
        '${pageDirectory.path}/${page + 1}.png',
      ).writeAsBytes(pages[page]);
    }
    if (!chapters) {
      await File('${directory.path}/cover.png').writeAsBytes(pages.first);
    }
    return LocalComic(
      id: id,
      title: '本地漫画 $id',
      subtitle: 'Fixture author',
      tags: const ['含,逗号', 'unicode-漫画'],
      directory: directory.path,
      chapters: chapters ? const ComicChapters({'chapter_1': '第一章'}) : null,
      cover: chapters ? 'chapter_1/1.png' : 'cover.png',
      comicType: ComicType.local,
      downloadedChapters: chapters ? const ['chapter_1'] : const [],
      createdAt: DateTime.utc(2026),
    );
  }

  Future<Archive> readArchive(File file) async =>
      ZipDecoder().decodeBytes(await file.readAsBytes(), verify: true);

  Future<File> unsafeArchive({
    required String id,
    required String cover,
    required String comicPath,
    required String imagePath,
  }) async {
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'manifest.json',
          jsonEncode({
            'version': 1,
            'exportedAt': 0,
            'comics': [
              {
                'id': id,
                'comicType': 0,
                'title': 'Unsafe fixture',
                'hasImages': true,
              },
            ],
          }),
        ),
      )
      ..addFile(
        ArchiveFile.string(
          '$comicPath/meta.json',
          jsonEncode({
            'id': id,
            'title': 'Unsafe fixture',
            'subtitle': '',
            'tags': <String>[],
            'chapters': null,
            'cover': cover,
            'comicType': 0,
            'downloadedChapters': <String>[],
            'createdAt': 0,
          }),
        ),
      )
      ..addFile(ArchiveFile.string('comics/placeholder.txt', 'fixture'))
      ..addFile(ArchiveFile(imagePath, pages.last.length, pages.last));
    final file = File('${cache.path}/unsafe.venera_comics');
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file;
  }

  Future<void> expectRejectedWithoutChanges(
    File archive,
    String id,
    File sentinel,
  ) async {
    final previous = await sentinel.readAsBytes();
    final count = LocalManager().count;
    Object? failure;
    try {
      await importVeneraComics(archive);
    } catch (error) {
      failure = error;
    }
    expect(
      {
        'rejected': failure != null,
        'outsideLibraryUnchanged': listEquals(
          await sentinel.readAsBytes(),
          previous,
        ),
        'comicCount': LocalManager().count,
        'registered': LocalManager().find(id, ComicType.local) != null,
      },
      {
        'rejected': true,
        'outsideLibraryUnchanged': true,
        'comicCount': count,
        'registered': false,
      },
    );
  }

  Future<void> expectRestoredPages(LocalComic original, File archive) async {
    expect(await importVeneraComics(archive), 1);
    final restored = LocalManager().find(original.id, ComicType.local)!;
    expect(restored.title, original.title);
    expect(restored.tags, original.tags);
    expect(restored.cover, original.cover);
    expect(await restored.coverFile.readAsBytes(), pages.first);
    final paths = await LocalManager().getImages(
      restored.id,
      ComicType.local,
      1,
    );
    expect(paths, hasLength(2));
    for (var index = 0; index < paths.length; index++) {
      expect(
        await File(paths[index].substring('file://'.length)).readAsBytes(),
        pages[index],
      );
    }
  }

  test('nested chapter cover and pages survive export and import', () async {
    final comic = await fixture(chapters: true);
    final file = await exportVeneraComics([comic]);
    final archive = await readArchive(file);
    final prefix = 'comics/${comic.id}_0/chapter_1';
    for (var index = 0; index < pages.length; index++) {
      expect(
        archive.findFile('$prefix/${index + 1}.png')!.content,
        pages[index],
      );
    }
    await expectRestoredPages(comic, file);
  });

  test(
    'chapterless root pages survive without replacing generated metadata',
    () async {
      final comic = await fixture();
      await File(
        '${comic.baseDir}/meta.json',
      ).writeAsString('unrelated metadata');
      await File(
        '${comic.baseDir}/manifest.json',
      ).writeAsString('unrelated manifest');
      final file = await exportVeneraComics([comic]);
      final archive = await readArchive(file);
      final prefix = 'comics/${comic.id}_0';
      for (var index = 0; index < pages.length; index++) {
        expect(
          archive.findFile('$prefix/${index + 1}.png')?.content,
          pages[index],
        );
      }
      final meta = jsonDecode(
        utf8.decode(archive.findFile('$prefix/meta.json')!.content),
      );
      expect(meta['title'], comic.title);
      expect(archive.findFile('$prefix/manifest.json'), isNull);
      final manifest = await readVeneraComicsManifest(file);
      expect(manifest.comics.single.hasImages, isTrue);
      await expectRestoredPages(comic, file);
    },
  );

  test('metadata-only export includes cover but excludes root pages', () async {
    final comic = await fixture();
    final file = await exportVeneraComics([comic], includeImages: false);
    final archive = await readArchive(file);
    final prefix = 'comics/${comic.id}_0';
    expect(archive.findFile('$prefix/cover.png')!.content, pages.first);
    expect(archive.findFile('$prefix/1.png'), isNull);
    expect(archive.findFile('$prefix/2.png'), isNull);
    expect(
      (await readVeneraComicsManifest(file)).comics.single.hasImages,
      isFalse,
    );
  });

  test(
    'rejects a parent-traversing cover before changing files or records',
    () async {
      const id = 'unsafe_cover';
      final sentinel = File('${root.path}/escape.png');
      await sentinel.writeAsBytes(pages.first);
      final file = await unsafeArchive(
        id: id,
        cover: '../../escape.png',
        comicPath: 'comics/${id}_0',
        imagePath: 'escape.png',
      );
      await expectRejectedWithoutChanges(file, id, sentinel);
    },
  );

  test(
    'rejects a parent-traversing manifest id before changing files or records',
    () async {
      const id = '../escaped_comic';
      final directory = await Directory(
        '${root.path}/escaped_comic_0',
      ).create();
      final sentinel = File('${directory.path}/cover.png');
      await sentinel.writeAsBytes(pages.first);
      final file = await unsafeArchive(
        id: id,
        cover: 'cover.png',
        comicPath: 'escaped_comic_0',
        imagePath: 'escaped_comic_0/cover.png',
      );
      await expectRejectedWithoutChanges(file, id, sentinel);
    },
  );

  test(
    'native ZIP read failure closes and removes the incomplete archive',
    () async {
      final comic = await fixture();
      final kernel = DynamicLibrary.open('kernel32.dll');
      final openFile = kernel
          .lookupFunction<
            IntPtr Function(
              Pointer<Utf16>,
              Uint32,
              Uint32,
              Pointer<Void>,
              Uint32,
              Uint32,
              IntPtr,
            ),
            int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
          >('CreateFileW');
      final closeHandle = kernel
          .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
            'CloseHandle',
          );
      var handle = -1;
      try {
        await expectLater(
          exportVeneraComics(
            [comic],
            onPhase: (phase, _) {
              if (phase != ExportPhase.packaging) return;
              final staged = cache.listSync().whereType<Directory>().single;
              final path = '${staged.path}/manifest.json'.toNativeUtf16();
              try {
                // Deny native reads, while allowing staging cleanup to delete it.
                handle = openFile(path, 0x80000000, 4, nullptr, 3, 0, 0);
                expect(handle, isNot(-1));
              } finally {
                calloc.free(path);
              }
            },
          ),
          throwsA(
            predicate<Object>(
              (error) => error.toString().contains('Failed to write content'),
            ),
          ),
        );
      } finally {
        if (handle != -1) closeHandle(handle);
      }
      expect(
        cache.listSync(),
        isEmpty,
        reason: 'No staging tree or partial ZIP remains.',
      );
      expect(await comic.coverFile.readAsBytes(), pages.first);
      final retry = await exportVeneraComics([comic]);
      expect((await readArchive(retry)).findFile('manifest.json'), isNotNull);
    },
    skip: !Platform.isWindows,
  );
}

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart' show ZipDecoder;
import 'package:flutter/foundation.dart';
import 'package:flutter_saf/flutter_saf.dart' show AndroidFile;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart' show overrideIO;
import 'package:zip_flutter/zip_flutter.dart';

import 'fixtures/avif_page.dart';

class _SafArchive extends Fake implements AndroidFile {
  _SafArchive(this.path, this.contents);

  @override
  final String path;
  final File contents;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      contents.open(mode: mode);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late String previousDataPath;
  late String previousCachePath;
  late TargetPlatform? previousTarget;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('cbz-round-trip-');
    previousDataPath = App.dataPath;
    previousCachePath = App.cachePath;
    previousTarget = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    App.dataPath = root.path;
    App.cachePath = (await Directory('${root.path}/cache').create()).path;
    await appdata.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
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

  test('imports SAF archives and clears their cache', () async {
    final pages = await Directory('${root.path}/saf-pages').create();
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=',
    );
    await File('${pages.path}/1.png').writeAsBytes(image);
    final archive = File('${root.path}/backing-file');
    await ZipFile.compressFolderAsync(pages.path, archive.path, 4);
    for (final name in ['first.CBZ', 'second.ZIP']) {
      final safFile = _SafArchive('/saf/$name', archive);
      final comic = (await CBZ.importAll(safFile)).single;
      expect(comic.title, name.split('.').first);
      final paths = await LocalManager().getImagesForComic(comic, 1);
      final page = File(paths.single.substring('file://'.length));
      expect(await page.readAsBytes(), image);
    }
    await archive.writeAsString('invalid archive');
    await expectLater(
      CBZ.importAll(_SafArchive('/saf/broken.cbz', archive)),
      throwsA(isA<Exception>()),
    );
    expect(Directory(App.cachePath).listSync(), isEmpty);
  });

  test('imports a CBZ containing only an AVIF page and a cover', () async {
    final input = await Directory('${root.path}/avif-pages').create();
    final image = avifPageBytes();
    await File('${input.path}/001.AVIF').writeAsBytes(image);
    await File('${input.path}/cover.Avif').writeAsBytes(image);
    final archive = File('${root.path}/avif-book.cbz');
    await ZipFile.compressFolderAsync(input.path, archive.path, 4);
    final comic = (await CBZ.importAll(archive)).single;
    expect(await comic.coverFile.readAsBytes(), image);
    final pages = await LocalManager().getImagesForComic(comic, 1);
    final saved = File(pages.single.substring('file://'.length));
    expect(await saved.readAsBytes(), image);
  });

  test('CBZ preserves every page in unequal length chapters', () async {
    final folder = await Directory('${root.path}/original').create();
    final expected = <List<Uint8List>>[];
    for (var chapter = 0; chapter < 2; chapter++) {
      final chapterDirectory = await Directory(
        '${folder.path}/chapter_$chapter',
      ).create();
      final pages = <Uint8List>[];
      for (var page = 0; page < chapter + 2; page++) {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder).drawColor(
          ui.Color(0xff000000 | ((chapter * 3 + page + 1) * 0x223344)),
          ui.BlendMode.src,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(3, 4);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
          pages.add(bytes);
          await File(
            '${chapterDirectory.path}/${page + 1}.png',
          ).writeAsBytes(bytes);
        } finally {
          image.dispose();
          picture.dispose();
        }
      }
      expected.add(pages);
    }
    final comic = LocalComic(
      id: 'chapter-export',
      title: 'Chapter export fixture',
      subtitle: 'Generated fixture',
      tags: const ['test'],
      directory: folder.path,
      chapters: const ComicChapters({
        'chapter_0': 'First chapter',
        'chapter_1': 'Second chapter',
      }),
      cover: 'chapter_0/1.png',
      comicType: ComicType.local,
      downloadedChapters: const ['chapter_0', 'chapter_1'],
      createdAt: DateTime.utc(2026),
    );
    await LocalManager().add(comic);
    final exported = await overrideIO(
      () => CBZ.export(comic, '${root.path}/chapters.cbz'),
    );
    final archive = ZipDecoder().decodeBytes(await exported.readAsBytes());
    final metadata =
        jsonDecode(utf8.decode(archive.findFile('metadata.json')!.content))
            as Map<String, dynamic>;
    expect(metadata['chapters'], [
      {'title': 'First chapter', 'start': 1, 'end': 2},
      {'title': 'Second chapter', 'start': 3, 'end': 5},
    ]);
    LocalManager().remove(comic.id, comic.comicType);
    final imported = (await CBZ.importAll(exported)).single;
    expect(imported.chapters!.allChapters.values, [
      'First chapter',
      'Second chapter',
    ]);
    for (var chapter = 0; chapter < expected.length; chapter++) {
      final paths = await LocalManager().getImagesForComic(
        imported,
        chapter + 1,
      );
      expect(paths, hasLength(expected[chapter].length));
      for (var page = 0; page < paths.length; page++) {
        expect(
          await File(paths[page].substring('file://'.length)).readAsBytes(),
          expected[chapter][page],
          reason: 'chapter ${chapter + 1}, page ${page + 1}',
        );
      }
    }
    // Older exports counted chapters instead of pages in the later ranges.
    metadata['chapters'] = [
      {'title': 'First chapter', 'start': 1, 'end': 2},
      {'title': 'Second chapter', 'start': 2, 'end': 4},
    ];
    final legacyDirectory = await Directory('${root.path}/legacy').create();
    for (final entry in archive) {
      if (entry.isFile && entry.name != 'metadata.json') {
        await File(
          '${legacyDirectory.path}/${entry.name}',
        ).writeAsBytes(entry.content);
      }
    }
    await File(
      '${legacyDirectory.path}/metadata.json',
    ).writeAsString(jsonEncode(metadata));
    final legacyFile = File('${root.path}/legacy.cbz');
    await ZipFile.compressFolderAsync(legacyDirectory.path, legacyFile.path, 4);
    final legacy = (await CBZ.importAll(legacyFile)).single;
    expect(
      legacy.chapters,
      isNull,
      reason: 'Invalid ranges must use flat pages',
    );
    final legacyPages = await LocalManager().getImagesForComic(legacy, 1);
    final allExpected = expected.expand((chapter) => chapter).toList();
    expect(legacyPages, hasLength(allExpected.length));
    for (var page = 0; page < legacyPages.length; page++) {
      expect(
        await File(legacyPages[page].substring('file://'.length)).readAsBytes(),
        allExpected[page],
        reason: 'Legacy page ${page + 1} must not be lost or duplicated',
      );
    }
    expect(Directory(App.cachePath).listSync(), isEmpty);
  });
}

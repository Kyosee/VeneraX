import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_cover_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/export_tasks.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/venera_comics.dart';

final class _SafIO extends IOOverrides {
  _SafIO(this.safRoot, this.storageRoot);

  final String safRoot;
  final String storageRoot;

  String _resolve(String path) {
    if (!path.startsWith('android:')) return path;
    if (path == safRoot) return storageRoot;
    if (!path.startsWith('$safRoot/') && !path.startsWith('$safRoot\\')) {
      throw StateError('SAF root was changed: $path');
    }
    return p.join(storageRoot, path.substring(safRoot.length + 1));
  }

  @override
  File createFile(String path) => super.createFile(_resolve(path));

  @override
  Directory createDirectory(String path) =>
      super.createDirectory(_resolve(path));
}

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
    await TranslationStore().init();
    await AppTranslation.init();
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
    TranslationStore().close();
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

  Future<LocalComic> fixture({
    bool chapters = false,
    String? virtualDirectory,
    ComicType comicType = ComicType.local,
  }) async {
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
      directory: virtualDirectory ?? directory.path,
      chapters: chapters ? const ComicChapters({'chapter_1': '第一章'}) : null,
      cover: chapters ? 'chapter_1/1.png' : 'cover.png',
      comicType: comicType,
      downloadedChapters: chapters ? const ['chapter_1'] : const [],
      createdAt: DateTime.utc(2026),
    );
  }

  Future<Archive> readArchive(File file) async =>
      ZipDecoder().decodeBytes(await file.readAsBytes(), verify: true);

  test('selected books carry only their custom cover, separately from page images', () async {
    final comic = await fixture();
    final other = await fixture();
    const ref = 'collection://selected.png';
    final file = ComicCoverStore.fileFor(ref)!;
    await file.parent.create(recursive: true);
    await file.writeAsBytes(pages.last);
    appdata.settings[ComicCoverStore.settingsKey] = {
      'local': {comic.id: ref, other.id: 'collection://unselected.png'},
    };
    addTearDown(() => appdata.settings[ComicCoverStore.settingsKey] = {});
    final archive = await exportVeneraComics([comic], includeImages: false, includeTranslations: false);
    final zip = await readArchive(archive);
    expect(zip.findFile('collection_covers/selected.png')!.content, pages.last);
    expect(zip.findFile('collection_covers/unselected.png'), isNull);
    appdata.settings[ComicCoverStore.settingsKey] = {};
    await file.delete();
    await importVeneraComics(archive, importTranslations: false, importCustomCovers: false);
    expect(ComicCoverStore.reference('local', comic.id), isNull);
    await importVeneraComics(archive, importTranslations: false);
    expect(await file.readAsBytes(), pages.last);
    expect(ComicCoverStore.reference('local', comic.id), ref);
  });

  String addTranslation(LocalComic comic, {String sourceKey = 'local'}) {
    final chapter = TranslationChapterIdentity(
      scopePrefix: 'pageTranslation@2@auto>zh@$sourceKey@${comic.id}@0@',
      sourceKey: sourceKey,
      comicId: comic.id,
      chapterId: '0',
      sourceLang: 'auto',
      targetLang: 'zh',
      comicTitle: comic.title,
    );
    final key = '${chapter.scopePrefix}p1@';
    TranslationStore().put(key, [
      TranslatedRegion(
        rect: IntRect(0, 0, 2, 3),
        text: 'Translated ${comic.id}',
        backgroundColor: 0xFFFFFFFF,
        textColor: 0xFF000000,
      ),
    ], chapter: chapter);
    TranslationStore().recordChapterPageCount(sourceKey, comic.id, '0', 2);
    return key;
  }

  Archive attachment(Archive archive) => ZipDecoder().decodeBytes(
    archive.findFile('translations.venera')!.content,
    verify: true,
  );

  Database attachedStore(Archive archive) {
    final file = File('${cache.path}/attachment-${fixtureNumber++}.db');
    file.writeAsBytesSync(
      attachment(archive).findFile('image_translation.db')!.content,
    );
    final db = sqlite3.open(file.path);
    addTearDown(db.dispose);
    return db;
  }

  Future<void> useEmptyTranslationStore() async {
    final previousPath = App.dataPath;
    TranslationStore().close();
    App.dataPath = (await Directory('${cache.path}/recipient').create()).path;
    await TranslationStore().init();
    addTearDown(() async {
      TranslationStore().close();
      App.dataPath = previousPath;
      await TranslationStore().init();
    });
  }

  Future<void> finishExport(ExportTask task) async {
    final manager = ExportTaskManager.instance;
    final finished = Completer<void>();
    void changed() {
      if (!task.isActive &&
          !manager.currentTasks.contains(task) &&
          !finished.isCompleted) {
        finished.complete();
      }
    }

    manager.addListener(changed);
    try {
      changed();
      await finished.future.timeout(const Duration(seconds: 20));
    } finally {
      manager.removeListener(changed);
    }
    expect(task.status, ExportTaskStatus.completed, reason: task.error);
    await appdata.saveData(false);
  }

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

  test(
    'untranslated selections do not attach unrelated translations',
    () async {
      final selected = await fixture();
      final other = await fixture();
      addTranslation(other);
      expect(translationComicsForExport([selected]), isEmpty);

      final archive = await readArchive(await exportVeneraComics([selected]));
      expect(archive.findFile('translations.venera'), isNull);
    },
  );

  test(
    'translation export opt-out leaves the v1 comic and original images',
    () async {
      final comic = await fixture();
      addTranslation(comic);
      final file = await exportVeneraComics([
        comic,
      ], includeTranslations: false);
      final archive = await readArchive(file);
      expect(archive.findFile('translations.venera'), isNull);
      expect((await readVeneraComicsManifest(file)).version, 1);
      await expectRestoredPages(comic, file);
    },
  );

  test(
    'selection uses the stored source key after a source is uninstalled',
    () async {
      const sourceKey = 'uninstalled-export-fixture';
      final comic = await fixture(comicType: ComicType.fromKey(sourceKey));
      expect(comic.sourceKey, startsWith('Unknown:'));
      final key = addTranslation(comic, sourceKey: sourceKey);
      addTranslation(comic, sourceKey: 'another-source');
      final other = await fixture(comicType: comic.comicType);
      addTranslation(other, sourceKey: sourceKey);
      final prefsKey = 'imageTranslationEnabledComics';
      final previousPrefs = appdata.implicitData[prefsKey];
      addTearDown(() {
        if (previousPrefs == null) {
          appdata.implicitData.remove(prefsKey);
        } else {
          appdata.implicitData[prefsKey] = previousPrefs;
        }
      });
      appdata.implicitData[prefsKey] = {
        '${comic.id}@$sourceKey': true,
        '${comic.id}@another-source': true,
        '${other.id}@$sourceKey': true,
      };

      expect(translationComicsForExport([comic]), [(sourceKey, comic.id)]);
      final archive = await readArchive(await exportVeneraComics([comic]));
      final db = attachedStore(archive);
      expect(db.select('select cache_key from translated_page;'), [
        {'cache_key': key},
      ]);
      expect(
        db.select(
          'select source_key, comic_id, total_pages from chapter_page_count;',
        ),
        [
          {'source_key': sourceKey, 'comic_id': comic.id, 'total_pages': 2},
        ],
      );
      final prefs = jsonDecode(
        utf8.decode(
          attachment(archive).findFile('image_translation_prefs.json')!.content,
        ),
      );
      expect(prefs[prefsKey], {'${comic.id}@$sourceKey': true});
    },
  );

  test(
    'translation attachment round-trips totals and text without changing images',
    () async {
      final comic = await fixture();
      final key = addTranslation(comic);
      final file = await exportVeneraComics([comic]);
      final archive = await readArchive(file);
      expect((await readVeneraComicsManifest(file)).version, 1);
      expect(archive.findFile('translations.venera'), isNotNull);
      for (var page = 0; page < pages.length; page++) {
        expect(
          archive.findFile('comics/${comic.id}_0/${page + 1}.png')!.content,
          pages[page],
        );
        expect(
          await File('${comic.baseDir}/${page + 1}.png').readAsBytes(),
          pages[page],
        );
      }

      await useEmptyTranslationStore();
      await expectRestoredPages(comic, file);
      expect(
        TranslationStore().get(key)!.single.text,
        'Translated ${comic.id}',
      );
      expect(TranslationStore().chapterPageCounts('local', comic.id), {'0': 2});
      expect(TranslationStore().count, 1);
    },
  );

  test(
    'metadata-only comic bundles can carry translations and total pages',
    () async {
      final comic = await fixture();
      final key = addTranslation(comic);
      final file = await exportVeneraComics([comic], includeImages: false);
      final archive = await readArchive(file);
      expect(
        (await readVeneraComicsManifest(file)).comics.single.hasImages,
        isFalse,
      );
      expect(archive.findFile('comics/${comic.id}_0/1.png'), isNull);
      expect(archive.findFile('translations.venera'), isNotNull);

      await useEmptyTranslationStore();
      expect(await importVeneraComics(file), 1);
      expect(
        TranslationStore().get(key)!.single.text,
        'Translated ${comic.id}',
      );
      expect(TranslationStore().chapterPageCounts('local', comic.id), {'0': 2});
    },
  );

  test(
    'image-pack import can explicitly ignore translation attachments',
    () async {
      final comic = await fixture();
      addTranslation(comic);
      final file = await exportVeneraComics([comic]);
      await useEmptyTranslationStore();

      expect(await importVeneraComics(file, importTranslations: false), 1);
      expect(TranslationStore().count, 0);
      expect(TranslationStore().chapterPageCounts('local', comic.id), isEmpty);
      final restored = LocalManager().find(comic.id, ComicType.local)!;
      expect(
        await File('${restored.baseDir}/1.png').readAsBytes(),
        pages.first,
      );
    },
  );

  test('old v1 bundles without translation attachments still import', () async {
    final comic = await fixture();
    final file = await exportVeneraComics([comic], includeTranslations: false);
    final archive = await readArchive(file);
    expect((await readVeneraComicsManifest(file)).version, 1);
    expect(archive.findFile('translations.venera'), isNull);
    await useEmptyTranslationStore();

    expect(await importVeneraComics(file), 1);
    expect(TranslationStore().count, 0);
    expect(TranslationStore().chapterPageCounts('local', comic.id), isEmpty);
    expect(
      await LocalManager().getImages(comic.id, ComicType.local, 1),
      hasLength(2),
    );
    expect(TranslationStore().chapterPageCounts('local', comic.id), {'0': 2});
  });

  test(
    'a normal app backup cannot masquerade as a translation attachment',
    () async {
      final comic = await fixture();
      final ordinaryBackup = Archive()
        ..addFile(
          ArchiveFile.string(
            'appdata.json',
            jsonEncode({
              'settings': {'comicDisplayMode': 'unexpected-from-backup'},
            }),
          ),
        );
      final bytes = ZipEncoder().encode(ordinaryBackup);
      final file = await exportVeneraComics(
        [comic],
        includeTranslations: false,
        onPhase: (phase, _) {
          if (phase != ExportPhase.packaging) return;
          final staged = cache.listSync().whereType<Directory>().single;
          File('${staged.path}/translations.venera').writeAsBytesSync(bytes);
        },
      );
      final displayMode = appdata.settings['comicDisplayMode'];

      await expectLater(importVeneraComics(file), throwsFormatException);
      expect(appdata.settings['comicDisplayMode'], displayMode);
    },
  );

  for (final merged in [false, true]) {
    test(
      'export task forwards translation choice when merged=$merged',
      () async {
        final comics = [await fixture(), await fixture()];
        for (final comic in comics) {
          await LocalManager().add(comic);
          addTranslation(comic);
        }
        for (final includeTranslations in [false, true]) {
          final destination = await Directory(
            '${cache.path}/output-$includeTranslations',
          ).create();
          final task = ExportTaskManager.instance.startExport(
            folderPath: destination.path,
            format: ExportFormat.veneraComics,
            comics: comics,
            merged: merged,
            includeTranslations: includeTranslations,
          )!;
          await finishExport(task);
          expect(task.includeTranslations, includeTranslations);
          final files = destination.listSync().whereType<File>().toList();
          expect(files, hasLength(merged ? 1 : 2));
          for (final file in files) {
            final archive = await readArchive(file);
            expect(
              archive.findFile('translations.venera'),
              includeTranslations ? isNotNull : isNull,
            );
            if (includeTranslations) {
              final ids = (await readVeneraComicsManifest(
                file,
              )).comics.map((comic) => comic.id).toSet();
              expect(
                attachedStore(archive)
                    .select('select comic_id from chapter_page_count;')
                    .map((row) => row['comic_id'])
                    .toSet(),
                ids,
              );
            }
          }
        }
      },
    );
  }

  test(
    'resuming a restored task preserves the disabled translation choice',
    () async {
      final comic = await fixture();
      await LocalManager().add(comic);
      addTranslation(comic);
      final destination = await Directory('${cache.path}/resumed').create();
      final task = ExportTask.fromJson(
        ExportTask(
          id: 'restored-translation-export',
          folderPath: destination.path,
          format: ExportFormat.veneraComics,
          comics: [
            ExportComicRef(id: comic.id, comicTypeValue: 0, title: comic.title),
          ],
          createdAt: DateTime.utc(2026),
          includeTranslations: false,
          merged: true,
        ).toJson(),
      );
      ExportTaskManager.instance.currentTasks.add(task);
      ExportTaskManager.instance.resume(task.id);
      await finishExport(task);

      final file = destination.listSync().whereType<File>().single;
      expect((await readArchive(file)).findFile('translations.venera'), isNull);
    },
  );

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
    'SAF source keeps its URI prefix while exporting a nested cover',
    () async {
      const safRoot = 'android://primary:Download/Comic';
      final comic = await fixture(chapters: true, virtualDirectory: safRoot);
      final file = await IOOverrides.runWithIOOverrides(
        () => exportVeneraComics([comic]),
        _SafIO(safRoot, '${root.path}/${comic.id}'),
      );
      final archive = await readArchive(file);
      final prefix = 'comics/${comic.id}_0/chapter_1';
      for (var index = 0; index < pages.length; index++) {
        expect(archive.findFile('$prefix/${index + 1}.png')!.content, pages[index]);
      }
    },
  );

  test(
    'SAF library keeps its URI prefix while importing covers and pages',
    () async {
      final comic = await fixture(chapters: true);
      final file = await exportVeneraComics([comic]);
      const safRoot = 'android://primary:Download/Library';
      final library = await Directory('${root.path}/saf_library').create();
      final previousPath = LocalManager().path;
      LocalManager().path = safRoot;
      try {
        await IOOverrides.runWithIOOverrides(
          () => expectRestoredPages(comic, file),
          _SafIO(safRoot, library.path),
        );
      } finally {
        LocalManager().path = previousPath;
      }
    },
  );

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

  final unsafeCovers = [
    '',
    '.',
    '././',
    '/escape.png',
    r'C:\escape.png',
    r'..\escape.png',
    r'\\server\escape.png',
    'cover:stream',
    'cover\u0000.png',
  ];
  for (var index = 0; index < unsafeCovers.length; index++) {
    test(
      'rejects invalid cover path case $index without changing the library',
      () async {
        final id = 'invalid_cover_$index';
        final sentinel = File('${root.path}/escape.png');
        await sentinel.writeAsBytes(pages.first);
        final file = await unsafeArchive(
          id: id,
          cover: unsafeCovers[index],
          comicPath: 'comics/${id}_0',
          imagePath: 'comics/${id}_0/cover.png',
        );
        await expectRejectedWithoutChanges(file, id, sentinel);
      },
    );
  }

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

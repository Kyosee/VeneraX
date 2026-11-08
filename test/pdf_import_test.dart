import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf_import.dart';
import 'fixtures/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory library;

  setUp(() {
    root = Directory.systemTemp.createTempSync('venera_pdf_import_');
    library = Directory(FilePath.join(root.path, 'library'))..createSync();
    LocalManager().path = library.path;
    App.cachePath = FilePath.join(root.path, 'cache');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<LocalComic> import(File file, {void Function(double)? onProgress}) =>
      importPdfComic(
        file,
        localPath: library.path,
        cachePath: root.path,
        onProgress: onProgress,
      );

  test(
    'file picker accepts uppercase PDF and routes it to the PDF importer',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final path = FilePath.join(root.path, 'comic.PDF');
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'openFile');
        if (!App.isMacOS && !App.isIOS) {
          final groups = call.arguments['acceptedTypeGroups'] as List;
          expect(groups.first['extensions'], contains('pdf'));
        }
        return [path];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final importer = _RoutingImporter();
      expect(await importer.files(), isTrue);
      expect(importer.importedPath, path);
    },
  );

  test(
    'renders PDF pages in reader order, with a cover and bounded sizes',
    () async {
      final source = File(FilePath.join(root.path, '漫画.PDF'))
        ..writeAsBytesSync(pdfFixture(pageCount: 12));
      final original = source.readAsBytesSync();
      final progress = <double>[];
      final comic = await import(source, onProgress: progress.add);

      expect(comic.title, '漫画');
      expect(comic.chapters, isNull);
      expect(comic.cover, '1.png');
      final pages = await LocalManager().getImagesForComic(comic, 1);
      expect(
        pages.map((p) => File(p.replaceFirst('file://', '')).name),
        List.generate(12, (i) => '${i + 1}.png'),
      );
      expect(progress.length, 12);
      expect(progress.last, 1);
      expect(
        comic.coverFile.readAsBytesSync(),
        File(pages.first.replaceFirst('file://', '')).readAsBytesSync(),
      );
      expect(source.readAsBytesSync(), original);

      // Red portrait, green rotated landscape, and a very large blue page.
      for (var i = 0; i < 3; i++) {
        final codec = await ui.instantiateImageCodec(
          File(pages[i].replaceFirst('file://', '')).readAsBytesSync(),
        );
        final frame = await codec.getNextFrame();
        final image = frame.image;
        try {
          expect((
            image.width,
            image.height,
          ), [(200, 400), (400, 200), (2400, 1200)][i]);
          final rgba = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final center =
              ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
          expect(
            rgba!.buffer.asUint8List(center, 4),
            [
              [255, 0, 0, 255],
              [0, 255, 0, 255],
              [0, 0, 255, 255],
            ][i],
          );
        } finally {
          image.dispose();
          codec.dispose();
        }
      }
    },
  );

  test(
    'failed conversion removes its pages without touching existing folders',
    () async {
      final source = File(FilePath.join(root.path, 'comic.pdf'))
        ..writeAsBytesSync(pdfFixture(pageCount: 2));
      final existing = Directory(FilePath.join(library.path, 'comic'))
        ..createSync();
      var rendered = 0;
      await expectLater(
        import(
          source,
          onProgress: (_) {
            rendered++;
            throw const FileSystemException('No space left on device');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(rendered, 1);
      expect(library.listSync().map((e) => e.path), [existing.path]);
      expect(existing.listSync(), isEmpty);
      expect(source.existsSync(), isTrue);

      final comic = await import(source);
      expect(comic.directory, isNot('comic'));
      expect(await LocalManager().getImagesForComic(comic, 1), hasLength(2));
    },
  );

  test(
    'rejects damaged and empty PDFs without leaving a comic directory',
    () async {
      final source = File(FilePath.join(root.path, 'invalid.pdf'));
      for (final bytes in [
        utf8.encode('not a PDF'),
        pdfFixture(pageCount: 0),
      ]) {
        source.writeAsBytesSync(bytes);
        await expectLater(import(source), throwsA(anything));
        expect(library.listSync(), isEmpty);
        expect(source.readAsBytesSync(), bytes);
      }
    },
  );
}

class _RoutingImporter extends ImportComic {
  String? importedPath;

  @override
  Future<bool> pdfFile(File file) async {
    importedPath = file.path;
    return true;
  }

  @override
  Future<bool> cbzFile(File file) =>
      throw StateError('PDF routed to archive importer');
}

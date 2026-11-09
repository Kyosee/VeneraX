import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory comicDirectory;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera-pdf-export-');
    comicDirectory = await Directory('${root.path}/comic').create();
    LocalManager().path = root.path;
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  LocalComic comic({bool hasChapter = false}) => LocalComic(
    id: 'pdf-export-test',
    title: 'PDF export test',
    subtitle: 'Fixture author',
    tags: const [],
    directory: comicDirectory.path,
    chapters: hasChapter ? const ComicChapters({'one': 'Chapter 1'}) : null,
    cover: 'cover.png',
    comicType: ComicType.local,
    downloadedChapters: hasChapter ? const ['one'] : const [],
    createdAt: DateTime.utc(2026),
  );

  Future<void> writePng(File file, ui.Color color) async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(color, ui.BlendMode.src);
    final picture = recorder.endRecording();
    final image = await picture.toImage(2, 3);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
      picture.dispose();
    }
  }

  test('missing cover fails instead of leaving PDF export pending', () async {
    await expectLater(
      createPdfFromComicIsolate(
        comic(),
        '${root.path}/missing.pdf',
      ).timeout(const Duration(seconds: 3)),
      throwsA(
        allOf(
          isNot(isA<TimeoutException>()),
          predicate<Object>((error) => error.toString().contains('cover.png')),
        ),
      ),
    );
  });

  test(
    'corrupt image decoding fails instead of leaving the worker waiting',
    () async {
      await File('${comicDirectory.path}/cover.png').writeAsBytes([1, 2, 3]);
      await expectLater(
        createPdfFromComicIsolate(
          comic(),
          '${root.path}/corrupt.pdf',
        ).timeout(const Duration(seconds: 3)),
        throwsA(
          allOf(
            isNot(isA<TimeoutException>()),
            predicate<Object>(
              (error) => error.toString().toLowerCase().contains('image'),
            ),
          ),
        ),
      );
    },
  );

  test(
    'an unwritable output reports the file error and releases the worker',
    () async {
      await writePng(
        File('${comicDirectory.path}/cover.png'),
        const ui.Color(0xff123456),
      );
      await expectLater(
        createPdfFromComicIsolate(
          comic(),
          root.path,
        ).timeout(const Duration(seconds: 3)),
        throwsA(
          allOf(
            isNot(isA<TimeoutException>()),
            predicate<Object>((error) => error.toString().contains(root.path)),
          ),
        ),
      );
    },
  );

  test(
    'real image decoding still produces complete PDF pages and pixels',
    () async {
      await writePng(
        File('${comicDirectory.path}/cover.png'),
        const ui.Color(0xff123456),
      );
      final chapter = await Directory('${comicDirectory.path}/one').create();
      await writePng(File('${chapter.path}/1.png'), const ui.Color(0xffabcdef));

      final file = await createPdfFromComicIsolate(
        comic(hasChapter: true),
        '${root.path}/complete.pdf',
      ).timeout(const Duration(seconds: 5));
      final bytes = await file.readAsBytes();
      final content = latin1.decode(bytes);
      expect(content, startsWith('%PDF-1.7'));
      expect(content, endsWith('%%EOF\n'));
      expect(content, contains('/Count 2\n'));
      final images = RegExp(
        r'/Subtype /Image\n/Width 2\n/Height 3\n'
        r'/ColorSpace /DeviceRGB\n/BitsPerComponent 8\n'
        r'/Filter /FlateDecode\n/Length (\d+)\n>>\nstream\n',
      ).allMatches(content).toList();
      expect(images, hasLength(2));
      for (var index = 0; index < images.length; index++) {
        final match = images[index];
        final length = int.parse(match.group(1)!);
        final pixels = ZLibDecoder().convert(
          bytes.sublist(match.end, match.end + length),
        );
        final rgb = index == 0 ? [0x12, 0x34, 0x56] : [0xab, 0xcd, 0xef];
        expect(pixels, [for (var pixel = 0; pixel < 6; pixel++) ...rgb]);
      }
      final xrefOffset = int.parse(
        RegExp(r'startxref\n(\d+)\n%%EOF').firstMatch(content)!.group(1)!,
      );
      expect(content.substring(xrefOffset), startsWith('xref\n'));
    },
  );
}

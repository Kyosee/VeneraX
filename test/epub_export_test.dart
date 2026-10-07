import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/epub.dart';
import 'package:xml/xml.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File page;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venera-epub-test-');
    page = File('${directory.path}/page.png');
    await page.writeAsBytes(List.generate(65536, (i) => i % 251));
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<Archive> export({
    String title = 'Comic',
    String chapter = 'Chapter',
  }) async {
    final file = await createEpubComic(
      EpubData(
        title: title,
        author: title,
        cover: page,
        chapters: [
          for (var i = 0; i < 12; i++)
            EpubChapter('$chapter $i', [page, page, page]),
        ],
      ),
      '${directory.path}/book.epub',
    );
    return ZipDecoder().decodeBytes(await file.readAsBytes(), verify: true);
  }

  XmlDocument xml(Archive archive, String path) =>
      XmlDocument.parse(utf8.decode(archive.findFile(path)!.content));

  test(
    'every chapter and image reference resolves, including the last page',
    () async {
      final archive = await export();
      final opf = xml(archive, 'content.opf');
      expect(opf.findAllElements('itemref').length, 12);
      for (final item in opf.findAllElements('item')) {
        final href = item.getAttribute('href')!;
        expect(archive.findFile(href), isNotNull, reason: href);
      }
      for (var i = 0; i < 12; i++) {
        final chapter = xml(archive, 'OEBPS/$i.html');
        final images = chapter.findAllElements('img');
        expect(images.length, 3);
        for (final image in images) {
          final path = 'OEBPS/${image.getAttribute('src')}';
          expect(archive.findFile(path)!.content, await page.readAsBytes());
        }
      }
      expect(
        archive.findFile('OEBPS/images/img35.png')!.content,
        await page.readAsBytes(),
      );
    },
  );

  test('titles and chapter names remain valid XML', () async {
    const title = '漫画 & <作者> "测试"';
    final archive = await export(title: title, chapter: title);
    expect(
      xml(archive, 'content.opf').findAllElements('dc:title').single.innerText,
      title,
    );
    expect(xml(archive, 'toc.ncx').findAllElements('navPoint').length, 12);
    expect(
      xml(archive, 'OEBPS/11.html').findAllElements('h1').single.innerText,
      '$title 11',
    );
  });

  test(
    'mimetype is the first ZIP entry and is stored without extra fields',
    () async {
      await export();
      final bytes = await File('${directory.path}/book.epub').readAsBytes();
      final header = ByteData.sublistView(bytes);
      expect(header.getUint32(0, Endian.little), 0x04034b50);
      expect(header.getUint16(8, Endian.little), 0);
      expect(header.getUint16(28, Endian.little), 0);
      final nameLength = header.getUint16(26, Endian.little);
      expect(utf8.decode(bytes.sublist(30, 30 + nameLength)), 'mimetype');
      expect(
        utf8.decode(bytes.sublist(30 + nameLength, 58)),
        'application/epub+zip',
      );
    },
  );

  test('later pages survive a SAF-style empty bulk read', () async {
    final laterPage = _BulkReadFailureFile(page);
    final file = await createEpubComic(
      EpubData(
        title: 'Comic',
        author: 'Author',
        cover: page,
        chapters: [
          EpubChapter('First', [page]),
          EpubChapter('Later', [laterPage]),
        ],
      ),
      '${directory.path}/bulk-read.epub',
    );
    final archive = ZipDecoder().decodeBytes(
      await file.readAsBytes(),
      verify: true,
    );
    expect(
      archive.findFile('OEBPS/images/img1.png')!.content,
      await page.readAsBytes(),
    );
  });

  test('partial file reads preserve all image bytes', () async {
    final archive = await IOOverrides.runWithIOOverrides(
      export,
      _ShortReads(page),
    );
    expect(
      archive.findFile('OEBPS/images/img35.png')!.content,
      await page.readAsBytes(),
    );
  });

  test('premature end of an image fails and removes the output', () async {
    await expectLater(
      IOOverrides.runWithIOOverrides(export, _ShortReads(page, earlyEnd: true)),
      throwsA('Failed to read image file'),
    );
    expect(await File('${directory.path}/book.epub').exists(), isFalse);
  });

  test(
    'same-named local chapters are preserved through the export isolate',
    () async {
      for (final id in ['a', 'b']) {
        final chapterDir = Directory('${directory.path}/$id')..createSync();
        await File('${chapterDir.path}/0.png').writeAsBytes([id.codeUnitAt(0)]);
      }
      final comic = LocalComic(
        id: 'epub-test',
        title: 'Comic',
        subtitle: 'Author',
        tags: const [],
        directory: directory.path,
        chapters: const ComicChapters({'a': 'Same name', 'b': 'Same name'}),
        cover: 'page.png',
        comicType: const ComicType(0),
        downloadedChapters: const ['b', 'a'],
        createdAt: DateTime(2024),
      );
      final files = await Future.wait([
        createEpubWithLocalComic(comic, '${directory.path}/first.epub'),
        createEpubWithLocalComic(comic, '${directory.path}/second.epub'),
      ]);
      for (final file in files) {
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        expect(
          xml(archive, 'content.opf').findAllElements('itemref').length,
          2,
        );
        expect(
          xml(
            archive,
            'toc.ncx',
          ).findAllElements('navLabel').map((e) => e.innerText),
          ['Same name', 'Same name'],
        );
        expect(archive.findFile('OEBPS/images/img0.png')!.content, [98]);
        expect(archive.findFile('OEBPS/images/img1.png')!.content, [97]);
      }
    },
  );

  test(
    'missing or empty later pages fail without leaving an incomplete EPUB',
    () async {
      for (final empty in [false, true]) {
        final invalid = File('${directory.path}/invalid.png');
        if (empty) await invalid.writeAsBytes([]);
        final destination = File('${directory.path}/failed.epub');
        await expectLater(
          createEpubComic(
            EpubData(
              title: 'Comic',
              author: 'Author',
              cover: page,
              chapters: [
                EpubChapter('Chapter', [page, invalid]),
              ],
            ),
            destination.path,
          ),
          throwsA(anything),
        );
        expect(await destination.exists(), isFalse);
      }
    },
  );

  test('many-chapter archive preserves size and the final page', () async {
    // Opt in to the 2 GiB regression with --dart-define=EPUB_LARGE_TEST=true.
    const large = bool.fromEnvironment('EPUB_LARGE_TEST');
    const pageSize = large ? 16 * 1024 * 1024 : 65536;
    const count = large ? 128 : 20;
    final payload = File('${directory.path}/large.png');
    final writer = payload.openSync(mode: FileMode.write);
    final chunk = Uint8List.fromList(List.generate(65536, (i) => i % 251));
    try {
      for (var written = 0; written < pageSize; written += chunk.length) {
        writer.writeFromSync(chunk);
      }
    } finally {
      writer.closeSync();
    }
    final file = await createEpubComic(
      EpubData(
        title: 'Large comic',
        author: 'Author',
        cover: page,
        chapters: [
          for (var i = 0; i < count; i++) EpubChapter('Chapter $i', [payload]),
        ],
      ),
      '${directory.path}/large.epub',
    );
    expect(await file.length(), greaterThan(count * pageSize));
    final input = InputFileStream(file.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      expect(
        xml(archive, 'content.opf').findAllElements('itemref').length,
        count,
      );
      for (var i = 0; i < count; i++) {
        expect(archive.findFile('OEBPS/images/img$i.png')!.size, pageSize);
      }
      final last = archive
          .findFile('OEBPS/images/img${count - 1}.png')!
          .content;
      expect(last, await payload.readAsBytes());
      expect(
        xml(
          archive,
          'OEBPS/${count - 1}.html',
        ).findAllElements('img').single.getAttribute('src'),
        'images/img${count - 1}.png',
      );
    } finally {
      input.closeSync();
    }
  });
}

class _BulkReadFailureFile implements File {
  _BulkReadFailureFile(this.file);

  final File file;

  @override
  String get path => file.path;

  @override
  Uint8List readAsBytesSync() => Uint8List(0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ShortReads extends IOOverrides {
  _ShortReads(this.file, {this.earlyEnd = false});

  final File file;
  final bool earlyEnd;

  @override
  File createFile(String path) => path == file.path
      ? _ShortReadFile(file, earlyEnd)
      : super.createFile(path);
}

class _ShortReadFile implements File {
  _ShortReadFile(this.file, this.earlyEnd);

  final File file;
  final bool earlyEnd;

  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      _ShortReadHandle(file.openSync(mode: mode), earlyEnd);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ShortReadHandle implements RandomAccessFile {
  _ShortReadHandle(this.handle, this.earlyEnd);

  final RandomAccessFile handle;
  final bool earlyEnd;

  @override
  int lengthSync() => handle.lengthSync();

  @override
  void setPositionSync(int position) => handle.setPositionSync(position);

  @override
  void closeSync() => handle.closeSync();

  @override
  int readIntoSync(List<int> buffer, [int start = 0, int? end]) {
    if (earlyEnd && handle.positionSync() >= 1024) return 0;
    return handle.readIntoSync(
      buffer,
      start,
      ((end ?? buffer.length) - start > 1024) ? start + 1024 : end,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

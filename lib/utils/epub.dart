import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:xml/xml.dart';

class EpubChapter {
  final String title;
  final List<File> images;

  const EpubChapter(this.title, this.images);
}

class EpubData {
  final String title;
  final String author;
  final File cover;
  final List<EpubChapter> chapters;

  const EpubData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
  });
}

Future<File> createEpubComic(EpubData data, String outFilePath) async {
  final handle = FileHandle(outFilePath, mode: FileAccess.write);
  final output = OutputFileStream.withFileHandle(handle);
  final zip = ZipEncoder()..startEncode(output);
  var completed = false;

  void addText(String path, String text, {bool store = false}) {
    final entry = ArchiveFile.string(path, text);
    if (store) entry.compression = CompressionType.none;
    zip.add(entry);
  }

  void addImage(String path, File image) {
    // SAF bulk reads can silently return empty bytes after a native read error.
    final input = InputFileStream.withFileHandle(_EpubImageHandle(image.path));
    try {
      if (input.length == 0) {
        throw 'Failed to read image file';
      }
      // Images are already compressed. Store them with bounded-memory file IO.
      final entry = ArchiveFile.stream(path, input)
        ..compression = CompressionType.none;
      zip.add(entry, autoClose: false);
    } finally {
      input.closeSync();
    }
  }

  String escape(String text) => XmlText(text).toXmlString();

  try {
    addText('mimetype', 'application/epub+zip', store: true);
    addText('META-INF/container.xml', '''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>''');

    final coverExt = data.cover.extension;
    final coverMime = FileType.fromExtension(coverExt).mime;
    addImage('OEBPS/images/cover.$coverExt', data.cover);
    var imgIndex = 0;
    final manifest = StringBuffer()
      ..writeln(
        '    <item id="cover_image" href="OEBPS/images/cover.$coverExt" media-type="$coverMime"/>',
      )
      ..writeln(
        '    <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
      );
    final spine = StringBuffer();
    final navMap = StringBuffer();
    for (var i = 0; i < data.chapters.length; i++) {
      final chapter = data.chapters[i];
      final title = escape(chapter.title);
      final images = StringBuffer();
      for (final image in chapter.images) {
        final ext = image.extension;
        final name = 'img$imgIndex.$ext';
        addImage('OEBPS/images/$name', image);
        final mime = FileType.fromExtension(ext).mime;
        manifest.writeln(
          '    <item id="img$imgIndex" href="OEBPS/images/$name" media-type="$mime"/>',
        );
        images.writeln('    <img src="images/$name" alt="$name"/>');
        imgIndex++;
      }
      addText('OEBPS/$i.html', '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
  <head>
    <title>$title</title>
    <style type="text/css">
      img { max-width: 100%; height: auto; }
      body { margin: 0; padding: 0; }
    </style>
  </head>
  <body>
    <h1>$title</h1>
    <div>
$images    </div>
  </body>
</html>''');
      manifest.writeln(
        '    <item id="chapter$i" href="OEBPS/$i.html" media-type="application/xhtml+xml"/>',
      );
      spine.writeln('    <itemref idref="chapter$i"/>');
      navMap.writeln('''    <navPoint id="chapter$i" playOrder="${i + 1}">
      <navLabel><text>$title</text></navLabel>
      <content src="OEBPS/$i.html"/>
    </navPoint>''');
    }

    final uuid = const Uuid().v4();
    // This exporter uses the EPUB 2 NCX navigation format.
    addText('content.opf', '''<?xml version="1.0" encoding="UTF-8"?>
<package version="2.0" unique-identifier="book_id"
    xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata>
    <dc:title>${escape(data.title)}</dc:title>
    <dc:creator>${escape(data.author)}</dc:creator>
    <dc:language>und</dc:language>
    <dc:identifier id="book_id">urn:uuid:$uuid</dc:identifier>
    <meta name="cover" content="cover_image"/>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine toc="toc">
$spine  </spine>
</package>''');

    addText('toc.ncx', '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx" version="2005-1">
  <head>
    <meta name="dtb:uid" content="urn:uuid:$uuid"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>${escape(data.title)}</text></docTitle>
  <navMap>
$navMap  </navMap>
</ncx>''');

    zip.endEncode();
    output.closeSync();
    completed = true;
    return File(outFilePath);
  } finally {
    if (!completed) {
      try {
        handle.closeSync();
      } finally {
        await File(outFilePath).deleteIgnoreError();
      }
    }
  }
}

class _EpubImageHandle extends FileHandle {
  _EpubImageHandle(super.path);

  @override
  int readInto(Uint8List buffer, [int? size]) {
    // archive assumes reads fill its buffer; SAF may return shorter chunks.
    final count = (size ?? buffer.length).clamp(0, length - position);
    var read = 0;
    while (read < count) {
      final bytes = super.readInto(Uint8List.sublistView(buffer, read, count));
      if (bytes == 0) throw 'Failed to read image file';
      read += bytes;
    }
    return read;
  }
}

Future<File> createEpubWithLocalComic(
  LocalComic comic,
  String outFilePath,
) async {
  final chapters = <EpubChapter>[];
  Future<void> addChapter(String title, Object id) async {
    final images = await LocalManager().getImagesForComic(comic, id);
    chapters.add(
      EpubChapter(
        title,
        images.map((path) => File(path.substring('file://'.length))).toList(),
      ),
    );
  }

  if (comic.chapters == null) {
    await addChapter(comic.title, 0);
  } else {
    for (final id in comic.downloadedChapters) {
      await addChapter(comic.chapters![id]!, id);
    }
  }
  final data = EpubData(
    title: comic.title,
    author: comic.subtitle,
    cover: comic.coverFile,
    chapters: chapters,
  );
  return Isolate.run(
    () => overrideIO(() => createEpubComic(data, outFilePath)),
  );
}

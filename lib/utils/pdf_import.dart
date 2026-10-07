import 'dart:math';
import 'dart:ui' as ui;

import 'package:pdfrx_engine/pdfrx_engine.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

/// Converts one PDF into the same image directory used by local comics.
Future<LocalComic> importPdfComic(
  File file, {
  required String localPath,
  required String cachePath,
  void Function(double progress)? onProgress,
}) async {
  await pdfrxInitialize(tmpPath: cachePath);
  final document = await PdfDocument.openFile(file.path);
  Directory? destination;
  var completed = false;
  try {
    if (document.pages.isEmpty) {
      throw const FormatException('PDF has no pages');
    }
    final title = file.basenameWithoutExt;
    var name = findValidDirectoryName(localPath, title);
    var suffix = 1;
    // Even an empty existing directory belongs to someone else.
    while (await Directory(FilePath.join(localPath, name)).exists()) {
      name = findValidDirectoryName(localPath, '$title (${suffix++})');
    }
    destination = Directory(FilePath.join(localPath, name));
    await destination.create(recursive: true);
    for (var index = 0; index < document.pages.length; index++) {
      final page = document.pages[index];
      if (!page.width.isFinite ||
          !page.height.isFinite ||
          page.width <= 0 ||
          page.height <= 0) {
        throw const FormatException('Invalid PDF page size');
      }
      // Render at 144 dpi, capped at 2400 pixels on the longest edge.
      final scale = min(2.0, 2400 / max(page.width, page.height));
      final width = max(1, (page.width * scale).round());
      final height = max(1, (page.height * scale).round());
      final image = await page.render(
        fullWidth: width.toDouble(),
        fullHeight: height.toDouble(),
        backgroundColor: 0xffffffff,
      );
      if (image == null) throw const FormatException('PDF page render failed');
      try {
        final bytes = await _encodePng(image);
        await File(
          FilePath.join(destination.path, '${index + 1}.png'),
        ).writeAsBytes(bytes);
      } finally {
        image.dispose();
      }
      onProgress?.call((index + 1) / document.pages.length);
    }
    completed = true;
    return LocalComic(
      id: '', // Assigned by ImportComic.registerComics.
      title: title,
      subtitle: '',
      tags: const [],
      directory: name,
      chapters: null,
      cover: '1.png',
      comicType: ComicType.local,
      downloadedChapters: const [],
      createdAt: DateTime.now(),
    );
  } finally {
    try {
      await document.dispose();
    } finally {
      if (!completed && destination != null) {
        await destination.deleteIgnoreError(recursive: true);
      }
    }
  }
}

Future<Uint8List> _encodePng(PdfImage image) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(image.pixels);
  try {
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: image.width,
      height: image.height,
      pixelFormat: ui.PixelFormat.bgra8888,
    );
    try {
      final codec = await descriptor.instantiateCodec();
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw const FormatException('PNG encoding failed');
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

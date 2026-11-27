import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/comic_image_codec.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/utils/io.dart';

import 'fixtures/avif_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('software decoding preserves transparency and requested size', () async {
    final codec = await decodeComicImage(
      transparentAvifPageBytes(),
      decode: (buffer, {getTargetSize}) async {
        buffer.dispose();
        throw const FormatException('Unsupported AVIF');
      },
      getTargetSize: (w, h) =>
          ui.TargetImageSize(width: w ~/ 2, height: h ~/ 2),
    );
    addTearDown(codec.dispose);
    final image = (await codec.getNextFrame()).image;
    addTearDown(image.dispose);
    expect(image.width, 8);
    expect(image.height, 4);
    final pixels = (await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    ))!;
    expect(pixels.getUint8(0), greaterThan(230));
    expect(pixels.getUint8(3), closeTo(128, 2));
    expect(pixels.getUint8(7 * 4 + 2), greaterThan(230));
    expect(pixels.getUint8(7 * 4 + 3), 255);
  });

  test(
    'a local AVIF page renders its original pixels without a server',
    () async {
      final dir = await Directory.systemTemp.createTemp('venera-avif-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File(
        '${dir.path}/page.AVIF',
      ).writeAsBytes(avifPageBytes());
      final provider = ReaderImageProvider(
        'file://${file.path}',
        null,
        '1',
        '0',
        1,
      );
      await overrideIO(() async {
        final stream = provider.resolve(ImageConfiguration.empty);
        final ready = Completer<ImageInfo>();
        final listener = ImageStreamListener(
          (info, _) => ready.complete(info),
          onError: ready.completeError,
        );
        stream.addListener(listener);
        try {
          final info = await ready.future;
          try {
            expect(info.image.width, 16);
            expect(info.image.height, 8);
            final pixels = (await info.image.toByteData(
              format: ui.ImageByteFormat.rawStraightRgba,
            ))!;
            expect(pixels.getUint8(4 * 2), greaterThan(230));
            expect(pixels.getUint8(4 * 2 + 2), lessThan(30));
            expect(pixels.getUint8(4 * 13), lessThan(30));
            expect(pixels.getUint8(4 * 13 + 2), greaterThan(230));
          } finally {
            info.dispose();
          }
        } finally {
          stream.removeListener(listener);
          await provider.evict();
        }
      });
    },
  );
}

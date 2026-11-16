import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('local-image-size-'));
  tearDown(() => temp.deleteSync(recursive: true));

  String write(String name, List<int> bytes) {
    final file = File('${temp.path}/$name')..writeAsBytesSync(bytes);
    return 'file://${file.path}';
  }

  test('reads a page size from the start of a large file', () async {
    // Noise keeps the PNG well past the part that is read.
    const width = 1024, height = 512;
    final random = Random(1);
    final pixels = Uint8List.fromList([
      for (var i = 0; i < width * height * 4; i++) random.nextInt(256),
    ]);
    final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: width,
      height: height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final image = (await codec.getNextFrame()).image;
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    expect(png.lengthInBytes, greaterThan(1024 * 1024));
    final path = write('page.png', png.buffer.asUint8List());
    expect(await readLocalImageSize(path), const Size(1024, 512));
  });

  test('leaves unknown formats and missing files to the decoder', () async {
    expect(await readLocalImageSize(write('page.bin', [1, 2, 3, 4])), isNull);
    expect(await readLocalImageSize('file://${temp.path}/missing.png'), isNull);
  });
}

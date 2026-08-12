import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

RgbaImage _whiteImage(int width, int height) {
  var pixels = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    pixels[i * 4] = 255;
    pixels[i * 4 + 1] = 255;
    pixels[i * 4 + 2] = 255;
    pixels[i * 4 + 3] = 255;
  }
  return RgbaImage(width, height, pixels);
}

Future<Uint8List> _decodeRgba(Uint8List png) async {
  var codec = await ui.instantiateImageCodec(png);
  var frame = await codec.getNextFrame();
  try {
    var data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  } finally {
    frame.image.dispose();
    codec.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('long translation never paints outside its region', () async {
    const width = 80;
    const height = 60;
    var decoded = _whiteImage(width, height);
    var region = TranslatedRegion(
      rect: IntRect(25, 22, 55, 36),
      text: 'This translation is deliberately too long for this tiny box.',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );

    var png = await renderTranslatedPage(Uint8List(0), decoded, [region]);
    var pixels = await _decodeRgba(png);

    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        if (x >= region.rect.left &&
            x < region.rect.right &&
            y >= region.rect.top &&
            y < region.rect.bottom) {
          continue;
        }
        var i = (y * width + x) * 4;
        expect(
          pixels.sublist(i, i + 4),
          [255, 255, 255, 255],
          reason: 'pixel $x,$y is outside the translation region',
        );
      }
    }
  });

  test('tiny translation region does not enter text layout', () async {
    const width = 20;
    const height = 20;
    var decoded = _whiteImage(width, height);
    var region = TranslatedRegion(
      rect: IntRect(8, 8, 11, 11),
      text: 'too small',
      backgroundColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
    );

    var png = await renderTranslatedPage(Uint8List(0), decoded, [region]);
    expect(await _decodeRgba(png), decoded.pixels);
  });
}

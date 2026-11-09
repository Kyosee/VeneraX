import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// Reuse the image package already resolved by flutter_launcher_icons.
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as image;

import '../tool/prepare_ohos_icons.dart';

void main() {
  test('HarmonyOS default icon has an opaque white background', () {
    final root = Directory.systemTemp.createTempSync('ohos_icon_resources_');
    addTearDown(() => root.deleteSync(recursive: true));
    Directory('${root.path}/assets').createSync();
    final transparent = image.Image(width: 3, height: 1, numChannels: 4)
      ..setPixelRgba(1, 0, 255, 0, 0, 128)
      ..setPixelRgba(2, 0, 0, 0, 255, 255);
    final source = image.encodePng(transparent);
    for (final name in [
      'app_icon.png',
      'venera_original.png',
      'user_logo.png',
      'new_logo2.png',
      'new_logo3.png',
    ]) {
      File('${root.path}/assets/$name').writeAsBytesSync(source);
    }

    prepareOhosIcons(root);

    final media = '${root.path}/ohos/AppScope/resources/base/media';
    final generated = image.decodePng(
      File('$media/icon_default.png').readAsBytesSync(),
    )!;
    expect((generated.width, generated.height), (3, 1));
    expect(generated.getPixel(0, 0).toList(), [255, 255, 255]);
    expect(generated.getPixel(1, 0).toList(), [255, 127, 127]);
    expect(generated.getPixel(2, 0).toList(), [0, 0, 255]);
    for (final preset in ['orig', 'flat', 'mono', 'illust']) {
      expect(File('$media/icon_$preset.png').readAsBytesSync(), source);
    }
  });
}

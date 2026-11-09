import 'dart:io';

// Reuse the image package already resolved by flutter_launcher_icons.
// ignore: depend_on_referenced_packages
import 'package:image/image.dart' as image;

void prepareOhosIcons(Directory root) {
  const icons = {
    'default': 'app_icon.png',
    'orig': 'venera_original.png',
    'flat': 'user_logo.png',
    'mono': 'new_logo2.png',
    'illust': 'new_logo3.png',
  };
  final destination = Directory(
    '${root.path}/ohos/AppScope/resources/base/media',
  )..createSync(recursive: true);
  for (final icon in icons.entries) {
    final source = File('${root.path}/assets/${icon.value}');
    final output = '${destination.path}/icon_${icon.key}.png';
    if (icon.key == 'default') {
      final foreground = image.decodePng(source.readAsBytesSync());
      if (foreground == null) {
        throw FormatException('Invalid default launcher icon: ${source.path}');
      }
      final background = image.Image(
        width: foreground.width,
        height: foreground.height,
        numChannels: 3,
      );
      image.fill(background, color: image.ColorRgb8(255, 255, 255));
      image.compositeImage(background, foreground);
      File(output).writeAsBytesSync(image.encodePng(background));
    } else {
      source.copySync(output);
    }
  }
}

void main() => prepareOhosIcons(File.fromUri(Platform.script).parent.parent);

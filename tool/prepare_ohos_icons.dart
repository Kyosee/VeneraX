import 'dart:io';

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
    File('${root.path}/assets/${icon.value}').copySync(
      '${destination.path}/icon_${icon.key}.png',
    );
  }
}

void main() => prepareOhosIcons(File.fromUri(Platform.script).parent.parent);

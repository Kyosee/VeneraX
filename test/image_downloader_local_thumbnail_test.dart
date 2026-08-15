import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/images.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loadThumbnail reads a file:// cover from disk', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    await binding.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('venera_cover_test');
      final file = File('${dir.path}${Platform.pathSeparator}cover.png');
      await file.writeAsBytes([1, 2, 3, 4]);
      try {
        final bytes = <int>[];
        await for (final p in ImageDownloader.loadThumbnail(
          'file://${file.path}',
          'comic_collection_test',
        )) {
          if (p.imageBytes != null) bytes.addAll(p.imageBytes!);
        }
        expect(bytes, [1, 2, 3, 4]);

        await file.delete();
        await expectLater(
          ImageDownloader.loadThumbnail(
            'file://${file.path}',
            'comic_collection_test',
          ).drain(),
          throwsA(contains('Cover file not found')),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}

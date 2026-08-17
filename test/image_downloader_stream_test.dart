import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/images.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  const sourceKey = 'stream_diagnostic_source';

  ComicSource buildSource() {
    return ComicSource(
      'Stream diagnostic',
      sourceKey,
      null,
      null,
      null,
      null,
      const [],
      null,
      null,
      null,
      null,
      null,
      (image, cid, eid) => Future<Map<String, dynamic>>.delayed(
        const Duration(days: 1),
        () => <String, dynamic>{},
      ),
      null,
      'stream_diagnostic.js',
      '',
      '1.0.0',
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      null,
      false,
      false,
      null,
      null,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('venera_image_stream_test');
    App.dataPath = root.path;
    App.cachePath = root.path;
    CacheManager.instance = null;
    ComicSourceManager().add(buildSource());
  });

  tearDown(() async {
    ImageDownloader.cancelAllLoadingImages();
    ComicSourceManager().remove(sourceKey);
    await CacheManager().clear();
    DatabaseGateway.instance.closeManaged('${App.dataPath}/cache.db');
    CacheManager.instance = null;
    await root.delete(recursive: true);
  });

  test('immediate subscriber receives a cached image', () async {
    const imageKey = 'immediate-image';
    await CacheManager().writeCache('$imageKey@$sourceKey@cid@eid', [1, 2, 3]);

    final progress =
        await ImageDownloader.loadComicImage(imageKey, sourceKey, 'cid', 'eid')
            .firstWhere((event) => event.imageBytes != null)
            .timeout(const Duration(seconds: 1));

    expect(progress.imageBytes, [1, 2, 3]);
  });

  test('late subscriber receives the cached image event', () async {
    const imageKey = 'prefetched-image';
    await CacheManager().writeCache('$imageKey@$sourceKey@cid@eid', [9, 8, 7]);

    // Mirrors _preDownloadImage: the shared stream is started and discarded.
    ImageDownloader.loadComicImage(imageKey, sourceKey, 'cid', 'eid');
    await Future<void>.delayed(const Duration(milliseconds: 100));

    final progress =
        await ImageDownloader.loadComicImage(imageKey, sourceKey, 'cid', 'eid')
            .firstWhere((event) => event.imageBytes != null)
            .timeout(const Duration(seconds: 1));

    expect(progress.imageBytes, [9, 8, 7]);
  });
}

import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_provider/avif_fallback.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/sqlite_connection.dart';
import 'package:venera/network/images.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CacheManager manager;
  const url = 'https://example.invalid/cover.jpg';
  final key = ImageDownloader.thumbnailCacheKey(url, null, 'comic');

  int expires(String cacheKey) {
    final db = sqlite3.open('${root.path}/cache.db');
    try {
      return db.select('SELECT expires FROM cache WHERE key = ?', [
            cacheKey,
          ]).single['expires']
          as int;
    } finally {
      db.dispose();
    }
  }

  setUp(() async {
    root = Directory.systemTemp.createTempSync('thumbnail-retention-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    appdata.settings[CacheManager.directorySetting] = '';
    CacheManager.instance = null;
    manager = CacheManager();
    await manager.ready;
  });

  tearDown(() async {
    await manager.ready;
    PaintingBinding.instance.imageCache.clear();
    AvifFallbackRegistry.instance.clear();
    DatabaseGateway.instance.closeManaged('${root.path}/cache.db');
    CacheManager.instance = null;
    root.deleteSync(recursive: true);
  });

  test(
    'cached thumbnail completes offline after restart and renews for 90 days',
    () async {
      await manager.writeCache(key, [
        1,
        2,
        3,
      ], ImageDownloader.thumbnailCacheDuration.inMilliseconds);
      final beforeRestart = DateTime.now()
          .add(const Duration(days: 89))
          .millisecondsSinceEpoch;
      expect(expires(key), greaterThan(beforeRestart));
      DatabaseGateway.instance.closeManaged('${root.path}/cache.db');
      CacheManager.instance = null;
      manager = CacheManager();
      await manager.ready;

      // Complete consumption used to continue to the network after a cache hit.
      final events = await ImageDownloader.loadThumbnail(
        url,
        null,
        'comic',
      ).toList().timeout(const Duration(seconds: 5));
      expect(events.single.imageBytes, [1, 2, 3]);
      expect(expires(key), greaterThan(beforeRestart));

      await manager.writeCache('page', [4]);
      await manager.findCache('page');
      final now = DateTime.now();
      expect(
        expires('page'),
        greaterThan(now.add(const Duration(days: 6)).millisecondsSinceEpoch),
      );
      expect(
        expires('page'),
        lessThan(now.add(const Duration(days: 8)).millisecondsSinceEpoch),
      );
    },
  );

  test(
    'long-lived thumbnails still expire, obey the size limit and clear',
    () async {
      await manager.writeCache('expired', [1], -1);
      expect(
        await manager.findCache(
          'expired',
          ImageDownloader.thumbnailCacheDuration.inMilliseconds,
        ),
        isNull,
      );
      await manager.writeCache(key, [
        1,
        2,
        3,
      ], ImageDownloader.thumbnailCacheDuration.inMilliseconds);
      manager.setLimitSize(0);
      await manager.checkCache();
      expect(await manager.findCache(key), isNull);
      manager.setLimitSize(1);
      await manager.writeCache(key, [
        1,
        2,
        3,
      ], ImageDownloader.thumbnailCacheDuration.inMilliseconds);
      await manager.clear();
      expect(await manager.findCache(key), isNull);
    },
  );

  test(
    'explicit refresh discards original and fallback bytes, preserving other covers',
    () async {
      const avif = 'https://example.invalid/cover.avif';
      const webp = 'https://example.invalid/cover.webp';
      final originalKey = ImageDownloader.thumbnailCacheKey(
        avif,
        null,
        'comic',
      );
      final fallbackKey = ImageDownloader.thumbnailCacheKey(
        webp,
        null,
        'comic',
      );
      await manager.writeCache(originalKey, [1]);
      await manager.writeCache(fallbackKey, [2]);
      await manager.writeCache(key, [3]);
      AvifFallbackRegistry.instance.markFailed(avif);

      await const CachedImageProvider(avif, cid: 'comic').refresh();

      expect(await manager.findCache(originalKey), isNull);
      expect(await manager.findCache(fallbackKey), isNull);
      expect((await manager.findCache(key))!.readAsBytesSync(), [3]);
    },
  );
}

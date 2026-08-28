import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/history_image_provider.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/image_provider/local_favorite_image.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';
import 'package:venera/network/images.dart';

/// An image whose bytes fail to decode is evicted by `diskCacheKey`. If that key
/// does not match the one the downloader wrote under, eviction silently hits a
/// non-existent row and the bad bytes are served from cache forever: the image
/// never recovers, and a source's load hook is never reached because the cache
/// branch returns before the download branch runs.
///
/// Every provider that reads through [ImageDownloader] must therefore report the
/// same key the downloader writes. `key` cannot be reused for this — it is the
/// provider's identity in Flutter's in-memory image cache and several providers
/// build it from fields that never reach disk.
void main() {
  const url = 'https://example.invalid/covers/abc.jpg';

  group('cover provider', () {
    test('eviction key matches the written key', () {
      final withCid = CachedImageProvider(url, sourceKey: 'src', cid: '96937');
      expect(
        withCid.diskCacheKey,
        ImageDownloader.thumbnailCacheKey(url, 'src', '96937'),
      );

      final noCid = CachedImageProvider(url, sourceKey: 'src');
      expect(noCid.diskCacheKey, ImageDownloader.thumbnailCacheKey(url, 'src'));
    });

    test('identity key stays separate from the disk key', () {
      final p = CachedImageProvider(url, sourceKey: 'src', cid: '96937');
      expect(p.key, isNot(p.diskCacheKey));
    });
  });

  group('reader provider', () {
    ReaderImageProvider make({bool resize = false, String? trKey}) =>
        ReaderImageProvider(
          'page.jpg',
          'src',
          'cid1',
          'eid1',
          0,
          enableResize: resize,
          translationKey: trKey,
        );

    test('eviction key matches the written key', () {
      expect(
        make().diskCacheKey,
        ImageDownloader.imageCacheKey('page.jpg', 'src', 'cid1', 'eid1'),
      );
    });

    test('resize and translation state do not reach the disk key', () {
      // These change the provider identity so the reader can swap the image in
      // place, but the bytes on disk are the same entry.
      final plain = make();
      final resized = make(resize: true);
      final translated = make(trKey: 'tr-key');

      expect(resized.diskCacheKey, plain.diskCacheKey);
      expect(translated.diskCacheKey, plain.diskCacheKey);
      expect(resized.key, isNot(plain.key));
      expect(translated.key, isNot(plain.key));
    });
  });

  group('history provider', () {
    test('eviction key matches the written key', () {
      final history = History.fromMap({
        'type': 0,
        'time': 0,
        'id': 'comic-1',
        'cover': url,
        'ep': 0,
        'page': 0,
      });
      final p = HistoryImageProvider(history);

      expect(
        p.diskCacheKey,
        ImageDownloader.thumbnailCacheKey(
          history.cover,
          history.type.sourceKey,
          history.id,
        ),
      );
      expect(p.key, isNot(p.diskCacheKey));
    });
  });

  group('local favorite provider', () {
    test('eviction key matches the written key', () {
      // intKey resolves to a source key; with no sources registered it is null,
      // which must still produce the downloader's exact key rather than throw.
      final p = LocalFavoriteImageProvider(url, 'comic-1', 12345);
      expect(p.diskCacheKey, ImageDownloader.thumbnailCacheKey(url, null));
      expect(p.key, isNot(p.diskCacheKey));
    });
  });

  group('image favorites provider', () {
    test('eviction key matches the written key', () {
      final p = ImageFavoritesProvider(
        ImageFavorite(3, 'page.jpg', false, 'eid1', 'cid1', 0, 'src', ''),
      );

      expect(
        p.diskCacheKey,
        ImageDownloader.imageCacheKey('page.jpg', 'src', 'cid1', 'eid1'),
      );
      // `key` keeps the page so each favorited page stays distinct; that is
      // exactly why it cannot double as the disk key.
      expect(p.key, contains('@3'));
      expect(p.key, isNot(p.diskCacheKey));
    });
  });

  group('key construction', () {
    test('cid distinguishes entries and is dropped when absent', () {
      expect(
        ImageDownloader.thumbnailCacheKey(url, 'src', '1'),
        isNot(ImageDownloader.thumbnailCacheKey(url, 'src', '2')),
      );
      expect(
        ImageDownloader.thumbnailCacheKey(url, 'src'),
        isNot(contains('@null')),
      );
    });

    test('page keys separate chapters', () {
      expect(
        ImageDownloader.imageCacheKey('p.jpg', 'src', 'c', 'e1'),
        isNot(ImageDownloader.imageCacheKey('p.jpg', 'src', 'c', 'e2')),
      );
    });
  });
}

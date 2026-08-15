import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/foundation/local.dart';

/// Regression test for issue #205 (批量下载时下载页面封面不显示).
///
/// A queued download task shows up in the local grid as a placeholder
/// [LocalComic] with no directory: nothing has been written to disk yet. Such a
/// placeholder used to carry no cover at all, so every queued comic rendered a
/// blank box until its turn came — only the running one had a cover. The task
/// now carries the cover url known by whoever created it, and the placeholder
/// is loaded over the network instead of from a file that does not exist.
///
/// The empty-directory guard from issue #53 must stay intact: a placeholder
/// without any cover url still has to be refused rather than scanned for out of
/// the downloads root.
void main() {
  LocalComic comic({required String directory, required String cover}) =>
      LocalComic(
        id: 'c1',
        title: 'T',
        subtitle: '',
        tags: const [],
        directory: directory,
        chapters: null,
        cover: cover,
        comicType: const ComicType(123),
        downloadedChapters: const [],
        createdAt: DateTime(2024),
      );

  test('queued placeholder loads its cover url over the network', () {
    final provider = findImageProvider(
      comic(directory: '', cover: 'https://example.com/cover.jpg'),
    );
    expect(provider, isA<CachedImageProvider>());
    expect(
      (provider as CachedImageProvider).url,
      'https://example.com/cover.jpg',
    );
    expect(provider.sourceKey, isNotNull,
        reason: 'cover requests need the source auth headers');
  });

  test('placeholder without a cover url keeps the local loader', () {
    final provider = findImageProvider(comic(directory: '', cover: ''));
    expect(provider, isA<LocalComicImageProvider>());
  });

  test('comic already on disk keeps the local loader', () {
    final provider = findImageProvider(
      comic(directory: 'T', cover: 'cover.jpg'),
    );
    expect(provider, isA<LocalComicImageProvider>());
  });
}

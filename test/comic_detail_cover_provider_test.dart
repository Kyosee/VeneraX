import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

/// Regression test for issue #38 (导入漫画详情页/历史页不显示封面).
///
/// A locally-imported comic stores a *relative* cover path ("cover.jpg") and has
/// no network [ComicSource]. The comic detail header used to build a
/// [CachedImageProvider] for it, which sends the relative path to the network
/// layer and fails with "relative URL without a base" — so the cover went blank.
/// Such covers must instead be loaded straight from the local file via
/// [LocalComicImageProvider], the same loader the local library grid uses.
/// Downloaded comics keep a resolvable network source and must still use the
/// cached/network path.
void main() {
  LocalComic comicOfType(ComicType type) => LocalComic(
        id: 'c1',
        title: 'T',
        subtitle: '',
        tags: const [],
        directory: '/comics/T',
        chapters: null,
        cover: 'cover.jpg',
        comicType: type,
        downloadedChapters: const [],
        createdAt: DateTime(2024),
      );

  test('pure local import loads its cover from the local file', () {
    final provider = comicDetailCoverProvider(
      sourceKey: 'local',
      id: 'c1',
      cover: 'cover.jpg',
      localComic: comicOfType(ComicType.local),
    );
    expect(provider, isA<LocalComicImageProvider>());
  });

  test('downloaded comic (non-local type) keeps the cached/network loader', () {
    final provider = comicDetailCoverProvider(
      sourceKey: 'some_source',
      id: 'c1',
      cover: 'cover.jpg',
      localComic: comicOfType(const ComicType(123)),
    );
    expect(provider, isA<CachedImageProvider>());
  });

  test('no backing local comic falls back to the cached/network loader', () {
    final provider = comicDetailCoverProvider(
      sourceKey: 'some_source',
      id: 'c1',
      cover: 'https://example.com/c.jpg',
      localComic: null,
    );
    expect(provider, isA<CachedImageProvider>());
  });
}

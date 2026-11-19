import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';

ImageFavoritesEp _chapter(String eid, int ep, List<int> pages) =>
    ImageFavoritesEp(eid, ep, [
      for (final page in pages)
        ImageFavorite(page, 'key-$eid-$page', null, eid, 'comic', ep, 's', 'C$ep'),
    ], 'C$ep', 20);

ImageFavoritesComic _comic(List<ImageFavoritesEp> chapters) =>
    ImageFavoritesComic(
      'comic',
      chapters,
      'Title',
      's',
      [],
      [],
      DateTime(2026),
      '',
      {},
      '',
      20,
    );

void main() {
  test('saved chapters follow their ids after a chapter is inserted', () {
    final comic = _comic([_chapter('a', 1, [2]), _chapter('b', 2, [3, 5])]);
    final moved = comic.remapChaptersById(
      ['extra', 'a', 'b'],
      ['Extra', 'Chapter A', 'Chapter B'],
    );
    expect(moved, isTrue);
    expect([for (final e in comic.imageFavoritesEp) (e.eid, e.ep)], [
      ('a', 2),
      ('b', 3),
    ]);
    final b = comic.imageFavoritesEp.last;
    expect(b.epName, 'Chapter B');
    expect([for (final f in b.imageFavorites) (f.ep, f.epName, f.page)], [
      (3, 'Chapter B', 3),
      (3, 'Chapter B', 5),
    ]);
  });

  test('a replaced chapter keeps its place, so collecting still asks', () {
    final comic = _comic([_chapter('old', 1, [4])]);
    expect(comic.remapChaptersById(['new'], ['New']), isFalse);
    expect(comic.imageFavoritesEp.single.ep, 1);
    expect(comic.imageFavoritesEp.single.eid, 'old');
  });

  test('a move onto a kept chapter changes nothing', () {
    final comic = _comic([_chapter('gone', 1, [2]), _chapter('b', 2, [3])]);
    expect(comic.remapChaptersById(['b', 'c'], ['B', 'C']), isFalse);
    expect([for (final e in comic.imageFavoritesEp) (e.eid, e.ep)], [
      ('gone', 1),
      ('b', 2),
    ]);
  });

  test('imported chapters without an id stay where they are', () {
    final comic = _comic([_chapter('', 1, [2]), _chapter('b', 2, [3])]);
    expect(comic.remapChaptersById(['b', 'x'], ['B', 'X']), isFalse);
    final reordered = _comic([_chapter('', 1, [2]), _chapter('b', 3, [3])]);
    expect(reordered.remapChaptersById(['z', 'b', 'x'], ['Z', 'B', 'X']), isTrue);
    expect([for (final e in reordered.imageFavoritesEp) (e.eid, e.ep)], [
      ('', 1),
      ('b', 2),
    ]);
  });
}

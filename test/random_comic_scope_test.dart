import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/random_comic_scope.dart';

History history({required int page, int? maxPage}) {
  final value = History.fromMap({
    'type': 1,
    'time': 0,
    'title': 'Comic',
    'subtitle': '',
    'cover': '',
    'ep': 1,
    'page': page,
    'id': 'comic',
    'readEpisode': '',
    'max_page': maxPage,
    'chapter_group': null,
  });
  return value;
}

void main() {
  test('all accepts every reading state', () {
    expect(
      randomComicMatchesReadingScope(RandomComicReadingScope.all, null),
      isTrue,
    );
    expect(
      randomComicMatchesReadingScope(
        RandomComicReadingScope.all,
        history(page: 1, maxPage: 10),
      ),
      isTrue,
    );
  });

  test('not started requires missing history', () {
    expect(
      randomComicMatchesReadingScope(RandomComicReadingScope.notStarted, null),
      isTrue,
    );
    expect(
      randomComicMatchesReadingScope(
        RandomComicReadingScope.notStarted,
        history(page: 1, maxPage: 10),
      ),
      isFalse,
    );
  });

  test(
    'in progress includes unknown totals but excludes completed history',
    () {
      expect(
        randomComicMatchesReadingScope(
          RandomComicReadingScope.inProgress,
          history(page: 3),
        ),
        isTrue,
      );
      expect(
        randomComicMatchesReadingScope(
          RandomComicReadingScope.inProgress,
          history(page: 10, maxPage: 10),
        ),
        isFalse,
      );
    },
  );

  test('completed accepts the last page and defensive overshoot', () {
    expect(
      randomComicMatchesReadingScope(
        RandomComicReadingScope.completed,
        history(page: 10, maxPage: 10),
      ),
      isTrue,
    );
    expect(
      randomComicMatchesReadingScope(
        RandomComicReadingScope.completed,
        history(page: 11, maxPage: 10),
      ),
      isTrue,
    );
  });
}

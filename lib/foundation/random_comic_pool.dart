import 'history.dart';

enum RandomComicReadingScope { all, notStarted, inProgress, completed }

bool randomComicMatchesReadingScope(
  RandomComicReadingScope scope,
  History? history,
) {
  final completed =
      history != null &&
      history.maxPage != null &&
      history.maxPage! > 0 &&
      history.page >= history.maxPage!;
  return switch (scope) {
    RandomComicReadingScope.all => true,
    RandomComicReadingScope.notStarted => history == null,
    RandomComicReadingScope.inProgress => history != null && !completed,
    RandomComicReadingScope.completed => completed,
  };
}

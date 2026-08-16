import 'history.dart';

enum RandomComicReadingScope { all, notStarted, inProgress, completed }

String? randomComicAvailableFolder(
  String? selectedFolder,
  Iterable<String> folders,
) => selectedFolder != null && folders.contains(selectedFolder)
    ? selectedFolder
    : null;

RandomComicReadingScope randomComicReadingScopeFromName(Object? name) =>
    RandomComicReadingScope.values.firstWhere(
      (scope) => scope.name == name,
      orElse: () => RandomComicReadingScope.all,
    );

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

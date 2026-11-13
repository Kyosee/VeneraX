import 'dart:math';

import 'favorites.dart';

/// Stable identity used to keep one draw session free of repeats.
typedef RandomComicIdentity = ({String sourceKey, String id});

RandomComicIdentity randomComicIdentity(FavoriteItem comic) =>
    (sourceKey: comic.sourceKey, id: comic.id);

/// Selects one comic from the current random scope.
///
/// A future reading-statistics-weighted implementation can implement this
/// contract without changing the draw UI. The current release deliberately
/// exposes only [UniformRandomComicPicker].
abstract interface class RandomComicPicker {
  FavoriteItem? pick(
    List<FavoriteItem> candidates, {
    Set<RandomComicIdentity> excluded = const {},
  });
}

extension RandomComicBatchPicker on RandomComicPicker {
  /// Deals up to [count] distinct comics without crossing the current round.
  List<FavoriteItem> pickMany(
    List<FavoriteItem> candidates, {
    required int count,
    Set<RandomComicIdentity> excluded = const {},
  }) {
    final remainingExclusions = {...excluded};
    final result = <FavoriteItem>[];
    for (var i = 0; i < count; i++) {
      final comic = pick(candidates, excluded: remainingExclusions);
      if (comic == null) break;
      result.add(comic);
      remainingExclusions.add(randomComicIdentity(comic));
    }
    return result;
  }
}

/// Gives every eligible comic the same chance of being selected.
class UniformRandomComicPicker implements RandomComicPicker {
  UniformRandomComicPicker({Random? random}) : _random = random ?? Random();

  final Random _random;

  @override
  FavoriteItem? pick(
    List<FavoriteItem> candidates, {
    Set<RandomComicIdentity> excluded = const {},
  }) {
    final eligible = candidates
        .where((comic) => !excluded.contains(randomComicIdentity(comic)))
        .toList(growable: false);
    if (eligible.isEmpty) return null;
    return eligible[_random.nextInt(eligible.length)];
  }
}

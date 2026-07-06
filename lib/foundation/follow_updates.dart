import 'dart:async';
import 'dart:convert';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  String folder, {
  bool Function()? shouldCancel,
}) async {
  int retries = 3;
  while (true) {
    // Bail before the (slow) network call so a cancel that arrives mid-queue
    // doesn't have to wait for this comic to finish fetching (#3).
    if (shouldCancel?.call() ?? false) {
      return ComicUpdateResult(false, null);
    }
    try {
      var comicSource = c.type.comicSource;
      if (comicSource == null) {
        return ComicUpdateResult(false, "Comic source not found");
      }
      var newInfo = (await comicSource.loadComicInfo!(c.id)).data;
      // The fetch may have taken seconds; if the user cancelled meanwhile, drop
      // the result without touching the DB.
      if (shouldCancel?.call() ?? false) {
        return ComicUpdateResult(false, null);
      }

      // Rate-limited or blocked endpoints sometimes "succeed" with a hollow
      // payload; writing it below would blank the favorite's name/cover.
      // Treat it as a failed attempt so the retry/error path reports it.
      if (newInfo.title.trim().isEmpty) {
        throw Exception("Empty comic info");
      }

      var newTags = <String>[];
      for (var entry in newInfo.tags.entries) {
        const shouldIgnore = ['author', 'artist', 'time'];
        var namespace = entry.key;
        if (shouldIgnore.contains(namespace.toLowerCase())) {
          continue;
        }
        for (var tag in entry.value) {
          newTags.add("$namespace:$tag");
        }
      }

      const ComicStateRepository().mirrorComicDetails(newInfo);

      var item = FavoriteItem(
        id: c.id,
        name: newInfo.title,
        coverPath: newInfo.cover,
        author:
            newInfo.subTitle ?? newInfo.tags['author']?.firstOrNull ?? c.author,
        type: c.type,
        tags: newTags,
      );

      LocalFavoritesManager().updateInfo(folder, item, false);

      var updated = false;
      var updateTime = newInfo.findUpdateTime();
      if (updateTime != null && updateTime != c.updateTime) {
        LocalFavoritesManager().updateUpdateTime(
          folder,
          c.id,
          c.type,
          updateTime,
        );
        updated = true;
      } else {
        LocalFavoritesManager().updateCheckTime(folder, c.id, c.type);
      }
      return ComicUpdateResult(updated, null);
    } catch (e, s) {
      retries--;
      if (retries == 0) {
        // Only escalate to an error once we've exhausted retries and are
        // actually giving up on this comic. Transient failures (source script
        // errors, rate limiting, non-JSON responses) are expected during bulk
        // update checks and shouldn't flood the error log on every retry.
        Log.error("Check Updates", e, s);
        return ComicUpdateResult(false, e.toString());
      }
      Log.warning("Check Updates", "Failed to update ${c.id}, retrying: $e");
      // Wait in short slices so a cancel during the retry backoff is honored
      // promptly instead of blocking for the full 2 seconds.
      for (var i = 0; i < 4; i++) {
        if (shouldCancel?.call() ?? false) {
          return ComicUpdateResult(false, null);
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }
}

class UpdateProgress {
  final int total;
  final int current;
  final int errors;
  final int updated;
  final FavoriteItemWithUpdateInfo? comic;
  final String? errorMessage;

  /// Whether [comic] itself was found updated by this event — unlike the
  /// cumulative [updated] counter, this needs no cross-event bookkeeping.
  final bool comicUpdated;

  UpdateProgress(
    this.total,
    this.current,
    this.errors,
    this.updated, [
    this.comic,
    this.errorMessage,
    this.comicUpdated = false,
  ]);
}

void updateFolderBase(
  String folder,
  StreamController<UpdateProgress> stream,
  bool ignoreCheckTime,
  bool Function()? shouldCancel, {
  DateTime? checkedSince,
}) async {
  // This runs unawaited; a throw here (folder deleted mid-flight, database
  // being swapped by a sync import) used to be an unhandled zone error that
  // left the stream open forever — the consuming task then stayed "running"
  // permanently and blocked every later check for the folder. Surface it
  // through the stream instead so the task finalizes as failed.
  List<FavoriteItemWithUpdateInfo> comics;
  try {
    comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  } catch (e, s) {
    Log.error("Check Updates", e, s);
    stream.addError(e);
    stream.close();
    return;
  }
  int total = comics.length;
  int current = 0;
  int errors = 0;
  int updated = 0;

  stream.add(UpdateProgress(total, current, errors, updated));

  var comicsToUpdate = <FavoriteItemWithUpdateInfo>[];

  for (var comic in comics) {
    // Resume support: skip comics already checked during this task's lifetime.
    // `checkedSince` is the task's creation time; a comic whose last check is
    // at or after it was handled before the app was killed, so resuming the
    // task continues from the breakpoint instead of re-checking everything.
    if (checkedSince != null) {
      var lastCheckTime = comic.lastCheckDateTime;
      if (lastCheckTime != null && !lastCheckTime.isBefore(checkedSince)) {
        current++;
        stream.add(UpdateProgress(total, current, errors, updated));
        continue;
      }
    }
    if (!ignoreCheckTime) {
      var lastCheckTime = comic.lastCheckDateTime;
      if (lastCheckTime != null &&
          DateTime.now().difference(lastCheckTime).inDays < 1) {
        current++;
        stream.add(UpdateProgress(total, current, errors, updated));
        continue;
      }
    }
    comicsToUpdate.add(comic);
  }

  total = comicsToUpdate.length;
  current = 0;
  stream.add(UpdateProgress(total, current, errors, updated));

  var channel = Channel<FavoriteItemWithUpdateInfo>(10);

  // Producer
  () async {
    var c = 0;
    for (var comic in comicsToUpdate) {
      if (shouldCancel?.call() ?? false) {
        break;
      }
      await channel.push(comic);
      c++;
      // Throttle, but in short slices so a cancel during the backoff closes the
      // channel within ~0.5s instead of blocking for the full delay (#3).
      if (c % 5 == 0) {
        var delay = c % 100 + 1;
        if (delay > 10) {
          delay = 10;
        }
        for (var i = 0; i < delay * 2; i++) {
          if (shouldCancel?.call() ?? false) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }
    channel.close();
  }();

  // Consumers
  var updateFutures = <Future>[];
  for (var i = 0; i < 5; i++) {
    var f = () async {
      while (true) {
        var comic = await channel.pop();
        if (comic == null) {
          break;
        }
        if (shouldCancel?.call() ?? false) {
          break;
        }
        var result = await updateComic(comic, folder, shouldCancel: shouldCancel);
        current++;
        if (result.updated) {
          updated++;
        }
        if (result.errorMessage != null) {
          errors++;
        }
        stream.add(
          UpdateProgress(
            total,
            current,
            errors,
            updated,
            comic,
            result.errorMessage,
            result.updated,
          ),
        );
      }
    }();
    updateFutures.add(f);
  }

  await Future.wait(updateFutures);

  if (updated > 0) {
    LocalFavoritesManager().notifyChanges();
  }

  stream.close();
}

Stream<UpdateProgress> updateFolder(
  String folder,
  bool ignoreCheckTime, {
  bool Function()? shouldCancel,
  DateTime? checkedSince,
}) {
  var stream = StreamController<UpdateProgress>();
  updateFolderBase(
    folder,
    stream,
    ignoreCheckTime,
    shouldCancel,
    checkedSince: checkedSince,
  );
  return stream.stream;
}

Future<String> getUpdatedComicsAsJson(String folder) async {
  var comics = LocalFavoritesManager().getComicsWithUpdatesInfo(folder);
  var updatedComics = comics.where((c) => c.hasNewUpdate == true).toList();
  var jsonList = updatedComics
      .map(
        (c) => {
          'id': c.id,
          'name': c.name,
          'coverUrl': c.coverPath,
          'author': c.author,
          'type': c.type.sourceKey,
          'updateTime': c.updateTime,
          'tags': c.tags,
        },
      )
      .toList();
  return jsonEncode(jsonList);
}

import 'dart:async';
import 'dart:convert';
import 'package:flutter/scheduler.dart';
import 'package:venera/foundation/comic_state_repository.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';

/// Serializes the per-comic database writes of a bulk update check and slots
/// them into the gaps between frames.
///
/// The check's 5 concurrent workers all apply their results with synchronous
/// SQLite statements on the UI isolate; when several comics finish near each
/// other those bursts used to land inside a single frame and read as dropped
/// frames while reading or scrolling. The network fetch is the throughput
/// bottleneck, so running the (millisecond-scale) write batches one at a time
/// costs nothing in check speed.
class _FollowUpdateDbGate {
  Future<void> _tail = Future.value();

  Future<void> run(void Function() writes) {
    final result = _tail.then((_) async {
      await _yieldToUi();
      writes();
    });
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _yieldToUi() async {
    try {
      final scheduler = SchedulerBinding.instance;
      if (scheduler.hasScheduledFrame ||
          scheduler.schedulerPhase != SchedulerPhase.idle) {
        // A frame is being produced (the user is interacting); land the write
        // right after it completes so it gets the largest possible slice of
        // the inter-frame budget instead of competing with build/paint.
        await scheduler.endOfFrame;
        return;
      }
    } catch (_) {
      // No frame pipeline (headless mode); just break the synchronous chain.
    }
    await Future.delayed(Duration.zero);
  }
}

final _dbWriteGate = _FollowUpdateDbGate();

class ComicUpdateResult {
  final bool updated;
  final String? errorMessage;

  ComicUpdateResult(this.updated, this.errorMessage);
}

/// Checks one comic and writes the result back to every [folders] entry that
/// holds it. A comic favorited in several followed folders is fetched once, but
/// each folder row keeps its own baseline: `has_new_update` is decided per row
/// against that row's `last_update_time`, so removing one folder from the scope
/// later doesn't take the mark with it.
Future<ComicUpdateResult> updateComic(
  FavoriteItemWithUpdateInfo c,
  List<String> folders, {
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

      var item = FavoriteItem(
        id: c.id,
        name: newInfo.title,
        coverPath: newInfo.cover,
        author:
            newInfo.subTitle ?? newInfo.tags['author']?.firstOrNull ?? c.author,
        type: c.type,
        tags: newTags,
      );

      var updateTime = newInfo.findUpdateTime();
      var updated = updateTime != null && updateTime != c.updateTime;

      await _dbWriteGate.run(() {
        const ComicStateRepository().mirrorComicDetails(newInfo);
        for (var folder in folders) {
          // mirrorComicDetails above already mirrored strictly more data than
          // updateInfo's own mirror pass would; skip the duplicate.
          LocalFavoritesManager().updateInfo(folder, item, false, false);
          if (updated) {
            LocalFavoritesManager().updateUpdateTime(
              folder,
              c.id,
              c.type,
              updateTime,
            );
          } else {
            LocalFavoritesManager().updateCheckTime(folder, c.id, c.type);
          }
        }
      });
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

/// One comic to check, with every followed folder its result is written to.
typedef FollowUpdateEntry = ({
  FavoriteItemWithUpdateInfo comic,
  List<String> folders,
});

/// Collects the comics of [folders] into one entry per comic, even when it is
/// favorited in several of them (#263). The check then fetches each comic once
/// and writes the result to all of its folders. The row carried along is the
/// first one seen, so the due/skip decision reads one folder's bookkeeping;
/// folder order is the store's, which keeps that stable across runs.
List<FollowUpdateEntry> dedupeFollowUpdateEntries(
  Map<String, List<FavoriteItemWithUpdateInfo>> folders,
) {
  // The favorites store keys rows by (id, type), so that pair is the comic's
  // identity across folders.
  var byIdentity = <String, int>{};
  var comics = <FavoriteItemWithUpdateInfo>[];
  var owners = <List<String>>[];
  for (var entry in folders.entries) {
    for (var comic in entry.value) {
      var index = byIdentity[comic.identityKey];
      if (index == null) {
        byIdentity[comic.identityKey] = comics.length;
        comics.add(comic);
        owners.add([entry.key]);
      } else {
        owners[index].add(entry.key);
      }
    }
  }
  return [
    for (var i = 0; i < comics.length; i++)
      (comic: comics[i], folders: owners[i]),
  ];
}

void updateFoldersBase(
  List<String> folders,
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
  List<FollowUpdateEntry> entries;
  try {
    var perFolder = <String, List<FavoriteItemWithUpdateInfo>>{};
    for (var folder in folders) {
      perFolder[folder] = LocalFavoritesManager().getComicsWithUpdatesInfo(
        folder,
      );
    }
    entries = dedupeFollowUpdateEntries(perFolder);
  } catch (e, s) {
    Log.error("Check Updates", e, s);
    stream.addError(e);
    stream.close();
    return;
  }
  int total = entries.length;
  int current = 0;
  int errors = 0;
  int updated = 0;

  stream.add(UpdateProgress(total, current, errors, updated));

  var comicsToUpdate = <FollowUpdateEntry>[];

  for (var entry in entries) {
    var comic = entry.comic;
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
    if (!ignoreCheckTime && !FollowUpdateScope.isDue(comic.lastCheckDateTime)) {
      current++;
      stream.add(UpdateProgress(total, current, errors, updated));
      continue;
    }
    comicsToUpdate.add(entry);
  }

  total = comicsToUpdate.length;
  current = 0;
  stream.add(UpdateProgress(total, current, errors, updated));

  var channel = Channel<FollowUpdateEntry>(10);

  // Producer
  () async {
    var c = 0;
    for (var entry in comicsToUpdate) {
      if (shouldCancel?.call() ?? false) {
        break;
      }
      await channel.push(entry);
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
        var entry = await channel.pop();
        if (entry == null) {
          break;
        }
        if (shouldCancel?.call() ?? false) {
          break;
        }
        var result = await updateComic(
          entry.comic,
          entry.folders,
          shouldCancel: shouldCancel,
        );
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
            entry.comic,
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

Stream<UpdateProgress> updateFolders(
  List<String> folders,
  bool ignoreCheckTime, {
  bool Function()? shouldCancel,
  DateTime? checkedSince,
}) {
  var stream = StreamController<UpdateProgress>();
  updateFoldersBase(
    folders,
    stream,
    ignoreCheckTime,
    shouldCancel,
    checkedSince: checkedSince,
  );
  return stream.stream;
}

Future<String> getUpdatedComicsAsJson(List<String> folders) async {
  var updatedComics = LocalFavoritesManager()
      .getComicsWithUpdatesInfoIn(folders)
      .where((c) => c.hasNewUpdate == true)
      .toList();
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

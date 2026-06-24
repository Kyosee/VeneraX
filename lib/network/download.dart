import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// bytes per second
  int get speed;

  /// Estimated time remaining, or null when it can't be estimated yet (no
  /// throughput sample, unknown total). Shown in the download list (#12).
  Duration? get eta => null;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// Whether the task was actively running when its state was last persisted.
  /// Lets the queue auto-resume genuinely-interrupted downloads on restart
  /// without reviving tasks the user had manually paused.
  bool wasRunning = false;

  /// How many times the queue has auto-retried this task after it errored.
  /// Bounded by [LocalManager] so a permanently-failing task eventually stops
  /// retrying and waits for the user. Reset when the user retries manually.
  int autoRetryCount = 0;

  /// True when the user explicitly paused this task (vs. it merely waiting its
  /// turn in the queue). The queue won't auto-resume a user-paused task, and it
  /// stays paused across restarts. Set by [pause]/[resume] paths via the queue.
  bool userPaused = false;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  @override
  void cancel() {
    _isRunning = false;
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = this.tasks.values.toList();
          for (var i = 0; i < tasks.length; i++) {
            if (!tasks[i].isComplete) {
              tasks[i].cancel();
              await tasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          }
          catch(e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          var dir = Directory(FilePath.join(path!, c));
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    _isRunning = false;
    _message = "Paused".tl;
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    notifyListeners();
    // Persist the paused state (wasRunning=false) so a manual pause is not
    // auto-resumed on next launch.
    LocalManager().saveCurrentDownloadingTasks();
  }

  @override
  double get progress {
    if (_totalChapters > 0) {
      // Blend whole-chapter progress with the current chapter's in-flight image
      // fraction so the bar advances smoothly instead of jumping a full chapter
      // at a time (#11).
      var base = _chapter / _totalChapters;
      var images = _images;
      var key = (images != null && _chapter < images.keys.length)
          ? images.keys.elementAt(_chapter)
          : null;
      var chapterImages = key == null ? null : images![key];
      if (chapterImages != null && chapterImages.isNotEmpty) {
        base += (_index / chapterImages.length) / _totalChapters;
      }
      return base.clamp(0.0, 1.0);
    }
    return _totalCount == 0 ? 0 : _downloadedCount / _totalCount;
  }

  @override
  Duration? get eta {
    if (isPaused || isError || _imagesPerSecond <= 0) return null;
    final remaining = (_totalCount - _downloadedCount).clamp(0, _totalCount);
    if (remaining <= 0) return null;
    return Duration(seconds: (remaining / _imagesPerSecond).ceil());
  }

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...".tl;

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Total chapters to download
  int _totalChapters = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  /// Smoothed images-per-second throughput (EMA), driven once per second from
  /// [onNextSecond]. Used to estimate [eta]. Zero until the first full second.
  double _imagesPerSecond = 0;

  /// Downloaded-count snapshot at the previous tick, to derive per-second rate.
  int _lastDownloadedCount = 0;

  var tasks = <int, _ImageDownloadWrapper>{};

  int get _maxConcurrentTasks =>
      (appdata.settings["downloadThreads"] as num).toInt();

  void _scheduleTasks() {
    if (!_isRunning) return;
    var images = _images![_images!.keys.elementAt(_chapter)]!;
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      if (tasks[i] != null) {
        // A terminal image failure: stop scheduling and let the chapter pool
        // surface the error (the wrapper already retried internally).
        if (tasks[i]!.error != null) {
          return;
        }
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        continue;
      }
      Directory saveTo;
      if (comic!.chapters != null) {
        saveTo = Directory(FilePath.join(
          path!,
          LocalManager.getChapterDirectoryName(
            _images!.keys.elementAt(_chapter),
          ),
        ));
        if (!saveTo.existsSync()) {
          saveTo.createSync(recursive: true);
        }
      } else {
        saveTo = Directory(path!);
      }
      var task = _ImageDownloadWrapper(
        this,
        _images!.keys.elementAt(_chapter),
        images[i],
        saveTo,
        i,
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete && _isRunning) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  /// Download every image of the current chapter with a completion-based
  /// concurrency pool: up to [_maxConcurrentTasks] images are in flight and the
  /// progress frontier advances over whichever finish first, so a single slow
  /// image no longer stalls the rest of the window (#2). Returns false if the
  /// task was paused, cancelled or errored (caller should stop); true when the
  /// whole chapter completed.
  Future<bool> _downloadChapterPool(
    List<String> images,
    String Function() buildMessage,
  ) async {
    while (_isRunning && _index < images.length) {
      _scheduleTasks();
      // Fail the task if any image exhausted its retries.
      for (final t in tasks.values) {
        if (t.error != null) {
          Log.error("Download", t.error.toString());
          _setError("Error: ${t.error}");
          return false;
        }
      }
      final pending = tasks.values
          .where((t) => !t.isComplete && t.error == null)
          .map((t) => t.wait())
          .toList();
      if (pending.isEmpty) {
        // Everything scheduled has finished; advance the frontier and exit.
        while (tasks[_index]?.isComplete == true) {
          _index++;
          _downloadedCount++;
        }
        break;
      }
      // Wait for ANY in-flight image rather than the head specifically.
      await Future.any(pending);
      if (isPaused) return false;
      while (tasks[_index]?.isComplete == true) {
        _index++;
        _downloadedCount++;
      }
      _message = buildMessage();
      LocalManager().scheduleSaveDownloadingTasks();
    }
    return _isRunning;
  }

  @override
  void resume() async {
    if (_isRunning) return;
    _isError = false;
    _message = "Resuming...".tl;
    _isRunning = true;
    notifyListeners();
    runRecorder();
    // Persist wasRunning=true promptly so an interrupted download auto-resumes
    // on next launch even if it crashes before the first progress checkpoint.
    LocalManager().saveCurrentDownloadingTasks();

    if (comic == null) {
      _message = "Fetching comic info...".tl;
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    await LocalManager().saveCurrentDownloadingTasks();

    if (_cover == null) {
      _message = "Downloading cover...".tl;
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress
            in ImageDownloader.loadThumbnail(comic!.cover, source.key)) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null) {
          throw "Failed to download cover";
        }
        var fileType = detectFileType(data);
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        return "file://${file.path}";
      });
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (_images == null) {
      if (comic!.chapters == null && source.loadComicInfo != null) {
        // Chapter info may be missing because the task was created from a
        // local-first placeholder (network details not yet resolved) or lost
        // during restore. Fetch authoritative details before deciding whether
        // this is a single- or multi-chapter comic, otherwise a multi-chapter
        // comic would download `chapter/null`. A genuinely single-chapter
        // comic keeps `chapters == null` and falls through to the path below.
        _message = "Fetching comic info...".tl;
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicInfo!(comicId);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) return;
        if (res.error) {
          _setError("Error: ${res.errorMessage}");
          return;
        }
        comic = res.data;
        await LocalManager().saveCurrentDownloadingTasks();
      }
      if (comic!.chapters == null) {
        _message = "Fetching image list...".tl;
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        _images = {};
        _totalCount = 0;
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks();
    }

    if (comic!.chapters != null) {
      var chapterKeys = comic!.chapters!.allChapters.keys
          .where((i) => chapters == null || chapters!.contains(i))
          .toList();
      _totalChapters = chapterKeys.length;
      var prefetchCount = 3;
      var chapterDelay = Duration.zero;
      var consecutiveFast = 0;
      const throttleThreshold = Duration(seconds: 20);
      var prefetchFutures = <String, Future<Res<List<String>>>>{};
      var prefetchStartTimes = <String, DateTime>{};

      void startPrefetch(int fromIndex) {
        for (var p = fromIndex;
            p < (fromIndex + prefetchCount).clamp(0, chapterKeys.length);
            p++) {
          var key = chapterKeys[p];
          if (_images![key] != null || prefetchFutures.containsKey(key)) {
            continue;
          }
          prefetchStartTimes[key] = DateTime.now();
          prefetchFutures[key] = _runWithRetry(() async {
            var r = await source.loadComicPages!(comicId, key);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
        }
      }

      for (var ci = _chapter; ci < chapterKeys.length; ci++) {
        if (!_isRunning) return;
        var key = chapterKeys[ci];

        startPrefetch(ci);

        if (_images![key] == null) {
          _message = "Fetching image list (@a/@b)".tlParams({
            "a": ci + 1,
            "b": chapterKeys.length,
          });
          notifyListeners();

          if (chapterDelay > Duration.zero && ci > _chapter) {
            await Future.delayed(chapterDelay);
            if (!_isRunning) return;
          }

          var startTime = prefetchStartTimes.remove(key) ?? DateTime.now();
          var future = prefetchFutures.remove(key) ?? _runWithRetry(() async {
            var r = await source.loadComicPages!(comicId, key);
            if (r.error) {
              throw r.errorMessage!;
            } else {
              return r.data;
            }
          });
          var res = await future;
          var elapsed = DateTime.now().difference(startTime);
          if (!_isRunning) return;
          if (res.error) {
            Log.error("Download", res.errorMessage!);
            _setError("Error: ${res.errorMessage}");
            return;
          }

          if (elapsed > throttleThreshold) {
            prefetchCount = 0;
            chapterDelay = const Duration(seconds: 5);
            consecutiveFast = 0;
            prefetchFutures.clear();
            prefetchStartTimes.clear();
          } else {
            consecutiveFast++;
            if (consecutiveFast >= 3 && prefetchCount < 3) {
              prefetchCount = 3;
              chapterDelay = Duration.zero;
            }
          }

          _images![key] = res.data;
          _totalCount += res.data.length;
          await LocalManager().saveCurrentDownloadingTasks();
        }

        var images = _images![key]!;
        tasks.clear();
        final ok = await _downloadChapterPool(
          images,
          () => "Ep.@a @b/@c".tlParams({
            "a": ci + 1,
            "b": _index,
            "c": images.length,
          }),
        );
        if (!ok) return;
        _index = 0;
        _chapter++;
      }
    } else {
      while (_chapter < _images!.length) {
        var images = _images![_images!.keys.elementAt(_chapter)]!;
        tasks.clear();
        final ok = await _downloadChapterPool(
          images,
          () => "$_downloadedCount/$_totalCount",
        );
        if (!ok) return;
        _index = 0;
        _chapter++;
      }
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    // Per-second image throughput as an EMA, smoothing out the bursty nature of
    // image completions so the ETA doesn't swing wildly (#12).
    final delta = _downloadedCount - _lastDownloadedCount;
    _lastDownloadedCount = _downloadedCount;
    if (delta >= 0) {
      _imagesPerSecond = _imagesPerSecond == 0
          ? delta.toDouble()
          : _imagesPerSecond * 0.6 + delta * 0.4;
    }
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
    LocalManager().onTaskError(this);
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "totalCount": _totalCount,
      "totalChapters": _totalChapters,
      "index": _index,
      "chapter": _chapter,
      "wasRunning": _isRunning,
      "userPaused": userPaused,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
      source: ComicSource.find(json["source"])!,
      comicId: json["comicId"],
      comic:
          json["comic"] == null ? null : ComicDetails.fromJson(json["comic"]),
      chapters: ListOrNull.from(json["chapters"]),
    )
      ..path = json["path"]
      ..wasRunning = json["wasRunning"] ?? false
      ..userPaused = json["userPaused"] ?? false
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"] ?? 0
      .._totalCount = json["totalCount"] ?? 0
      .._totalChapters = json["totalChapters"] ?? 0
      .._index = json["index"] ?? 0
      .._chapter = json["chapter"] ?? 0;
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: id,
      title: title,
      subtitle: comic?.subTitle ?? '',
      tags: comic?.tags.entries.expand((e) {
            return e.value.map((v) => "${e.key}:$v");
          }).toList() ??
          [],
      directory: path == null ? '' : Directory(path!).name,
      chapters: comic?.chapters,
      cover: _cover == null ? '' : File(_cover!.split("file://").last).name,
      comicType: comicType,
      downloadedChapters: chapters ?? comic?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

Future<Res<T>> _runWithRetry<T>(Future<T> Function() task,
    {int retry = 3}) async {
  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  /// Complete every pending waiter. Critically also called on the cancelled
  /// path: otherwise `await wait()` in the download loop and in cancel()'s
  /// cleanup would hang forever on a cancelled image (B1).
  void _notifyWaiters() {
    for (var c in completers) {
      if (!c.isCompleted) {
        c.complete(this);
      }
    }
    completers.clear();
  }

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
          image, task.source.key, task.comicId, chapter,
          forDownload: true)) {
        if (isCancelled) {
          _notifyWaiters();
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          var fileType = detectFileType(p.imageBytes!);
          // Reject obvious garbage before saving it as a "page": a source can
          // answer 200 with an HTML error page, a truncated body, or an empty
          // response. detectFileType reports image/* only for real image magic
          // bytes, so a non-image mime (or a suspiciously tiny body) is treated
          // as a failure and retried instead of silently storing a broken page
          // that would surface as a corrupt image offline (#14).
          if (!fileType.mime.startsWith('image/') ||
              p.imageBytes!.length < 100) {
            throw "Invalid image data (${p.imageBytes!.length} bytes, "
                "${fileType.mime})";
          }
          var file = saveTo.joinFile("$index${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
          isComplete = true;
          _notifyWaiters();
        }
      }
    } catch (e, s) {
      if (isCancelled) {
        _notifyWaiters();
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        // Exponential-ish backoff (1s, 2s) instead of hammering immediately.
        await Future.delayed(Duration(seconds: 3 - retry));
        if (isCancelled) {
          _notifyWaiters();
          return;
        }
        start();
        return;
      }
      error = e.toString();
      _notifyWaiters();
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete || isCancelled) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  /// Per-task temp path for the archive being downloaded. Keyed by source +
  /// comic so a different archive download can't reuse a leftover partial file
  /// (which would corrupt it). The matching `$path.download` status file lets
  /// [FileDownloader] resume after an interrupted run.
  String get _archiveTempPath => FilePath.join(
        App.dataPath,
        "archive_${source.key.hashCode}_${comic.id.hashCode}.zip",
      );

  String _message = "Fetching comic info...".tl;

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
    LocalManager().onTaskError(this);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    // Drop the partial archive + its resume status so a cancelled task leaves
    // nothing behind. (Pause/app-kill keep them so the download can resume.)
    File(_archiveTempPath).deleteIgnoreError();
    File("$_archiveTempPath.download").deleteIgnoreError();
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    _message = "Paused".tl;
    _downloader?.stop();
    notifyListeners();
    LocalManager().saveCurrentDownloadingTasks();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  Duration? get eta {
    if (isPaused || isError || _speed <= 0 || _expectedBytes <= 0) return null;
    final remaining = _expectedBytes - _currentBytes;
    if (remaining <= 0) return null;
    return Duration(seconds: (remaining / _speed).ceil());
  }

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...".tl;
    LocalManager().saveCurrentDownloadingTasks();

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    var archiveFile = File(_archiveTempPath);

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
      "wasRunning": _isRunning,
      "userPaused": userPaused,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )
      ..path = json["path"]
      ..wasRunning = json["wasRunning"] ?? false
      ..userPaused = json["userPaused"] ?? false;
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    // An empty archive (or one that extracted nothing) would crash on
    // `files.first`; return no cover instead (B14).
    if (files.isEmpty) {
      return '';
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}

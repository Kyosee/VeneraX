import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'appdata.dart';
import 'comic_collection_store.dart';
import 'comic_cover_store.dart';
import 'comic_source/comic_source.dart';
import 'comic_state_repository.dart';
import 'comic_type.dart';
import 'favorites.dart';
import 'follow_update_scope.dart';
import 'follow_update_result.dart';
import 'follow_update_tasks.dart';
import 'history.dart';
import 'image_provider/base_image_provider.dart';
import 'image_provider/comic_image_codec.dart';
import 'local.dart';
import 'log.dart';

const readingWidgetHistoryUri = 'venerax://reading-widget/history';
const readingWidgetChannel = MethodChannel('venera/reading_widget');

enum ReadingWidgetKind { history, following, updates, local }

ComicType readingWidgetComicType(Comic comic) => switch (comic) {
  History() => comic.type,
  FavoriteItem() => comic.type,
  LocalComic() => comic.comicType,
  _ => ComicType.fromKey(comic.sourceKey),
};

String readingWidgetComicUri(
  Comic comic, [
  ReadingWidgetKind kind = ReadingWidgetKind.history,
]) => Uri(
  scheme: 'venerax',
  host: 'reading-widget',
  path: kind == ReadingWidgetKind.history ? '/read' : '/${kind.name}/read',
  queryParameters: {
    'id': comic.id,
    'type': '${readingWidgetComicType(comic).value}',
  },
).toString();

/// History lacks tags; enrich it from local metadata before exposing it outside
/// the app. Unknown tags stay private when a tag filter is configured.
bool isReadingWidgetHistoryVisible(Comic history) {
  try {
    if (isBlocked(history) != null) return false;
    final repository = const ComicStateRepository();
    final state = repository.load(history.sourceKey, history.id);
    if (state.localComic == null &&
        readingWidgetComicType(history).comicSource == null) {
      return false;
    }
    final info = repository.displayInfoFor(history);
    final blockedTags = appdata.settings['blockedTags'] as List;
    if (blockedTags.isNotEmpty && info.tags.isEmpty) return false;
    return isBlocked(
          Comic(
            history.title,
            '',
            history.id,
            history.subtitle,
            info.tags,
            info.description ?? '',
            history.sourceKey,
            null,
            null,
          ),
        ) ==
        null;
  } catch (_) {
    return false;
  }
}

List<FavoriteItemWithUpdateInfo> readingWidgetFollowedComics() {
  final items = App.favorites.getComicsWithUpdatesInfoIn(
    FollowUpdateScope.folders(),
  );
  items.sort((a, b) {
    final unread =
        (b.hasNewUpdate == true ? 1 : 0) - (a.hasNewUpdate == true ? 1 : 0);
    if (unread != 0) return unread;
    final updated = (b.updateTime ?? '').compareTo(a.updateTime ?? '');
    return updated != 0 ? updated : b.time.compareTo(a.time);
  });
  return items;
}

Future<List<LocalComic>> readingWidgetLocalComics() async {
  if (!App.local.isInitialized) return [];
  final sort = App.local.sortType;
  var comics = App.local.getComics(
    sort.isSize || sort == LocalSortType.lastRead
        ? LocalSortType.defaultSort
        : sort,
  );
  if (sort.isSize) {
    comics = await sortLocalComicsBySize(
      comics,
      descending: sort == LocalSortType.sizeDesc,
    );
  }
  final readAt = [
    for (final comic in comics)
      App.history.isInitialized
          ? App.history
                    .find(comic.id, comic.comicType)
                    ?.time
                    .millisecondsSinceEpoch ??
                0
          : 0,
  ];
  final indexes = List.generate(comics.length, (index) => index)
    ..sort((a, b) {
      final byReading = readAt[b].compareTo(readAt[a]);
      return byReading != 0 ? byReading : a.compareTo(b);
    });
  return [for (final index in indexes) comics[index]];
}

/// Publishes a small native snapshot; no source credentials or remote URLs leave
/// Dart. Each refresh invalidates older thumbnail work before it can publish.
class ReadingWidgetService with WidgetsBindingObserver {
  ReadingWidgetService({
    List<Comic> Function()? recent,
    List<FavoriteItemWithUpdateInfo> Function()? following,
    FutureOr<List<LocalComic>> Function()? local,
    FollowUpdateResult? Function()? lastCheck,
    bool Function(Comic)? visible,
    this.coverBytes,
  }) : _recent = recent ?? (() => HistoryManager().getRecent()),
       _following = following ?? readingWidgetFollowedComics,
       _local = local ?? readingWidgetLocalComics,
       _lastCheck = lastCheck ?? (() => FollowUpdateResult.latest),
       _visible = visible ?? isReadingWidgetHistoryVisible;

  static final instance = ReadingWidgetService();
  final List<Comic> Function() _recent;
  final List<FavoriteItemWithUpdateInfo> Function() _following;
  final FutureOr<List<LocalComic>> Function() _local;
  final FollowUpdateResult? Function() _lastCheck;
  final bool Function(Comic) _visible;
  final Future<Uint8List> Function(Comic)? coverBytes;
  final Map<String, String> _covers = {};
  bool _coversRestored = false;
  Timer? _timer;
  int _revision = 0;
  bool _started = false;

  /// The app is in front, so the home screen and its cards are out of sight.
  bool _foreground = true;

  /// Data changed since the cards were last published.
  bool _stale = false;

  /// The lock state the cards last showed; null before the first publish.
  bool? _publishedLocked;

  void start() {
    if (_started ||
        App.isBackgroundTask ||
        !(App.isAndroid || App.isOhos || App.isIOS || App.isMacOS)) {
      return;
    }
    _started = true;
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    HistoryManager().addListener(onDataChanged);
    App.local.addListener(onDataChanged);
    App.favorites.addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    appdata.settings.addListener(onDataChanged);
    appdata.addListener(onDataChanged);
    DataSync().addListener(onDataChanged);
    FollowUpdateTaskManager.instance.addListener(onDataChanged);
    WidgetsBinding.instance.addObserver(this);
    onDataChanged();
  }

  /// While the app is in front a change only marks the cards out of date;
  /// they are published once the app leaves the screen. A refresh after every
  /// page turn, upload and settings save held the UI thread (#352, #355).
  /// Locking or unlocking is published at once.
  @visibleForTesting
  void onDataChanged() {
    final locked = appdata.settings['authorizationRequired'] == true;
    if (locked ? _publishedLocked != true : _publishedLocked == true) {
      _timer?.cancel();
      unawaited(refresh());
      return;
    }
    // Locked cards show nothing that could change.
    if (locked) return;
    _stale = true;
    if (_foreground) return;
    ++_revision;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(refresh()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _timer?.cancel();
    if (_foreground || !_stale) return;
    unawaited(refresh());
  }

  Future<void> refresh({
    List<ReadingWidgetKind> kinds = ReadingWidgetKind.values,
    bool loadCovers = true,
  }) async {
    final revision = ++_revision;
    try {
      final locked = appdata.settings['authorizationRequired'] == true;
      _publishedLocked = locked;
      if (ReadingWidgetKind.values.every(kinds.contains)) _stale = false;
      // Started first: the folder check runs while the other kinds publish.
      final localCheck = locked || !kinds.contains(ReadingWidgetKind.local)
          ? null
          : (_readableLocal(revision)..ignore());
      if (!locked) _restoreCovers();
      final followed =
          locked ||
              !kinds.any(
                (kind) =>
                    kind == ReadingWidgetKind.following ||
                    kind == ReadingWidgetKind.updates,
              )
          ? <FavoriteItemWithUpdateInfo>[]
          : _following();
      final lastCheck = locked || !kinds.contains(ReadingWidgetKind.updates)
          ? null
          : _lastCheck();
      final collections =
          <ReadingWidgetKind, List<Comic>>{
            ReadingWidgetKind.history:
                locked || !kinds.contains(ReadingWidgetKind.history)
                ? []
                : _recent(),
            ReadingWidgetKind.following: followed
                .where((item) => item.hasNewUpdate == true)
                .toList(),
            ReadingWidgetKind.updates: followed
                .where(
                  (item) =>
                      lastCheck?.updatedKeys?.contains(item.identityKey) ==
                      true,
                )
                .toList(),
            ReadingWidgetKind.local: const [],
          }.map(
            (kind, comics) =>
                MapEntry(kind, comics.where(_visible).take(6).toList()),
          );
      final checked = followed.fold<int>(
        0,
        (latest, item) => math.max(latest, item.lastCheckTime ?? 0),
      );
      String checkText(int checked) => checked == 0
          ? 'Not checked yet'.tl
          : 'Last checked: @t'.tlParams({
              't': DateTime.fromMillisecondsSinceEpoch(
                checked,
              ).toIso8601String().replaceFirst('T', ' ').substring(0, 16),
            });
      final snapshots = <ReadingWidgetKind, Map<String, Object>>{};
      for (final kind in kinds) {
        if (kind == ReadingWidgetKind.local && localCheck != null) {
          final local = await localCheck;
          if (local == null || revision != _revision) return;
          collections[kind] = local.where(_visible).take(6).toList();
        }
        final comics = collections[kind]!;
        final snapshot = <String, Object>{
          'kind': kind.name,
          'locked': locked,
          'title': switch (kind) {
            ReadingWidgetKind.history => 'Recent reading'.tl,
            ReadingWidgetKind.following => 'Follow Updates'.tl,
            ReadingWidgetKind.updates => 'Latest check'.tl,
            ReadingWidgetKind.local => 'Local comics'.tl,
          },
          'subtitle':
              !locked &&
                  (kind == ReadingWidgetKind.following ||
                      kind == ReadingWidgetKind.updates)
              ? checkText(
                  kind == ReadingWidgetKind.updates
                      ? lastCheck?.checkedAt.millisecondsSinceEpoch ?? 0
                      : checked,
                )
              : '',
          'emptyText': locked
              ? 'Open VeneraX to view comics'.tl
              : switch (kind) {
                  ReadingWidgetKind.history =>
                    'Read a comic to keep your place here.'.tl,
                  ReadingWidgetKind.following =>
                    'No unread updates. Open your follow list to check.'.tl,
                  ReadingWidgetKind.updates =>
                    lastCheck?.updatedKeys == null
                        ? 'Run a check to see its results here.'.tl
                        : lastCheck!.failed > 0
                        ? 'Some comics could not be checked. Open your follow list to retry.'
                              .tl
                        : lastCheck.updatedKeys!.isEmpty
                        ? 'The latest check found no updates.'.tl
                        : 'No updates to show from the latest check.'.tl,
                  ReadingWidgetKind.local =>
                    'Import or download comics to read them here.'.tl,
                },
          'items': comics
              .map(
                (comic) => <String, Object>{
                  'id': comic.id,
                  'type': readingWidgetComicType(comic).value,
                  'title': comic.title,
                  'progress': _progress(comic),
                  'sourceName':
                      readingWidgetComicType(comic).comicSource?.name ??
                      'On this device'.tl,
                  'badge':
                      comic is FavoriteItemWithUpdateInfo &&
                          comic.hasNewUpdate == true
                      ? 'New updates'.tl
                      : '',
                  'pageProgress': _pageProgress(comic),
                  'coverPath': _covers[_coverKey(comic)] ?? '',
                  'uri': readingWidgetComicUri(comic, kind),
                },
              )
              .toList(),
        };
        snapshots[kind] = snapshot;
        // Clear all four kinds before waiting for any cover downloads.
        await readingWidgetChannel.invokeMethod<void>(
          'update',
          jsonEncode(snapshot),
        );
        if (revision != _revision) return;
      }
      for (final kind in loadCovers ? kinds : <ReadingWidgetKind>[]) {
        final comics = collections[kind]!;
        if (comics.isEmpty) continue;
        final active =
            await readingWidgetChannel.invokeMethod<bool>(
              'hasWidgets',
              kind.name,
            ) ??
            false;
        if (revision != _revision) return;
        // Warm a compact preview so the first added card already has covers.
        final count = active ? comics.length : math.min(2, comics.length);
        final snapshot = snapshots[kind]!;
        final items = snapshot['items']! as List<Map<String, Object>>;
        var changed = false;
        for (var i = 0; i < count; i++) {
          if (revision != _revision) return;
          final comic = comics[i];
          final key = _coverKey(comic);
          var path = _covers[key];
          if (path == null || !File(path).existsSync()) {
            final originalCover = comic.cover;
            _covers.remove(key);
            path = await _thumbnail(comic, revision);
            if (revision != _revision) return;
            // Loading online history can resolve and replace its cover URL.
            if (path.isNotEmpty) {
              final resolvedKey = comic.cover == originalCover ? key : _coverKey(comic);
              _covers[resolvedKey] = path;
            }
          }
          if (items[i]['coverPath'] != path) {
            items[i]['coverPath'] = path;
            changed = true;
          }
          // The compact card only shows the first cover. Publish it before
          // slower requests can be suspended when the app goes to background.
          if (changed && (i == 0 || i == count - 1)) {
            _saveCovers();
            await readingWidgetChannel.invokeMethod<void>(
              'update',
              jsonEncode(snapshot),
            );
            if (revision != _revision) return;
            changed = false;
          }
        }
      }
      if (ReadingWidgetKind.values.every(kinds.contains)) {
        _pruneCovers(collections.values.expand((items) => items));
      }
    } on MissingPluginException {
      // Desktop and older platform hosts have no home-screen widget bridge.
    } catch (_) {
      _stale = true;
      Log.warning('Reading widget', 'Unable to update reading widgets.');
    }
  }

  Future<List<LocalComic>>? _localCheck;

  /// Local comics whose folders still hold pages, or null once a newer refresh
  /// took over. One check at a time: refreshes come in bursts (resume,
  /// follow-update progress) and every check lists each folder.
  Future<List<LocalComic>?> _readableLocal(int revision) async {
    while (_localCheck != null) {
      await _localCheck!.then((_) {}, onError: (_) {});
      if (revision != _revision) return null;
    }
    final check = _localCheck = () async {
      final comics = (await _local()).where(_visible).toList();
      final readable = <LocalComic>[];
      // Stop after filling the snapshot; a large library need not be scanned.
      for (
        var start = 0;
        start < comics.length && readable.length < 6;
        start += 20
      ) {
        if (revision != _revision) break;
        final batch = comics.sublist(
          start,
          math.min(start + 20, comics.length),
        );
        final statuses = await loadLocalComicStatuses(batch);
        for (var i = 0; i < batch.length; i++) {
          if (statuses[i] != LocalComicStatus.notDownloaded) {
            readable.add(batch[i]);
          }
        }
      }
      return readable;
    }();
    try {
      return await check;
    } finally {
      if (identical(_localCheck, check)) _localCheck = null;
    }
  }

  String _progress(Comic comic) {
    if (comic is FavoriteItemWithUpdateInfo) {
      return comic.updateTime?.isNotEmpty == true
          ? comic.updateTime!
          : (comic.hasNewUpdate == true
                ? 'New updates'.tl
                : 'No new updates'.tl);
    }
    final history = _history(comic);
    if (history == null) return 'Start reading'.tl;
    final progress = (history.maxPage ?? 0) > 0
        ? 'Ch. @chapter · @page/@total'.tlParams({
            'chapter': math.max(1, history.ep),
            'page': history.page.clamp(1, history.maxPage!),
            'total': history.maxPage!,
          })
        : 'Ch. @chapter · p. @page'.tlParams({
            'chapter': math.max(1, history.ep),
            'page': math.max(1, history.page),
          });
    return (history.group ?? 1) > 1
        ? '${'Group @group'.tlParams({'group': history.group!})} · $progress'
        : progress;
  }

  History? _history(Comic comic) => comic is History
      ? comic
      : App.history.isInitialized
      ? App.history.find(comic.id, readingWidgetComicType(comic))
      : null;

  int _pageProgress(Comic comic) {
    if (comic is FavoriteItemWithUpdateInfo) return -1;
    final history = _history(comic);
    final total = history?.maxPage ?? 0;
    if (history == null || total <= 0) return -1;
    return (history.page / total * 100).round().clamp(0, 100);
  }

  String _coverKey(Comic comic) =>
      jsonEncode([
        readingWidgetComicType(comic).value,
        comic.id,
        ComicCoverStore.reference(comic.sourceKey, comic.id) ??
            (ComicCollectionStore.isCollectionSourceKey(comic.sourceKey)
                ? ComicCollectionStore.find(comic.id)?.displayCover
                : null) ??
            comic.cover,
      ]);

  Directory get _directory =>
      Directory(FilePath.join(App.dataPath, 'reading_widget_covers'));

  String get _coverIndex =>
      FilePath.join(App.dataPath, 'reading_widget_covers.json');

  void _restoreCovers() {
    if (_coversRestored) return;
    _coversRestored = true;
    try {
      final saved =
          jsonDecode(File(_coverIndex).readAsStringSync())
              as Map<String, dynamic>;
      final prefix = '${_directory.path}${Platform.pathSeparator}';
      for (final entry in saved.entries) {
        final path = entry.value;
        if (path is String &&
            path.startsWith(prefix) &&
            RegExp(
              r'^[a-zA-Z0-9-]+\.png$',
            ).hasMatch(path.substring(prefix.length)) &&
            File(path).existsSync()) {
          _covers[entry.key] = path;
        }
      }
    } catch (_) {
      // Missing or damaged thumbnails can be regenerated while the app is open.
    }
  }

  void _saveCovers() => writeStringAtomicSync(_coverIndex, jsonEncode(_covers));

  void _pruneCovers(Iterable<Comic> histories) {
    final retained = histories.map(_coverKey).toSet();
    _covers.removeWhere((key, _) => !retained.contains(key));
    _saveCovers();
    _removeUnusedCovers();
  }

  Future<String> _thumbnail(Comic comic, int revision) async {
    final chunks = StreamController<ImageChunkEvent>();
    try {
      void checkCurrent() {
        if (revision != _revision) {
          throw StateError('Widget refresh superseded');
        }
      }

      final provider = coverBytes == null ? findImageProvider(comic) : null;
      if (coverBytes == null && provider is! BaseImageProvider) return '';
      final bytes =
          await (coverBytes?.call(comic) ??
                  (provider! as BaseImageProvider).load(chunks, checkCurrent))
              .timeout(const Duration(seconds: 8));
      checkCurrent();
      ui.Codec? codec;
      ui.Image? image;
      try {
        codec = await decodeComicImage(
          bytes,
          getTargetSize: (width, height) {
            final scale = math.min(1.0, math.min(240 / width, 320 / height));
            return ui.TargetImageSize(
              width: math.max(1, (width * scale).round()),
              height: math.max(1, (height * scale).round()),
            );
          },
        );
        image = (await codec.getNextFrame()).image;
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        checkCurrent();
        if (png == null) return '';
        final directory = _directory..createSync(recursive: true);
        final file = File(
          FilePath.join(directory.path, '${const Uuid().v4()}.png'),
        );
        file.writeAsBytesSync(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
        return file.path;
      } finally {
        image?.dispose();
        codec?.dispose();
      }
    } catch (_) {
      return '';
    } finally {
      unawaited(chunks.close());
    }
  }

  void _removeUnusedCovers() {
    try {
      if (!_directory.existsSync()) return;
      final retained = _covers.values.toSet();
      for (final file in _directory.listSync().whereType<File>()) {
        if (!retained.contains(file.path)) file.deleteSync();
      }
    } catch (_) {
      // Thumbnail cleanup must not interrupt reading or navigation.
    }
  }
}

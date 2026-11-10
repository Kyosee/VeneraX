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
import 'comic_source/comic_source.dart';
import 'comic_state_repository.dart';
import 'comic_type.dart';
import 'favorites.dart';
import 'follow_update_scope.dart';
import 'follow_update_tasks.dart';
import 'history.dart';
import 'image_provider/base_image_provider.dart';
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

/// Publishes a small native snapshot; no source credentials or remote URLs leave
/// Dart. Each refresh invalidates older thumbnail work before it can publish.
class ReadingWidgetService with WidgetsBindingObserver {
  ReadingWidgetService({
    List<Comic> Function()? recent,
    List<FavoriteItemWithUpdateInfo> Function()? following,
    List<LocalComic> Function()? local,
    bool Function(Comic)? visible,
    this.coverBytes,
  }) : _recent = recent ?? (() => HistoryManager().getRecent()),
       _following = following ?? readingWidgetFollowedComics,
       _local =
           local ??
           (() => App.local.isInitialized ? App.local.getRecent() : []),
       _visible = visible ?? isReadingWidgetHistoryVisible;

  static final instance = ReadingWidgetService();
  final List<Comic> Function() _recent;
  final List<FavoriteItemWithUpdateInfo> Function() _following;
  final List<LocalComic> Function() _local;
  final bool Function(Comic) _visible;
  final Future<Uint8List> Function(Comic)? coverBytes;
  final Map<String, String> _covers = {};
  bool _coversRestored = false;
  Timer? _timer;
  int _revision = 0;
  bool _started = false;

  void start() {
    if (_started ||
        App.isBackgroundTask ||
        !(App.isAndroid || App.isOhos || App.isIOS || App.isMacOS)) {
      return;
    }
    _started = true;
    HistoryManager().addListener(_schedule);
    App.local.addListener(_schedule);
    App.favorites.addListener(_schedule);
    ComicSourceManager().addListener(_schedule);
    appdata.settings.addListener(_schedule);
    appdata.addListener(_schedule);
    DataSync().addListener(_schedule);
    FollowUpdateTaskManager.instance.addListener(_schedule);
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  void _schedule() {
    ++_revision;
    _timer?.cancel();
    if (appdata.settings['authorizationRequired'] == true) {
      unawaited(refresh());
    } else {
      _timer = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(refresh()),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _timer?.cancel();
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      unawaited(refresh());
    }
  }

  Future<void> refresh({
    List<ReadingWidgetKind> kinds = ReadingWidgetKind.values,
    bool loadCovers = true,
  }) async {
    final revision = ++_revision;
    try {
      final locked = appdata.settings['authorizationRequired'] == true;
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
      final collections =
          <ReadingWidgetKind, List<Comic>>{
            ReadingWidgetKind.history:
                locked || !kinds.contains(ReadingWidgetKind.history)
                ? []
                : _recent(),
            ReadingWidgetKind.following: followed,
            ReadingWidgetKind.updates: followed
                .where((item) => item.hasNewUpdate == true)
                .toList(),
            ReadingWidgetKind.local:
                locked || !kinds.contains(ReadingWidgetKind.local)
                ? []
                : _local()
                      .where(
                        (item) => item.status != LocalComicStatus.notDownloaded,
                      )
                      .toList(),
          }.map(
            (kind, comics) =>
                MapEntry(kind, comics.where(_visible).take(6).toList()),
          );
      final checked = followed.fold<int>(
        0,
        (latest, item) => math.max(latest, item.lastCheckTime ?? 0),
      );
      final checkText = checked == 0
          ? 'Not checked yet'.tl
          : 'Last checked: @t'.tlParams({
              't': DateTime.fromMillisecondsSinceEpoch(
                checked,
              ).toIso8601String().replaceFirst('T', ' ').substring(0, 16),
            });
      final snapshots = <ReadingWidgetKind, Map<String, Object>>{};
      for (final kind in kinds) {
        final comics = collections[kind]!;
        final snapshot = <String, Object>{
          'kind': kind.name,
          'locked': locked,
          'title': switch (kind) {
            ReadingWidgetKind.history => 'Recent reading'.tl,
            ReadingWidgetKind.following => 'Follow Updates'.tl,
            ReadingWidgetKind.updates => 'New updates'.tl,
            ReadingWidgetKind.local => 'Local comics'.tl,
          },
          'subtitle':
              !locked &&
                  (kind == ReadingWidgetKind.following ||
                      kind == ReadingWidgetKind.updates)
              ? checkText
              : '',
          'emptyText': locked
              ? 'Open VeneraX to view comics'.tl
              : switch (kind) {
                  ReadingWidgetKind.history =>
                    'Read a comic to keep your place here.'.tl,
                  ReadingWidgetKind.following =>
                    'Add favorites to your follow list to see them here.'.tl,
                  ReadingWidgetKind.updates =>
                    'No new updates. Open your follow list to check.'.tl,
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
        for (var i = 0; i < count; i++) {
          if (revision != _revision) return;
          final comic = comics[i];
          final key = _coverKey(comic);
          var path = _covers[key];
          if (path == null || !File(path).existsSync()) {
            path = await _thumbnail(comic, revision);
            if (revision != _revision) return;
            if (path.isNotEmpty) _covers[key] = path;
          }
          items[i]['coverPath'] = path;
        }
        await readingWidgetChannel.invokeMethod<void>(
          'update',
          jsonEncode(snapshot),
        );
        if (revision != _revision) return;
      }
      if (ReadingWidgetKind.values.every(kinds.contains)) {
        _pruneCovers(collections.values.expand((items) => items));
      }
    } on MissingPluginException {
      // Desktop and older platform hosts have no home-screen widget bridge.
    } catch (_) {
      Log.warning('Reading widget', 'Unable to update reading widgets.');
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
      jsonEncode([readingWidgetComicType(comic).value, comic.id, comic.cover]);

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
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      ui.Image? image;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        final scale = math.min(
          1.0,
          math.min(240 / descriptor.width, 320 / descriptor.height),
        );
        codec = await descriptor.instantiateCodec(
          targetWidth: math.max(1, (descriptor.width * scale).round()),
          targetHeight: math.max(1, (descriptor.height * scale).round()),
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
        descriptor?.dispose();
        buffer.dispose();
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

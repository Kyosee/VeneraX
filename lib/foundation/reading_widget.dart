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
import 'history.dart';
import 'image_provider/history_image_provider.dart';
import 'log.dart';

const readingWidgetHistoryUri = 'venerax://reading-widget/history';
const readingWidgetChannel = MethodChannel('venera/reading_widget');

String readingWidgetComicUri(History history) => Uri(
  scheme: 'venerax',
  host: 'reading-widget',
  path: '/read',
  queryParameters: {'id': history.id, 'type': '${history.type.value}'},
).toString();

/// History lacks tags; enrich it from local metadata before exposing it outside
/// the app. Unknown tags stay private when a tag filter is configured.
bool isReadingWidgetHistoryVisible(History history) {
  try {
    if (isBlocked(history) != null) return false;
    final repository = const ComicStateRepository();
    final state = repository.load(history.sourceKey, history.id);
    if (state.localComic == null && history.type.comicSource == null) {
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

/// Publishes a small native snapshot; no source credentials or remote URLs leave
/// Dart. Each refresh invalidates older thumbnail work before it can publish.
class ReadingWidgetService with WidgetsBindingObserver {
  ReadingWidgetService({
    List<History> Function()? recent,
    bool Function(History)? visible,
    this.coverBytes,
  }) : _recent = recent ?? (() => HistoryManager().getRecent()),
       _visible = visible ?? isReadingWidgetHistoryVisible;

  static final instance = ReadingWidgetService();
  final List<History> Function() _recent;
  final bool Function(History) _visible;
  final Future<Uint8List> Function(History)? coverBytes;
  final Map<String, String> _covers = {};
  bool _coversRestored = false;
  Timer? _timer;
  int _revision = 0;
  bool _started = false;

  void start() {
    if (_started || App.isBackgroundTask || !(App.isAndroid || App.isOhos)) {
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

  Future<void> refresh() async {
    final revision = ++_revision;
    try {
      final locked = appdata.settings['authorizationRequired'] == true;
      if (!locked) _restoreCovers();
      final histories = locked
          ? <History>[]
          : _recent().where(_visible).take(6).toList();
      final items = histories
          .map(
            (history) => <String, Object>{
              'id': history.id,
              'type': history.type.value,
              'title': history.title,
              'progress': history.description,
              'coverPath': _covers[_coverKey(history)] ?? '',
              'uri': readingWidgetComicUri(history),
            },
          )
          .toList();
      final snapshot = <String, Object>{
        'title': 'Recent reading'.tl,
        'emptyText':
            (locked
                    ? 'Open VeneraX to view reading history'
                    : 'No recent comics to show')
                .tl,
        'items': items,
      };
      // Publish removals and privacy changes before waiting for any image work.
      await readingWidgetChannel.invokeMethod<void>(
        'update',
        jsonEncode(snapshot),
      );
      if (revision != _revision) return;
      if (histories.isEmpty) {
        _covers.clear();
        _saveCovers();
        _removeUnusedCovers();
        return;
      }
      final active =
          await readingWidgetChannel.invokeMethod<bool>('hasWidgets') ?? false;
      if (revision != _revision) return;
      if (!active) {
        _pruneCovers(histories);
        return;
      }
      for (var i = 0; i < histories.length; i++) {
        if (revision != _revision) return;
        final history = histories[i];
        final key = _coverKey(history);
        var path = _covers[key];
        if (path == null || !File(path).existsSync()) {
          path = await _thumbnail(history, revision);
          if (revision != _revision) return;
          if (path.isNotEmpty) _covers[key] = path;
        }
        items[i]['coverPath'] = path;
      }
      if (revision != _revision) return;
      await readingWidgetChannel.invokeMethod<void>(
        'update',
        jsonEncode(snapshot),
      );
      if (revision != _revision) return;
      _pruneCovers(histories);
    } on MissingPluginException {
      // Desktop and older platform hosts have no home-screen widget bridge.
    } catch (_) {
      Log.warning('Reading widget', 'Unable to update reading widgets.');
    }
  }

  String _coverKey(History history) =>
      jsonEncode([history.type.value, history.id, history.cover]);

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

  void _pruneCovers(List<History> histories) {
    final retained = histories.map(_coverKey).toSet();
    _covers.removeWhere((key, _) => !retained.contains(key));
    _saveCovers();
    _removeUnusedCovers();
  }

  Future<String> _thumbnail(History history, int revision) async {
    final chunks = StreamController<ImageChunkEvent>();
    try {
      void checkCurrent() {
        if (revision != _revision) {
          throw StateError('Widget refresh superseded');
        }
      }

      final bytes =
          await (coverBytes?.call(history) ??
                  HistoryImageProvider(history).load(chunks, checkCurrent))
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

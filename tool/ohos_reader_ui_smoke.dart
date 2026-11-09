import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/export_tasks.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_enhance_shader.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/io.dart' show overrideIO;

import 'ohos_reader_smoke.dart' show runReaderProbe;

const _modes = [
  'galleryLeftToRight',
  'galleryRightToLeft',
  'galleryTopToBottom',
  'continuousTopToBottom',
  'continuousLeftToRight',
  'continuousRightToLeft',
];

void _log(String message) {
  for (final line in message.split('\n')) {
    debugPrint('OHOS_READER_UI: $line');
  }
}

String _position(History? history) => history == null
    ? 'none'
    : 'chapter=${history.ep} page=${history.page}/${history.maxPage} '
          'read=${history.readEpisode.join(",")}';

Future<void> _writePage(File file, int chapter, int page) async {
  if (await file.exists()) return;
  const width = 720;
  const height = 1280;
  const colors = [
    Color(0xffe7f1ff),
    Color(0xffffeadb),
    Color(0xffdff4e8),
    Color(0xfff1e4ff),
    Color(0xffffe1e8),
    Color(0xffe0f5f4),
  ];
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(colors[(chapter - 1) * 3 + page - 1], BlendMode.src);
  canvas.drawRect(
    const Rect.fromLTWH(24, 24, width - 48, height - 48),
    Paint()
      ..color = Colors.black87
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke,
  );
  void label(String text, double top, double size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.black,
          fontSize: size,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: width - 96);
    painter.paint(canvas, Offset((width - painter.width) / 2, top));
    painter.dispose();
  }

  label('VENERAX READER', 70, 48);
  label('CHAPTER $chapter', 190, 68);
  label('PAGE $page', 340, 120);
  label('Swipe / double tap / volume', 555, 30);
  for (var index = 0; index < 18; index++) {
    canvas.drawLine(
      Offset(80, 680 + index * 16),
      Offset(640, 680 + index * 16),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.15 + index * 0.045)
        ..strokeWidth = index % 3 + 1.0,
    );
  }
  for (var index = 0; index < 10; index++) {
    canvas.drawRect(
      Rect.fromLTWH(80 + index * 56, 1030, 56, 100),
      Paint()..color = index.isEven ? Colors.black : Colors.white,
    );
  }
  label('BOTTOM - C$chapter P$page', 1170, 32);
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(width, height);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) throw StateError('Fixture PNG encoding failed.');
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      flush: true,
    );
  } finally {
    image?.dispose();
    picture.dispose();
  }
}

Future<List<LocalComic>> _prepareComics() async {
  // runReaderProbe already redirected every opened manager to its sandbox.
  if (!App.domain.isInitialized) await App.domain.init(App.dataPath);
  if (!App.favorites.isInitialized) await App.favorites.init();
  if (!App.readLater.isInitialized) await App.readLater.init();
  if (!TranslationStore().isInitialized) await TranslationStore().init();

  final completed = int.parse(
    await File('${App.dataPath}/completed_runs').readAsString(),
  );
  final original = App.local.find(
    'probe_$completed',
    ComicType.fromKey('ohos_reader_probe'),
  );
  if (original == null) throw StateError('Downloaded probe comic missing.');
  // Independent history preserves the original probe's restart assertions.
  final downloaded = LocalComic(
    id: 'reader_ui_downloaded',
    title: 'Downloaded pipeline fixture',
    subtitle: original.subtitle,
    tags: original.tags,
    directory: original.directory,
    chapters: original.chapters,
    cover: original.cover,
    comicType: original.comicType,
    downloadedChapters: original.downloadedChapters,
    createdAt: original.createdAt,
  );
  await App.local.add(downloaded);

  final directory = Directory('${App.dataPath}/reader_ui_pages');
  for (var chapter = 1; chapter <= 2; chapter++) {
    final folder = Directory('${directory.path}/chapter_$chapter');
    await folder.create(recursive: true);
    for (var page = 1; page <= 3; page++) {
      await _writePage(File('${folder.path}/$page.png'), chapter, page);
    }
  }
  final visual = LocalComic(
    id: 'reader_ui_visual',
    title: 'Reader UI - 2 chapters / 6 pages',
    subtitle: 'Generated local fixture',
    tags: const ['probe'],
    directory: directory.path,
    chapters: const ComicChapters({
      'chapter_1': 'Chapter 1',
      'chapter_2': 'Chapter 2',
    }),
    cover: 'chapter_1/1.png',
    comicType: ComicType.local,
    downloadedChapters: const ['chapter_1', 'chapter_2'],
    createdAt:
        App.local.find('reader_ui_visual', ComicType.local)?.createdAt ??
        DateTime.now(),
  );
  await App.local.add(visual);
  _log('FIXTURES_READY downloaded=${downloaded.id} visual=${visual.id}');
  return [downloaded, visual];
}

Future<String> _checkShader(LocalComic visual) async {
  final manager = ImageEnhanceShader.instance;
  await manager.preload();
  if (!manager.isAvailable) {
    for (final item in Log.logs.where(
      (item) => item.title == 'ImageEnhanceShader',
    )) {
      _log('SHADER_LOAD_ERROR ${item.content}');
    }
    return 'SHADER_UNAVAILABLE';
  }
  _log('SHADER_LOAD_PASS');
  if (!manager.isEnabled) return 'SHADER_LOADED_DISABLED';

  ui.Codec? codec;
  ui.Image? source;
  ui.FragmentShader? shader;
  ui.Picture? picture;
  ui.Image? rendered;
  try {
    codec = await ui.instantiateImageCodec(
      await File('${visual.baseDir}/chapter_1/1.png').readAsBytes(),
    );
    source = (await codec.getNextFrame()).image;
    shader = manager.shaderFor(source);
    if (shader == null) throw StateError('Enabled shader was not created.');
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Paint()..shader = shader,
    );
    picture = recorder.endRecording();
    rendered = await picture.toImage(source.width, source.height);
    final bytes = await rendered.toByteData();
    final original = await source.toByteData();
    if (bytes == null ||
        original == null ||
        bytes.lengthInBytes != source.width * source.height * 4) {
      throw StateError('Shader output pixel readback failed.');
    }
    var changedPixels = 0;
    for (var offset = 0; offset < bytes.lengthInBytes; offset += 4) {
      if (bytes.getUint8(offset + 3) != original.getUint8(offset + 3)) {
        throw StateError('Shader changed the opaque fixture alpha.');
      }
      if (bytes.getUint8(offset) != original.getUint8(offset) ||
          bytes.getUint8(offset + 1) != original.getUint8(offset + 1) ||
          bytes.getUint8(offset + 2) != original.getUint8(offset + 2)) {
        changedPixels++;
      }
    }
    if (changedPixels == 0 || changedPixels == source.width * source.height) {
      throw StateError('Shader did not preserve flat areas and enhance edges.');
    }
    return 'SHADER_RENDER_PASS ${rendered.width}x${rendered.height} '
        'changedPixels=$changedPixels';
  } catch (error, stack) {
    _log('SHADER_RENDER_ERROR $error\n$stack');
    return 'SHADER_RENDER_FAIL $error';
  } finally {
    rendered?.dispose();
    picture?.dispose();
    shader?.dispose();
    source?.dispose();
    codec?.dispose();
  }
}

Future<void> main() => overrideIO(_run);

Future<void> _run() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _log(await runReaderProbe());
    final comics = await _prepareComics();
    runApp(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        navigatorObservers: [App.rootRouteObserver],
        debugShowCheckedModeBanner: false,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('zh', 'CN'),
          Locale('zh', 'TW'),
          Locale('en'),
        ],
        builder: (context, child) => OverlayWidget(child!),
        home: _ReaderProbeHome(comics: comics),
      ),
    );
  } catch (error, stack) {
    final message = 'SETUP_FAIL $error\n$stack';
    _log(message);
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(child: SingleChildScrollView(child: Text(message))),
        ),
      ),
    );
  }
}

class _ReaderProbeHome extends StatefulWidget {
  const _ReaderProbeHome({required this.comics});

  final List<LocalComic> comics;

  @override
  State<_ReaderProbeHome> createState() => _ReaderProbeHomeState();
}

class _ReaderProbeHomeState extends State<_ReaderProbeHome> {
  String _mode = _modes.first;
  bool _volume = true;
  bool _enhance = false;
  bool _busy = false;
  String _status = 'Ready. Uses the production Reader.';
  String _shaderStatus = 'Shader not checked';
  final Map<String, String> _lastPersisted = {};

  @override
  void initState() {
    super.initState();
    appdata.settings['enableReaderImageEnhance'] = false;
    appdata.settings['readerImageEnhanceStrength'] = 0.5;
    App.history.addListener(_onHistoryChanged);
    _onHistoryChanged();
    _log('READY');
  }

  void _onHistoryChanged() {
    for (final comic in widget.comics) {
      final value = _position(App.history.find(comic.id, comic.comicType));
      if (_lastPersisted[comic.id] != value) {
        _lastPersisted[comic.id] = value;
        _log('HISTORY_PERSISTED id=${comic.id} $value');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _shaderCheck() async {
    setState(() => _busy = true);
    final result = await _checkShader(widget.comics.last);
    _log(result);
    if (mounted) {
      setState(() {
        _shaderStatus = result;
        _busy = false;
      });
    }
  }

  Future<void> _open(LocalComic comic, {bool fromStart = false}) async {
    final settings = appdata.settings;
    settings.setEnabledComicSpecificSettings(
      comic.id,
      comic.comicType.sourceKey,
      true,
    );
    for (final entry in {
      'readerMode': _mode,
      'enableTurnPageByVolumeKey': _volume,
      'enableContinuousChapterReading': true,
    }.entries) {
      settings.setReaderSetting(
        comic.id,
        comic.comicType.sourceKey,
        entry.key,
        entry.value,
      );
    }
    final history =
        App.history.find(comic.id, comic.comicType) ??
        History.fromModel(model: comic, ep: 0, page: 0);
    _log(
      'OPEN id=${comic.id} mode=$_mode volume=$_volume shader=$_enhance '
      'fromStart=$fromStart saved=${_position(history)}',
    );
    await context.to(
      () => Reader(
        type: comic.comicType,
        cid: comic.id,
        name: comic.title,
        chapters: comic.chapters,
        history: history,
        initialChapter: fromStart ? 1 : history.ep,
        initialPage: fromStart ? 1 : history.page,
        author: comic.subtitle,
        tags: comic.tags,
      ),
    );
    _log('EXIT_STATE id=${comic.id} ${_position(history)}');
    // Let the production Reader finish its disposal and pending history write.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final persisted = _position(App.history.find(comic.id, comic.comicType));
    _log('EXIT_PERSISTED id=${comic.id} $persisted');
    if (mounted) setState(() => _status = 'Exited ${comic.id}: $persisted');
  }

  void _export(ExportFormat format, {bool merged = false}) {
    final manager = ExportTaskManager.instance;
    final task = manager.startExport(
      folderPath: '',
      format: format,
      comics: merged ? widget.comics : [widget.comics.last],
      merged: merged,
      saveWithDialog: true,
    );
    if (task == null) throw StateError('Another export is active.');
    void changed() {
      final status =
          'EXPORT ${format.name} merged=$merged '
          '${task.status.name} ${task.done}/${task.total} '
          'failed=${task.failedCount} ${task.phase.name} ${task.error ?? ""}';
      _log(status);
      if (mounted) {
        setState(() {
          _status = status;
          _busy = task.isActive;
        });
      }
      if (!task.isActive) manager.removeListener(changed);
    }

    manager.addListener(changed);
    changed();
  }

  @override
  void dispose() {
    App.history.removeListener(_onHistoryChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Reader UI probe')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _mode,
            decoration: const InputDecoration(
              labelText: 'Production reader mode',
            ),
            items: [
              for (final mode in _modes)
                DropdownMenuItem(value: mode, child: Text(mode)),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _mode = value);
            },
          ),
          SwitchListTile(
            title: const Text('Volume page turning'),
            value: _volume,
            onChanged: (value) => setState(() => _volume = value),
          ),
          SwitchListTile(
            title: const Text('Production image shader'),
            value: _enhance,
            onChanged: _busy
                ? null
                : (value) async {
                    setState(() => _enhance = value);
                    appdata.settings['enableReaderImageEnhance'] = value;
                    await _shaderCheck();
                  },
          ),
          Text(_shaderStatus),
          OutlinedButton(
            onPressed: _busy ? null : _shaderCheck,
            child: const Text('Check shader load / render'),
          ),
          FilledButton(
            onPressed: _busy
                ? null
                : () => _open(widget.comics.last, fromStart: true),
            child: const Text('Open visual comic at page 1'),
          ),
          FilledButton.tonal(
            onPressed: _busy ? null : () => _open(widget.comics.last),
            child: const Text('Resume visual comic'),
          ),
          OutlinedButton(
            onPressed: _busy ? null : () => _open(widget.comics.first),
            child: const Text('Open downloaded pipeline comic'),
          ),
          const SizedBox(height: 12),
          Text(_status),
          const SizedBox(height: 12),
          for (final comic in widget.comics)
            Text('${comic.id}: ${_lastPersisted[comic.id] ?? "none"}'),
          const Divider(),
          for (final format in ExportFormat.values)
            OutlinedButton(
              onPressed: _busy ? null : () => _export(format),
              child: Text('Export ${format.name} with system save'),
            ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => _export(ExportFormat.veneraComics, merged: true),
            child: const Text('Export merged venera_comics with system save'),
          ),
        ],
      ),
    ),
  );
}

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:venera/foundation/image_translation/hf_tokenizer.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/utils/io.dart';

/// Model file paths handed to the worker with each request; the worker has no
/// access to appdata/settings singletons.
class WorkerModelPaths {
  WorkerModelPaths({
    required this.detector,
    this.jaEncoder,
    this.jaDecoder,
    this.jaVocab,
    this.recModels = const {},
    this.recDicts = const {},
    this.recHeights = const {},
  });

  final String detector;
  final String? jaEncoder;
  final String? jaDecoder;
  final String? jaVocab;

  /// lang -> rec model path ('zh', 'en', 'ko').
  final Map<String, String> recModels;
  final Map<String, String> recDicts;
  final Map<String, int> recHeights;
}

class _OcrPageRequest {
  _OcrPageRequest(
    this.id,
    this.pixels,
    this.width,
    this.height,
    this.sourceLang,
    this.paths,
    this.intraThreads,
  );

  final int id;
  final TransferableTypedData pixels;
  final int width;
  final int height;

  /// 'auto' enables the vertical heuristic + fallback OCR chain.
  final String sourceLang;
  final WorkerModelPaths paths;
  final int intraThreads;
}

class _ReleaseRequest {
  const _ReleaseRequest();
}

class _WorkerResponse {
  _WorkerResponse(this.id, this.result, this.error);

  final int id;
  final Object? result;
  final String? error;
}

// ===========================================================================
// Main-isolate client
// ===========================================================================

/// Handle to the translation worker isolate. All heavy work — preprocessing,
/// ONNX inference (via the FFI binding), decoding loops — runs inside the
/// worker, so nothing here can jank the UI.
class TranslationWorker {
  TranslationWorker._();

  static final instance = TranslationWorker._();

  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _starting;
  final _receivePort = <ReceivePort>[];
  final _pending = <int, Completer<Object?>>{};
  int _nextId = 0;

  Future<void> _ensureStarted() async {
    if (_sendPort != null) return;
    if (_starting != null) return _starting;
    var completer = Completer<void>();
    _starting = completer.future;
    var port = ReceivePort();
    _receivePort.add(port);
    port.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        completer.complete();
      } else if (message is _WorkerResponse) {
        var pending = _pending.remove(message.id);
        if (pending == null) return;
        if (message.error != null) {
          pending.completeError(Exception(message.error));
        } else {
          pending.complete(message.result);
        }
      }
    });
    try {
      _isolate = await Isolate.spawn(
        _workerMain,
        port.sendPort,
        debugName: 'imageTranslationWorker',
      );
    } catch (e) {
      _starting = null;
      completer.completeError(e);
      rethrow;
    }
    await completer.future;
    _starting = null;
  }

  Future<T> _request<T>(Object Function(int id) build) async {
    await _ensureStarted();
    var id = _nextId++;
    var completer = Completer<Object?>();
    _pending[id] = completer;
    _sendPort!.send(build(id));
    return await completer.future as T;
  }

  /// Detects and recognizes all text blocks of a page.
  Future<List<OcrBlock>> ocrPage(
    RgbaImage image, {
    required String sourceLang,
    required WorkerModelPaths paths,
  }) {
    var intraThreads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);
    return _request<List<OcrBlock>>(
      (id) => _OcrPageRequest(
        id,
        TransferableTypedData.fromList([image.pixels]),
        image.width,
        image.height,
        sourceLang,
        paths,
        intraThreads,
      ),
    );
  }

  /// Frees model memory inside the worker (sessions are re-created lazily).
  void release() {
    _sendPort?.send(const _ReleaseRequest());
  }

  /// Kills the worker isolate entirely. Pending requests complete with an
  /// error; the worker restarts lazily on the next request.
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _starting = null;
    for (var port in _receivePort) {
      port.close();
    }
    _receivePort.clear();
    for (var pending in _pending.values) {
      pending.completeError(Exception('Translation worker disposed'));
    }
    _pending.clear();
  }
}

// ===========================================================================
// Worker isolate
// ===========================================================================

void _workerMain(SendPort mainPort) {
  var port = ReceivePort();
  mainPort.send(port.sendPort);
  var state = _WorkerState();
  port.listen((message) {
    if (message is _OcrPageRequest) {
      try {
        var blocks = state.ocrPage(message);
        mainPort.send(_WorkerResponse(message.id, blocks, null));
      } catch (e, s) {
        mainPort.send(_WorkerResponse(message.id, null, '$e\n$s'));
      }
    } else if (message is _ReleaseRequest) {
      state.release();
    }
  });
}

class _WorkerState {
  final _sessions = <String, OrtFfiSession>{};
  final _charsets = <String, List<String>>{};
  WordPieceVocab? _jaVocab;
  int _intraThreads = 2;

  OrtFfiSession _session(String path) {
    return _sessions.putIfAbsent(
      path,
      () => OrtFfiSession.open(path, intraOpThreads: _intraThreads),
    );
  }

  void release() {
    for (var session in _sessions.values) {
      session.close();
    }
    _sessions.clear();
    _jaVocab = null;
  }

  // -------------------------------------------------------------------------
  // OCR page
  // -------------------------------------------------------------------------

  List<OcrBlock> ocrPage(_OcrPageRequest req) {
    _intraThreads = req.intraThreads;
    var image = RgbaImage(
      req.width,
      req.height,
      req.pixels.materialize().asUint8List(),
    );
    var boxes = _detectBoxes(image, req.paths);
    if (boxes.isEmpty) return const [];
    var clusters = _clusterBoxes(boxes, image.width, image.height);
    clusters.sort((a, b) => _boundsOf(a).top.compareTo(_boundsOf(b).top));
    const maxBlocks = 32;
    if (clusters.length > maxBlocks) {
      clusters = clusters.sublist(0, maxBlocks);
    }

    var blocks = <OcrBlock>[];
    for (var cluster in clusters) {
      var bounds = _boundsOf(cluster).inflated(4, 4, image.width, image.height);
      if (bounds.width < 8 || bounds.height < 8) continue;
      var colors = _sampleColors(image, bounds);
      var (text, lang) = _recognizeBlock(image, cluster, bounds, req);
      text = text.trim();
      if (text.isEmpty) continue;
      blocks.add(
        OcrBlock(
          rect: bounds,
          text: text,
          language: lang,
          backgroundColor: colors.$1,
          textColor: colors.$2,
        ),
      );
    }
    return blocks;
  }

  /// OCR one block. In 'auto' mode a vertical block prefers the Japanese
  /// engine and horizontal blocks try the installed engines in order until
  /// one produces plausible text; the language is then derived from the
  /// recognized script.
  (String, String) _recognizeBlock(
    RgbaImage image,
    List<IntRect> lines,
    IntRect bounds,
    _OcrPageRequest req,
  ) {
    var paths = req.paths;
    var hasJa = paths.jaEncoder != null;

    List<String> engineOrder;
    if (req.sourceLang != 'auto') {
      engineOrder = [req.sourceLang];
    } else {
      var vertical = bounds.height > bounds.width * 1.3;
      engineOrder = [
        if (vertical && hasJa) 'ja',
        ...paths.recModels.keys,
        if (!vertical && hasJa) 'ja',
      ];
    }

    String bestText = '';
    for (var engine in engineOrder) {
      String text;
      if (engine == 'ja') {
        if (!hasJa) continue;
        text = _mangaOcr(image, bounds, paths);
      } else {
        if (!paths.recModels.containsKey(engine)) continue;
        text = _recognizeLines(image, lines, engine, paths);
      }
      text = text.trim();
      if (_isPlausible(text)) {
        return (text, _detectLanguage(text, engine));
      }
      if (text.length > bestText.length) {
        bestText = text;
      }
    }
    return (bestText, _detectLanguage(bestText, engineOrder.firstOrNull ?? 'ja'));
  }

  bool _isPlausible(String text) {
    if (text.length < 2) return false;
    var meaningful = text.runes
        .where((r) => r > 0x2E80 || (r >= 0x30 && r <= 0x7A))
        .length;
    return meaningful >= math.max(2, text.length ~/ 2);
  }

  /// Determines the language from the recognized script; falls back to the
  /// engine's own language when the text is ambiguous.
  String _detectLanguage(String text, String engineLang) {
    var kana = 0, hangul = 0, han = 0, latin = 0;
    for (var r in text.runes) {
      if ((r >= 0x3040 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF)) {
        kana++;
      } else if ((r >= 0xAC00 && r <= 0xD7AF) || (r >= 0x1100 && r <= 0x11FF)) {
        hangul++;
      } else if ((r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF)) {
        han++;
      } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        latin++;
      }
    }
    if (kana > 0) return 'ja';
    if (hangul > 0) return 'ko';
    if (han > 0) return engineLang == 'ja' ? 'ja' : 'zh';
    if (latin > 0) return 'en';
    return engineLang;
  }

  // ----- detection -----

  List<IntRect> _detectBoxes(RgbaImage image, WorkerModelPaths paths) {
    var session = _session(paths.detector);
    var boxes = <IntRect>[];
    const tileHeight = 1280;
    const tileOverlap = 128;
    var top = 0;
    while (top < image.height) {
      var bottom = math.min(image.height, top + tileHeight);
      var tile = RgbaImage(
        image.width,
        bottom - top,
        Uint8List.sublistView(
          image.pixels,
          top * image.width * 4,
          bottom * image.width * 4,
        ),
      );
      var input = _detPreprocess(tile);
      var output = session
          .run({
            session.inputNames.first: OrtInput.float32(input.tensor, [
              1,
              3,
              input.height,
              input.width,
            ]),
          })
          .values
          .first;
      var tileBoxes = _detPostprocess(
        output.data,
        input.width,
        input.height,
        tile.width,
        tile.height,
      );
      for (var box in tileBoxes) {
        box.top += top;
        box.bottom += top;
        if (!boxes.any((b) => _iou(b, box) > 0.5)) {
          boxes.add(box);
        }
      }
      if (bottom >= image.height) break;
      top = bottom - tileOverlap;
    }
    return boxes;
  }

  // ----- Japanese OCR (manga-ocr) -----

  String _mangaOcr(RgbaImage image, IntRect bounds, WorkerModelPaths paths) {
    _jaVocab ??= WordPieceVocab.fromFileSync(paths.jaVocab!);
    var encoder = _session(paths.jaEncoder!);
    var decoder = _session(paths.jaDecoder!);
    var pixels = _cropNormalized(image, bounds, 224, 224);
    var hidden = encoder
        .run({
          encoder.inputNames.first: OrtInput.float32(pixels, const [
            1,
            3,
            224,
            224,
          ]),
        })
        .values
        .first;

    const startToken = 2;
    const eosToken = 3;
    const maxTokens = 80;
    var ids = <int>[startToken];
    while (ids.length < maxTokens) {
      var next = decoder.runArgmaxLastRow({
        'input_ids': OrtInput.int64(
          Int64List.fromList(ids),
          [1, ids.length],
        ),
        'encoder_hidden_states': OrtInput.float32(hidden.data, hidden.shape),
      }, decoder.outputNames.first);
      if (next == eosToken) break;
      ids.add(next);
      // Greedy decoding can fall into repetition loops on hard crops
      // (stylized fonts, screentone backgrounds), which came out as garbage
      // strings. Cut the sequence when the tail starts repeating.
      if (_hasRepetitionLoop(ids)) {
        ids.removeRange(ids.length - 3, ids.length);
        break;
      }
    }
    return _jaVocab!.decode(ids.sublist(1));
  }

  /// True when the tail of [ids] repeats: the same trigram twice in a row,
  /// or four identical tokens.
  bool _hasRepetitionLoop(List<int> ids) {
    var n = ids.length;
    if (n >= 4 &&
        ids[n - 1] == ids[n - 2] &&
        ids[n - 2] == ids[n - 3] &&
        ids[n - 3] == ids[n - 4]) {
      return true;
    }
    if (n >= 6) {
      var repeated = true;
      for (var i = 0; i < 3; i++) {
        if (ids[n - 1 - i] != ids[n - 4 - i]) {
          repeated = false;
          break;
        }
      }
      if (repeated) return true;
    }
    return false;
  }

  // ----- Line OCR (PP-OCR CTC) -----

  String _recognizeLines(
    RgbaImage image,
    List<IntRect> lines,
    String lang,
    WorkerModelPaths paths,
  ) {
    var modelPath = paths.recModels[lang]!;
    var session = _session(modelPath);
    var charset = _charsets.putIfAbsent(lang, () {
      var dict = File(paths.recDicts[lang]!).readAsLinesSync();
      return ['', ...dict.map((line) => line.isEmpty ? ' ' : line), ' '];
    });
    var height = paths.recHeights[lang] ?? 48;
    var sorted = [...lines]..sort((a, b) => a.top.compareTo(b.top));
    var parts = <String>[];
    for (var line in sorted) {
      var rect = line.inflated(2, 2, image.width, image.height);
      if (rect.width < 8 || rect.height < 8) continue;
      var outW = (rect.width * height / math.max(1, rect.height))
          .round()
          .clamp(16, 960);
      outW = (outW / 8).ceil() * 8;
      var tensor = _cropNormalized(image, rect, outW, height);
      var output = session
          .run({
            session.inputNames.first: OrtInput.float32(tensor, [
              1,
              3,
              height,
              outW,
            ]),
          })
          .values
          .first;
      var text = _ctcDecode(output.data, output.shape.last, charset);
      if (text.trim().isNotEmpty) {
        parts.add(text.trim());
      }
    }
    return parts.join(' ');
  }

  String _ctcDecode(Float32List probs, int classes, List<String> charset) {
    var steps = probs.length ~/ classes;
    var buffer = StringBuffer();
    var prev = 0;
    for (var t = 0; t < steps; t++) {
      var best = 0;
      var bestScore = probs[t * classes];
      for (var c = 1; c < classes; c++) {
        var score = probs[t * classes + c];
        if (score > bestScore) {
          bestScore = score;
          best = c;
        }
      }
      if (best != 0 && best != prev && best < charset.length) {
        buffer.write(charset[best]);
      }
      prev = best;
    }
    return buffer.toString().trim();
  }
}

// ===========================================================================
// Pure image math (worker side)
// ===========================================================================

class _DetInput {
  _DetInput(this.tensor, this.width, this.height);

  final Float32List tensor;
  final int width;
  final int height;
}

Uint8List _resizeRegion(RgbaImage src, IntRect region, int outW, int outH) {
  var out = Uint8List(outW * outH * 4);
  var srcW = region.width;
  var srcH = region.height;
  for (var y = 0; y < outH; y++) {
    var fy = (y + 0.5) * srcH / outH - 0.5;
    var y0 = fy.floor().clamp(0, srcH - 1);
    var y1 = (y0 + 1).clamp(0, srcH - 1);
    var wy = fy - fy.floor();
    for (var x = 0; x < outW; x++) {
      var fx = (x + 0.5) * srcW / outW - 0.5;
      var x0 = fx.floor().clamp(0, srcW - 1);
      var x1 = (x0 + 1).clamp(0, srcW - 1);
      var wx = fx - fx.floor();
      var outIndex = (y * outW + x) * 4;
      for (var c = 0; c < 4; c++) {
        var p00 =
            src.pixels[((region.top + y0) * src.width + region.left + x0) * 4 + c];
        var p01 =
            src.pixels[((region.top + y0) * src.width + region.left + x1) * 4 + c];
        var p10 =
            src.pixels[((region.top + y1) * src.width + region.left + x0) * 4 + c];
        var p11 =
            src.pixels[((region.top + y1) * src.width + region.left + x1) * 4 + c];
        var top = p00 + (p01 - p00) * wx;
        var bottom = p10 + (p11 - p10) * wx;
        out[outIndex + c] = (top + (bottom - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// PP-OCR DBNet preprocessing: long side <= 1280 (small/stylized lettering
/// survives better than at the stock 960), multiple of 32, ImageNet
/// normalization.
_DetInput _detPreprocess(RgbaImage tile) {
  const maxSide = 1280.0;
  var scale = math.min(1.0, maxSide / math.max(tile.width, tile.height));
  int round32(double v) => math.max(32, (v / 32).round() * 32);
  var inW = round32(tile.width * scale);
  var inH = round32(tile.height * scale);
  var resized = _resizeRegion(
    tile,
    IntRect(0, 0, tile.width, tile.height),
    inW,
    inH,
  );
  const mean = [0.485, 0.456, 0.406];
  const std = [0.229, 0.224, 0.225];
  var tensor = Float32List(3 * inH * inW);
  var plane = inH * inW;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      tensor[c * plane + i] = (resized[i * 4 + c] / 255.0 - mean[c]) / std[c];
    }
  }
  return _DetInput(tensor, inW, inH);
}

/// DBNet postprocessing: binarize, connected components, filter, dilate.
List<IntRect> _detPostprocess(
  Float32List probs,
  int w,
  int h,
  int tileWidth,
  int tileHeight,
) {
  const binaryThreshold = 0.3;
  const scoreThreshold = 0.5;
  const unclipRatio = 1.8;
  var labels = Int32List(w * h);
  var boxes = <IntRect>[];
  var stack = <int>[];
  var nextLabel = 0;
  for (var start = 0; start < w * h; start++) {
    if (labels[start] != 0 || probs[start] < binaryThreshold) {
      continue;
    }
    nextLabel++;
    var minX = w, minY = h, maxX = 0, maxY = 0;
    var count = 0;
    var scoreSum = 0.0;
    stack.add(start);
    labels[start] = nextLabel;
    while (stack.isNotEmpty) {
      var index = stack.removeLast();
      var x = index % w;
      var y = index ~/ w;
      count++;
      scoreSum += probs[index];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
      for (var d = 0; d < 4; d++) {
        var nx = x + const [1, -1, 0, 0][d];
        var ny = y + const [0, 0, 1, -1][d];
        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
        var ni = ny * w + nx;
        if (labels[ni] == 0 && probs[ni] >= binaryThreshold) {
          labels[ni] = nextLabel;
          stack.add(ni);
        }
      }
    }
    if (count < 12 || scoreSum / count < scoreThreshold) {
      continue;
    }
    var boxW = maxX - minX + 1;
    var boxH = maxY - minY + 1;
    if (boxW < 3 || boxH < 3) continue;
    var offset = boxW * boxH * unclipRatio / (2 * (boxW + boxH));
    var scaleX = tileWidth / w;
    var scaleY = tileHeight / h;
    boxes.add(
      IntRect(
        ((minX - offset) * scaleX).round(),
        ((minY - offset) * scaleY).round(),
        ((maxX + 1 + offset) * scaleX).round(),
        ((minY - offset) * scaleY).round() +
            ((boxH + 2 * offset) * scaleY).round(),
      ),
    );
  }
  return boxes;
}

List<List<IntRect>> _clusterBoxes(List<IntRect> boxes, int width, int height) {
  var parents = List<int>.generate(boxes.length, (i) => i);
  int find(int i) {
    while (parents[i] != i) {
      parents[i] = parents[parents[i]];
      i = parents[i];
    }
    return i;
  }

  var inflated = [
    for (var box in boxes)
      // Inflation controls when neighbouring lines merge into one block.
      // Too generous and two adjacent speech bubbles fuse — the combined
      // crop then squashes both into one OCR input and recognition degrades
      // badly. 0.55 of the short side still bridges the gaps between lines
      // and vertical columns inside one bubble.
      box.inflated(
        (math.min(box.width, box.height) * 0.55).round().clamp(3, 32),
        (math.min(box.width, box.height) * 0.55).round().clamp(3, 32),
        width,
        height,
      ),
  ];
  for (var i = 0; i < boxes.length; i++) {
    for (var j = i + 1; j < boxes.length; j++) {
      if (inflated[i].intersects(inflated[j])) {
        parents[find(i)] = find(j);
      }
    }
  }
  var groups = <int, List<IntRect>>{};
  for (var i = 0; i < boxes.length; i++) {
    groups.putIfAbsent(find(i), () => []).add(boxes[i]);
  }
  return groups.values.toList();
}

IntRect _boundsOf(List<IntRect> boxes) {
  var result = IntRect(
    boxes[0].left,
    boxes[0].top,
    boxes[0].right,
    boxes[0].bottom,
  );
  for (var box in boxes.skip(1)) {
    result.left = math.min(result.left, box.left);
    result.top = math.min(result.top, box.top);
    result.right = math.max(result.right, box.right);
    result.bottom = math.max(result.bottom, box.bottom);
  }
  return result;
}

/// Crops a region and normalizes to (x/255 - 0.5) / 0.5, CHW.
Float32List _cropNormalized(RgbaImage image, IntRect rect, int outW, int outH) {
  var resized = _resizeRegion(image, rect, outW, outH);
  var tensor = Float32List(3 * outH * outW);
  var plane = outH * outW;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      tensor[c * plane + i] = (resized[i * 4 + c] / 255.0 - 0.5) / 0.5;
    }
  }
  return tensor;
}

/// Samples the ring outside a rect: (backgroundColor, textColor).
(int, int) _sampleColors(RgbaImage image, IntRect rect) {
  var ring = rect.inflated(6, 6, image.width, image.height);
  var rs = <int>[], gs = <int>[], bs = <int>[];
  void sample(int x, int y) {
    var i = (y * image.width + x) * 4;
    rs.add(image.pixels[i]);
    gs.add(image.pixels[i + 1]);
    bs.add(image.pixels[i + 2]);
  }

  for (var x = ring.left; x < ring.right; x += 3) {
    sample(x, ring.top);
    sample(x, ring.bottom - 1);
  }
  for (var y = ring.top; y < ring.bottom; y += 3) {
    sample(ring.left, y);
    sample(ring.right - 1, y);
  }
  int median(List<int> values) {
    if (values.isEmpty) return 255;
    values.sort();
    return values[values.length ~/ 2];
  }

  var r = median(rs), g = median(gs), b = median(bs);
  var luminance = 0.299 * r + 0.587 * g + 0.114 * b;
  var textColor = luminance < 128 ? 0xFFF5F5F5 : 0xFF202020;
  var backgroundColor = 0xFF000000 | (r << 16) | (g << 8) | b;
  return (backgroundColor, textColor);
}

double _iou(IntRect a, IntRect b) {
  var left = math.max(a.left, b.left);
  var top = math.max(a.top, b.top);
  var right = math.min(a.right, b.right);
  var bottom = math.min(a.bottom, b.bottom);
  if (left >= right || top >= bottom) return 0;
  var inter = (right - left) * (bottom - top);
  return inter / (a.area + b.area - inter);
}

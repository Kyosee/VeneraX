import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_translation/inference.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/opencc.dart';

class PipelineCanceled implements Exception {
  const PipelineCanceled();
}

/// Raw RGBA bitmap that can cross isolate boundaries.
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// Integer rectangle (avoids dart:ui types inside compute isolates).
class IntRect {
  IntRect(this.left, this.top, this.right, this.bottom);

  int left, top, right, bottom;

  int get width => right - left;
  int get height => bottom - top;
  int get area => width * height;

  bool intersects(IntRect other) {
    return left < other.right &&
        other.left < right &&
        top < other.bottom &&
        other.top < bottom;
  }

  IntRect inflated(int dx, int dy, int maxW, int maxH) {
    return IntRect(
      (left - dx).clamp(0, maxW),
      (top - dy).clamp(0, maxH),
      (right + dx).clamp(0, maxW),
      (bottom + dy).clamp(0, maxH),
    );
  }
}

/// A translated text block ready for rendering.
class TranslatedRegion {
  TranslatedRegion({
    required this.rect,
    required this.text,
    required this.backgroundColor,
    required this.textColor,
  });

  final IntRect rect;
  final String text;
  final int backgroundColor;
  final int textColor;
}

// ---------------------------------------------------------------------------
// Isolate-friendly image math
// ---------------------------------------------------------------------------

/// Bilinear resize of an RGBA bitmap region.
Uint8List _resizeRegion(
  RgbaImage src,
  IntRect region,
  int outW,
  int outH,
) {
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
        var p00 = src.pixels[((region.top + y0) * src.width + region.left + x0) * 4 + c];
        var p01 = src.pixels[((region.top + y0) * src.width + region.left + x1) * 4 + c];
        var p10 = src.pixels[((region.top + y1) * src.width + region.left + x0) * 4 + c];
        var p11 = src.pixels[((region.top + y1) * src.width + region.left + x1) * 4 + c];
        var top = p00 + (p01 - p00) * wx;
        var bottom = p10 + (p11 - p10) * wx;
        out[outIndex + c] = (top + (bottom - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// Copies a sub-rectangle into its own small bitmap. Runs on the caller's
/// isolate: sending the full page image into a compute() worker would copy
/// tens of MB per call, so workers only ever receive the region they need.
RgbaImage _extractRegion(RgbaImage src, IntRect rect) {
  var out = Uint8List(rect.width * rect.height * 4);
  for (var y = 0; y < rect.height; y++) {
    var srcStart = ((rect.top + y) * src.width + rect.left) * 4;
    out.setRange(
      y * rect.width * 4,
      (y + 1) * rect.width * 4,
      src.pixels,
      srcStart,
    );
  }
  return RgbaImage(rect.width, rect.height, out);
}

class _DetInput {
  _DetInput(this.tensor, this.inputWidth, this.inputHeight);

  final Float32List tensor;
  final int inputWidth;
  final int inputHeight;
}

class _DetPreArgs {
  _DetPreArgs(this.image, this.tile);

  final RgbaImage image;
  final IntRect tile;
}

/// PP-OCR DBNet preprocessing: resize the tile so the long side is <= 960
/// (multiple of 32) and normalize with ImageNet statistics.
_DetInput _detPreprocess(_DetPreArgs args) {
  const maxSide = 960.0;
  var tile = args.tile;
  var scale = math.min(1.0, maxSide / math.max(tile.width, tile.height));
  int round32(double v) => (math.max(32, (v / 32).round() * 32));
  var inW = round32(tile.width * scale);
  var inH = round32(tile.height * scale);
  var resized = _resizeRegion(args.image, tile, inW, inH);

  const mean = [0.485, 0.456, 0.406];
  const std = [0.229, 0.224, 0.225];
  var tensor = Float32List(3 * inH * inW);
  var plane = inH * inW;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      tensor[c * plane + i] =
          (resized[i * 4 + c] / 255.0 - mean[c]) / std[c];
    }
  }
  return _DetInput(tensor, inW, inH);
}

class _DetPostArgs {
  _DetPostArgs(this.probMap, this.inputWidth, this.inputHeight, this.tile);

  final Float32List probMap;
  final int inputWidth;
  final int inputHeight;
  final IntRect tile;
}

/// DBNet postprocessing: binarize the probability map, extract connected
/// components, score-filter them and dilate each box back to full text size
/// (approximation of the standard polygon unclip with axis-aligned boxes,
/// which fits manga text well enough).
List<IntRect> _detPostprocess(_DetPostArgs args) {
  const binaryThreshold = 0.3;
  const scoreThreshold = 0.5;
  const unclipRatio = 1.8;
  var w = args.inputWidth;
  var h = args.inputHeight;
  var probs = args.probMap;
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
    // Unclip approximation: uniform offset derived from area / perimeter.
    var offset = boxW * boxH * unclipRatio / (2 * (boxW + boxH));
    var scaleX = args.tile.width / w;
    var scaleY = args.tile.height / h;
    boxes.add(
      IntRect(
        (args.tile.left + (minX - offset) * scaleX).round(),
        (args.tile.top + (minY - offset) * scaleY).round(),
        (args.tile.left + (maxX + 1 + offset) * scaleX).round(),
        (args.tile.top + (minY - offset) * scaleY).round() +
            ((boxH + 2 * offset) * scaleY).round(),
      ),
    );
  }
  return boxes;
}

/// Groups detected line/column boxes into text blocks (speech bubbles):
/// boxes whose inflated rectangles touch are merged with union-find.
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
      box.inflated(
        (math.min(box.width, box.height) * 0.7).round().clamp(4, 40),
        (math.min(box.width, box.height) * 0.7).round().clamp(4, 40),
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
  var result = IntRect(boxes[0].left, boxes[0].top, boxes[0].right, boxes[0].bottom);
  for (var box in boxes.skip(1)) {
    result.left = math.min(result.left, box.left);
    result.top = math.min(result.top, box.top);
    result.right = math.max(result.right, box.right);
    result.bottom = math.max(result.bottom, box.bottom);
  }
  return result;
}

class _CropArgs {
  _CropArgs(this.image, this.rect, this.outWidth, this.outHeight);

  final RgbaImage image;
  final IntRect rect;
  final int outWidth;

  /// When 0, the width is derived from the aspect ratio (PP-OCR lines).
  final int outHeight;
}

class _CropResult {
  _CropResult(this.tensor, this.width, this.height, this.backgroundColor,
      this.textColor);

  final Float32List tensor;
  final int width;
  final int height;
  final int backgroundColor;
  final int textColor;
}

/// Crops a region, resizes it for the requested OCR input and normalizes to
/// (x/255 - 0.5) / 0.5. Also samples the surrounding background color for
/// rendering the cover patch later.
_CropResult _prepareCrop(_CropArgs args) {
  var rect = args.rect;
  int outW, outH;
  if (args.outHeight == 0) {
    outH = args.outWidth; // args.outWidth carries the fixed height here.
    outW = (rect.width * outH / math.max(1, rect.height)).round().clamp(16, 640);
    // CRNN convolutions need a width the strides can divide.
    outW = (outW / 8).ceil() * 8;
  } else {
    outW = args.outWidth;
    outH = args.outHeight;
  }
  var resized = _resizeRegion(args.image, rect, outW, outH);
  var tensor = Float32List(3 * outH * outW);
  var plane = outH * outW;
  for (var i = 0; i < plane; i++) {
    for (var c = 0; c < 3; c++) {
      tensor[c * plane + i] = (resized[i * 4 + c] / 255.0 - 0.5) / 0.5;
    }
  }

  // Sample a ring just outside the rect for the bubble background color.
  var image = args.image;
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
  return _CropResult(tensor, outW, outH, backgroundColor, textColor);
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

/// Full local translation pipeline for one page image: detect text regions,
/// recognize the source text, translate it offline and re-render the page.
class PageTranslationPipeline {
  PageTranslationPipeline();

  final _detector = TextDetectorEngine();
  MangaOcrEngine? _mangaOcr;
  final _recEngines = <String, PaddleRecEngine>{};
  final _translator = NeuralTranslatorEngine();

  static const _maxBlocksPerPage = 32;

  /// Translates [imageBytes]; returns re-rendered PNG bytes, or null when the
  /// page contains no translatable text.
  Future<Uint8List?> translatePage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
    bool Function()? shouldCancel,
  }) async {
    void checkCancel() {
      if (shouldCancel?.call() ?? false) {
        throw const PipelineCanceled();
      }
    }

    var image = await _decode(imageBytes);
    checkCancel();

    // Tall webtoon strips are detected tile by tile so small text is not
    // destroyed by the detector's 960px input limit.
    var boxes = <IntRect>[];
    const tileHeight = 1280;
    const tileOverlap = 128;
    var top = 0;
    while (top < image.height) {
      var bottom = math.min(image.height, top + tileHeight);
      // Full-width tile rows are a contiguous slice; only the tile crosses
      // the isolate boundary, not the whole page.
      var tileImage = RgbaImage(
        image.width,
        bottom - top,
        image.pixels.sublist(top * image.width * 4, bottom * image.width * 4),
      );
      var tileRect = IntRect(0, 0, tileImage.width, tileImage.height);
      var input = await compute(_detPreprocess, _DetPreArgs(tileImage, tileRect));
      checkCancel();
      var probMap = await _detector.run(
        input.tensor,
        input.inputHeight,
        input.inputWidth,
      );
      checkCancel();
      var tileBoxes = await compute(
        _detPostprocess,
        _DetPostArgs(probMap, input.inputWidth, input.inputHeight, tileRect),
      );
      // Map back to page coordinates and drop duplicates from the overlap.
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
    if (boxes.isEmpty) {
      return null;
    }

    var blocks = _clusterBoxes(boxes, image.width, image.height);
    blocks.sort((a, b) => _boundsOf(a).top.compareTo(_boundsOf(b).top));
    if (blocks.length > _maxBlocksPerPage) {
      blocks = blocks.sublist(0, _maxBlocksPerPage);
    }

    var regions = <TranslatedRegion>[];
    var translationCache = <String, String>{};
    for (var block in blocks) {
      checkCancel();
      var bounds = _boundsOf(block).inflated(4, 4, image.width, image.height);
      if (bounds.width < 8 || bounds.height < 8) continue;
      try {
        String text;
        _CropResult crop;
        // Extract the block (with a margin for background sampling) on this
        // isolate; the compute worker only receives the small region.
        var outer = bounds.inflated(8, 8, image.width, image.height);
        var blockImage = _extractRegion(image, outer);
        var innerRect = IntRect(
          bounds.left - outer.left,
          bounds.top - outer.top,
          bounds.right - outer.left,
          bounds.bottom - outer.top,
        );
        if (sourceLang == 'ja') {
          crop = await compute(
            _prepareCrop,
            _CropArgs(blockImage, innerRect, 224, 224),
          );
          checkCancel();
          text = await _mangaOcrEngine.recognize(crop.tensor);
        } else {
          // Line-level OCR does the reading; this tiny crop only samples the
          // block's background/text colors for rendering.
          crop = await compute(
            _prepareCrop,
            _CropArgs(blockImage, innerRect, 32, 32),
          );
          checkCancel();
          text = await _recognizeLines(image, block, sourceLang);
        }
        text = text.trim();
        if (!_isTranslatable(text)) continue;
        checkCancel();
        var translated = translationCache[text] ??
            await _translate(text, sourceLang, targetLang);
        translationCache[text] = translated;
        if (translated.isEmpty || translated == text) continue;
        regions.add(
          TranslatedRegion(
            rect: bounds,
            text: translated,
            backgroundColor: crop.backgroundColor,
            textColor: crop.textColor,
          ),
        );
      } on PipelineCanceled {
        rethrow;
      } catch (e, s) {
        Log.warning('Image Translation', 'Block failed, skipping: $e\n$s');
      }
    }
    if (regions.isEmpty) {
      return null;
    }
    checkCancel();
    return await renderTranslatedPage(imageBytes, image, regions);
  }

  MangaOcrEngine get _mangaOcrEngine => _mangaOcr ??= MangaOcrEngine();

  int _recHeight(String lang) => lang == 'ko' ? 32 : 48;

  PaddleRecEngine _recEngine(String lang) {
    return _recEngines.putIfAbsent(lang, () {
      return PaddleRecEngine(
        TranslationModels.ocrFor(lang),
        inputHeight: _recHeight(lang),
      );
    });
  }

  /// Horizontal scripts: recognize each detected line separately in reading
  /// order and join them.
  Future<String> _recognizeLines(
    RgbaImage image,
    List<IntRect> lines,
    String lang,
  ) async {
    lines.sort((a, b) => a.top.compareTo(b.top));
    var engine = _recEngine(lang);
    var parts = <String>[];
    for (var line in lines) {
      var rect = line.inflated(2, 2, image.width, image.height);
      if (rect.width < 8 || rect.height < 8) continue;
      var lineImage = _extractRegion(image, rect);
      var crop = await compute(
        _prepareCrop,
        _CropArgs(
          lineImage,
          IntRect(0, 0, lineImage.width, lineImage.height),
          _recHeight(lang),
          0,
        ),
      );
      var text = await engine.recognize(crop.tensor, crop.width);
      if (text.trim().isNotEmpty) {
        parts.add(text.trim());
      }
    }
    return parts.join(' ');
  }

  Future<String> _translate(String text, String source, String target) async {
    var modelTarget = target == 'zh-TW' ? 'zh' : target;
    var result = await _translator.translate(text, source, modelTarget);
    if (target == 'zh-TW') {
      result = OpenCC.simplifiedToTraditional(result);
    }
    return result.trim();
  }

  bool _isTranslatable(String text) {
    if (text.length < 2) return false;
    // Pure digits/punctuation (page numbers, sfx dashes) are not worth a
    // translation pass.
    return text.runes.any((r) {
      return r > 0x2E80 || (r >= 0x41 && r <= 0x7A);
    });
  }

  Future<RgbaImage> _decode(Uint8List bytes) async {
    var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    var descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Bound decoded size: huge pages (webtoon strips) are downscaled so the
    // pipeline's RGBA buffers stay within a sane memory budget, and no
    // dimension exceeds common GPU texture limits (the rendered result goes
    // through Picture.toImage).
    const maxPixels = 12 * 1024 * 1024;
    const maxDimension = 8000;
    var w = descriptor.width;
    var h = descriptor.height;
    var scale = 1.0;
    if (w * h > maxPixels) {
      scale = math.sqrt(maxPixels / (w * h));
    }
    if (math.max(w, h) * scale > maxDimension) {
      scale = maxDimension / math.max(w, h);
    }
    int? targetW;
    int? targetH;
    if (scale < 1.0) {
      // Both dimensions must be passed: instantiateCodec does not derive the
      // missing one from the aspect ratio.
      targetW = math.max(1, (w * scale).round());
      targetH = math.max(1, (h * scale).round());
    }
    var codec = await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
    var frame = await codec.getNextFrame();
    var image = frame.image;
    try {
      var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw Exception('Failed to read image pixels');
      }
      return RgbaImage(image.width, image.height, data.buffer.asUint8List());
    } finally {
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
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

  Future<void> release() async {
    await _detector.release();
    await _mangaOcr?.release();
    _mangaOcr = null;
    for (var engine in _recEngines.values) {
      await engine.release();
    }
    _recEngines.clear();
    await _translator.release();
  }
}

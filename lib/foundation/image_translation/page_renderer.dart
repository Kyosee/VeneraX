import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Renders the translated page: draws [decoded] as the base, then lays each
/// region's translated text over it. Returns PNG bytes.
///
/// In [InpaintMode.patch] the base is the untouched original and each region is
/// covered with an opaque rounded plate in the sampled background colour (the
/// legacy look). In [InpaintMode.smart]/[InpaintMode.ai] the caller has already
/// erased the original lettering in [decoded.pixels], so the base is clean and
/// each region only gets a backing plate where the placed text would otherwise
/// be hard to read against the artwork.
Future<Uint8List> renderTranslatedPage(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions, {
  InpaintMode mode = InpaintMode.smart,
}) async {
  var base = await _baseImage(originalBytes, decoded, mode);
  try {
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    canvas.drawImage(base, ui.Offset.zero, ui.Paint());
    for (var region in regions) {
      if (mode == InpaintMode.patch) {
        _drawPatchRegion(canvas, region);
      } else {
        _drawErasedRegion(canvas, decoded, region);
      }
    }
    var picture = recorder.endRecording();
    var rendered = await picture.toImage(decoded.width, decoded.height);
    picture.dispose();
    try {
      var data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw Exception('Failed to encode translated page');
      }
      return data.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  } finally {
    base.dispose();
  }
}

/// The base image to draw under the text. patch mode re-decodes the pristine
/// original at the working resolution; the erase modes draw [decoded] itself,
/// whose pixels were already cleaned by the inpainter.
Future<ui.Image> _baseImage(
  Uint8List originalBytes,
  RgbaImage decoded,
  InpaintMode mode,
) async {
  if (mode != InpaintMode.patch) {
    var buffer = await ui.ImmutableBuffer.fromUint8List(decoded.pixels);
    var descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: decoded.width,
      height: decoded.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    var codec = await descriptor.instantiateCodec();
    var frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return frame.image;
  }
  var buffer = await ui.ImmutableBuffer.fromUint8List(originalBytes);
  var descriptor = await ui.ImageDescriptor.encoded(buffer);
  var codec = await descriptor.instantiateCodec(
    targetWidth: decoded.width,
    targetHeight: decoded.height,
  );
  var frame = await codec.getNextFrame();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  return frame.image;
}

ui.Rect _rectOf(TranslatedRegion region) => ui.Rect.fromLTRB(
  region.rect.left.toDouble(),
  region.rect.top.toDouble(),
  region.rect.right.toDouble(),
  region.rect.bottom.toDouble(),
);

/// Legacy patch mode: opaque rounded plate + feathered halo, then the text.
void _drawPatchRegion(ui.Canvas canvas, TranslatedRegion region) {
  var rect = _rectOf(region);
  var background = ui.Color(region.backgroundColor);

  // Coverage margin scales with the region so original text bleeding past the
  // detected box is still hidden instead of leaving edges poking out.
  var minSide = math.min(rect.width, rect.height);
  var margin = math.max(3.0, minSide * 0.14);
  var core = rect.inflate(margin);
  var radius = ui.Radius.circular(math.min(margin, 4.0));

  // Feathered halo blends the fill into textured/translucent bubbles; the
  // opaque core on top still guarantees the original text is covered.
  var sigma = math.max(1.5, margin * 0.6);
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(core.inflate(sigma * 0.5), radius),
    ui.Paint()
      ..color = background
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma),
  );
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(core, radius),
    ui.Paint()..color = background,
  );

  _drawText(canvas, region, rect, ui.Color(region.textColor));
}

/// Erase mode: the base is already clean, so decide the text colour and whether
/// a subtle backing plate is needed from the erased pixels under the region,
/// then draw the text.
void _drawErasedRegion(
  ui.Canvas canvas,
  RgbaImage decoded,
  TranslatedRegion region,
) {
  var rect = _rectOf(region);
  var stats = _regionStats(decoded, region.rect);
  var textColor = stats.backgroundIsDark
      ? const ui.Color(0xFFF5F5F5)
      : const ui.Color(0xFF202020);

  // A backing plate goes down only when the cleaned area is too busy or too
  // close in luminance to the text to read against — a flat, uniform bubble
  // gets nothing, so the artwork shows through.
  if (stats.needsBacking) {
    var plate = stats.backgroundIsDark
        ? const ui.Color(0xC8101010)
        : const ui.Color(0xC8FFFFFF);
    var pad = math.max(2.0, math.min(rect.width, rect.height) * 0.06);
    var padded = rect.inflate(pad);
    var radius = ui.Radius.circular(math.min(padded.shortestSide * 0.5, 10.0));
    canvas.drawRRect(
      ui.RRect.fromRectAndRadius(padded, radius),
      ui.Paint()..color = plate,
    );
  }

  _drawText(canvas, region, rect, textColor);
}

/// Luminance / busyness of the region on the (erased) base, deciding text
/// colour and whether the placed text needs a backing plate.
class _RegionStats {
  _RegionStats(this.backgroundIsDark, this.needsBacking);
  final bool backgroundIsDark;
  final bool needsBacking;
}

_RegionStats _regionStats(RgbaImage image, IntRect rect) {
  var w = image.width;
  var left = rect.left.clamp(0, w - 1);
  var top = rect.top.clamp(0, image.height - 1);
  var right = rect.right.clamp(1, w);
  var bottom = rect.bottom.clamp(1, image.height);
  var pixels = image.pixels;

  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  // Sample on a stride grid — a full read is needless for a summary statistic.
  var stepX = math.max(1, (right - left) ~/ 24);
  var stepY = math.max(1, (bottom - top) ~/ 24);
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      var i = (y * w + x) * 4;
      var l = 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
      sum += l;
      sumSq += l * l;
      count++;
    }
  }
  if (count == 0) return _RegionStats(false, false);
  var mean = sum / count;
  var variance = (sumSq / count) - (mean * mean);
  var stdDev = variance <= 0 ? 0.0 : math.sqrt(variance);

  // High spread means the cleaned area is textured/detailed (screentone,
  // artwork) rather than a flat bubble — text would compete with it.
  var needsBacking = stdDev > 34;
  return _RegionStats(mean < 128, needsBacking);
}

void _drawText(
  ui.Canvas canvas,
  TranslatedRegion region,
  ui.Rect rect,
  ui.Color color,
) {
  if (_prefersVertical(region.text, rect)) {
    _drawVerticalText(canvas, region.text, color, rect);
    return;
  }
  var painter = _fitText(region.text, color, rect.width - 4, rect.height - 4);
  var offset = ui.Offset(
    rect.left + (rect.width - painter.width) / 2,
    rect.top + (rect.height - painter.height) / 2,
  );
  painter.paint(canvas, offset);
  painter.dispose();
}

/// Whether [text] should be laid out vertically inside [rect]: the region is
/// clearly taller than wide and the text is dominated by CJK characters.
bool _prefersVertical(String text, ui.Rect rect) {
  if (rect.height < rect.width * 1.6) return false;
  var cjk = 0, total = 0;
  for (var r in text.runes) {
    if (r <= 0x20) continue;
    total++;
    if ((r >= 0x4E00 && r <= 0x9FFF) ||
        (r >= 0x3400 && r <= 0x4DBF) ||
        (r >= 0x3040 && r <= 0x30FF) ||
        (r >= 0xAC00 && r <= 0xD7AF)) {
      cjk++;
    }
  }
  if (total < 2) return false;
  return cjk / total >= 0.7;
}

/// Draws [text] as vertical right-to-left columns fitted to [rect], one
/// character per cell, wrapping to a new column on the left when full.
void _drawVerticalText(
  ui.Canvas canvas,
  String text,
  ui.Color color,
  ui.Rect rect,
) {
  var chars = text.runes
      .map((r) => String.fromCharCode(r))
      .where((c) => c.trim().isNotEmpty)
      .toList();
  if (chars.isEmpty) return;

  var maxWidth = rect.width - 4;
  var maxHeight = rect.height - 4;

  TextPainter glyph(String c, double fontSize) {
    var painter = TextPainter(
      text: TextSpan(
        text: c,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          height: 1.0,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    painter.layout();
    return painter;
  }

  var upper = math.max(10.0, math.min(42.0, maxWidth * 0.9));
  const lower = 7.0;
  var size = upper;
  var chosen = lower;
  var perColumn = 1;
  var columns = chars.length;
  while (size >= lower) {
    var cellH = size * 1.15;
    var cellW = size * 1.15;
    perColumn = math.max(1, (maxHeight / cellH).floor());
    columns = (chars.length / perColumn).ceil();
    if (columns * cellW <= maxWidth) {
      chosen = size;
      break;
    }
    chosen = size;
    size -= 1.5;
  }

  var cellH = chosen * 1.15;
  var cellW = chosen * 1.15;
  perColumn = math.max(1, (maxHeight / cellH).floor());
  columns = (chars.length / perColumn).ceil();

  var blockW = columns * cellW;
  var blockH = math.min(maxHeight, perColumn * cellH);
  var startRight = rect.left + (rect.width + blockW) / 2;
  var top = rect.top + (rect.height - blockH) / 2;

  for (var col = 0; col < columns; col++) {
    var colCenterX = startRight - (col + 0.5) * cellW;
    for (var row = 0; row < perColumn; row++) {
      var index = col * perColumn + row;
      if (index >= chars.length) break;
      var painter = glyph(chars[index], chosen);
      var dx = colCenterX - painter.width / 2;
      var dy = top + row * cellH + (cellH - painter.height) / 2;
      painter.paint(canvas, ui.Offset(dx, dy));
      painter.dispose();
    }
  }
}

/// Finds the largest font size whose wrapped layout fits the region.
TextPainter _fitText(
  String text,
  ui.Color color,
  double maxWidth,
  double maxHeight,
) {
  TextPainter build(double fontSize) {
    var painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          height: 1.2,
          fontWeight: FontWeight.w500,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    painter.layout(maxWidth: math.max(8, maxWidth));
    return painter;
  }

  var upper = math.max(10.0, math.min(42.0, maxHeight * 0.8));
  const lower = 7.0;
  var size = upper;
  while (size > lower) {
    var painter = build(size);
    if (painter.height <= maxHeight && painter.width <= maxWidth) {
      return painter;
    }
    painter.dispose();
    size -= 1.5;
  }
  return build(lower);
}

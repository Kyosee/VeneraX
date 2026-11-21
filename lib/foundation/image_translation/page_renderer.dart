import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_translation/inpaint.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Erases source strokes on a worker isolate, then fits each translation in
/// the independent layout rectangle. Difficult backgrounds keep a small backing
/// behind the translated glyphs so every usable translation remains readable.
Future<Uint8List> renderTranslatedPage(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions, {
  InpaintMode mode = InpaintMode.smart,
  StrokeMask? strokeMask,
  void Function(List<TranslatedRegion>)? onSkipped,
}) async {
  var visible = List<int>.empty();
  var backed = <int>{};
  if (regions.isNotEmpty) {
    var (cleaned, indices, fallback) = await compute(_cleanPage, (
      decoded,
      regions,
      mode,
      strokeMask,
    ));
    decoded = cleaned;
    visible = indices;
    backed = fallback.toSet();
  }
  if (onSkipped != null) {
    var displayed = visible.toSet();
    onSkipped([
      for (var i = 0; i < regions.length; i++)
        if (!displayed.contains(i)) regions[i],
    ]);
  }
  var base = await _baseImage(decoded);
  try {
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    canvas.drawImage(base, ui.Offset.zero, ui.Paint());
    for (var index in visible) {
      var region = regions[index];
      if (backed.contains(index)) {
        final dark = _regionIsDark(decoded, region.rect);
        _drawText(
          canvas,
          region,
          _rectOf(region),
          dark ? const ui.Color(0xFFF5F5F5) : const ui.Color(0xFF202020),
          background: dark
              ? const ui.Color(0xFF202020)
              : const ui.Color(0xFFF5F5F5),
        );
      } else if (mode == InpaintMode.patch) {
        _drawText(canvas, region, _rectOf(region), ui.Color(region.textColor));
      } else {
        _drawErasedRegion(canvas, decoded, region);
      }
    }
    var picture = recorder.endRecording();
    var rendered = await picture.toImage(decoded.width, decoded.height);
    picture.dispose();
    try {
      var data = await rendered.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw Exception('Failed to encode translated page');
      return data.buffer.asUint8List();
    } finally {
      rendered.dispose();
    }
  } finally {
    base.dispose();
  }
}

(RgbaImage, List<int>, List<int>) _cleanPage(
  (RgbaImage, List<TranslatedRegion>, InpaintMode, StrokeMask?) work,
) {
  var (image, regions, mode, strokeMask) = work;
  var visible = <int>[];
  var backed = <int>[];
  final textRegions = [for (final region in regions) ...region.eraseRects];
  for (var index = 0; index < regions.length; index++) {
    var region = regions[index];
    if (region.text.trim().isEmpty ||
        region.rect.width <= 4 ||
        region.rect.height <= 4) {
      continue;
    }
    var masks = <(TextMask, bool)>[];
    for (var line in region.eraseRects) {
      var mask = TextInpainter.computeMask(
        image,
        line,
        strokeMask: strokeMask,
        flatFill: mode == InpaintMode.patch,
        textRegions: textRegions,
      );
      if (mask != null) {
        masks.add((mask, mode == InpaintMode.patch));
      } else if (mode == InpaintMode.patch) {
        final local = TextInpainter.computeMask(
          image,
          line,
          strokeMask: strokeMask,
          textRegions: textRegions,
        );
        if (local != null) masks.add((local, false));
      }
    }
    // A difficult line must not suppress the whole translation. Keep the art
    // in that line and back only the translated glyphs where it is drawn.
    if (masks.isEmpty || masks.length != region.eraseRects.length) {
      backed.add(index);
    }
    for (final (mask, flatFill) in masks) {
      if (flatFill) {
        TextInpainter.fillWithBackground(image, mask);
      } else {
        TextInpainter.eraseWithMask(image, mask);
      }
    }
    visible.add(index);
  }
  return (image, visible, backed);
}

Future<ui.Image> _baseImage(RgbaImage decoded) async {
  var buffer = await ui.ImmutableBuffer.fromUint8List(decoded.pixels);
  var descriptor = ui.ImageDescriptor.raw(
    buffer,
    width: decoded.width,
    height: decoded.height,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  var codec = await descriptor.instantiateCodec();
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

ui.Rect _rectOf(TranslatedRegion region) => ui.Rect.fromLTRB(
  region.rect.left.toDouble(),
  region.rect.top.toDouble(),
  region.rect.right.toDouble(),
  region.rect.bottom.toDouble(),
);

/// Erase mode: the base is already clean, so the text only needs a contrast
/// outline (never an opaque plate) to stay readable over minor screentone or
/// gradient the erase left behind.
void _drawErasedRegion(
  ui.Canvas canvas,
  RgbaImage decoded,
  TranslatedRegion region,
) {
  var rect = _rectOf(region);
  var backgroundIsDark = _regionIsDark(decoded, region.rect);
  var textColor = backgroundIsDark
      ? const ui.Color(0xFFF5F5F5)
      : const ui.Color(0xFF202020);
  // Outline in the opposite colour keeps the text legible without covering the
  // art — this is what replaces the old opaque backing plate.
  var outline = backgroundIsDark
      ? const ui.Color(0xE6000000)
      : const ui.Color(0xE6FFFFFF);
  _drawText(canvas, region, rect, textColor, outline: outline);
}

/// Mean-luminance test of the region on the (erased) base, choosing the text
/// colour. Sampled on a stride grid — a full read is needless for a summary.
bool _regionIsDark(RgbaImage image, IntRect rect) {
  var w = image.width;
  var left = rect.left.clamp(0, w - 1);
  var top = rect.top.clamp(0, image.height - 1);
  var right = rect.right.clamp(1, w);
  var bottom = rect.bottom.clamp(1, image.height);
  var pixels = image.pixels;

  var sum = 0.0;
  var count = 0;
  var stepX = math.max(1, (right - left) ~/ 24);
  var stepY = math.max(1, (bottom - top) ~/ 24);
  for (var y = top; y < bottom; y += stepY) {
    for (var x = left; x < right; x += stepX) {
      var i = (y * w + x) * 4;
      sum += 0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2];
      count++;
    }
  }
  if (count == 0) return false;
  return sum / count < 128;
}

/// Draws the region's text (horizontal wrap or vertical columns). [outline],
/// when set, is painted as a stroke behind the fill so the text stays readable
/// on a cleaned background without an opaque plate.
void _drawText(
  ui.Canvas canvas,
  TranslatedRegion region,
  ui.Rect rect,
  ui.Color color, {
  ui.Color? outline,
  ui.Color? background,
}) {
  if (rect.width <= 4 || rect.height <= 4 || region.text.trim().isEmpty) {
    return;
  }
  canvas.save();
  canvas.clipRect(rect);
  try {
    if (_prefersVertical(region.text, rect)) {
      _drawVerticalText(
        canvas,
        region.text,
        color,
        rect,
        outline: outline,
        background: background,
        lineHeight: region.lineHeight,
      );
      return;
    }
    var maxWidth = rect.width - 4;
    var maxHeight = rect.height - 4;
    var size = _fitFontSize(
      region.text,
      maxWidth,
      maxHeight,
      lineHeight: region.lineHeight,
    );
    if (outline != null) {
      var strokePainter = _horizontalPainter(
        region.text,
        size,
        _strokeStyle(outline, size),
        maxWidth,
      );
      var strokeOffset = ui.Offset(
        rect.left + (rect.width - strokePainter.width) / 2,
        rect.top + (rect.height - strokePainter.height) / 2,
      );
      strokePainter.paint(canvas, strokeOffset);
      strokePainter.dispose();
    }
    var painter = _horizontalPainter(
      region.text,
      size,
      _fillStyle(color, size).copyWith(backgroundColor: background),
      maxWidth,
    );
    var offset = ui.Offset(
      rect.left + (rect.width - painter.width) / 2,
      rect.top + (rect.height - painter.height) / 2,
    );
    painter.paint(canvas, offset);
    painter.dispose();
  } finally {
    canvas.restore();
  }
}

/// Stroke width scales with the glyph so the outline reads at any size.
double _strokeWidth(double fontSize) => math.max(1.5, fontSize * 0.14);

/// Hard floor for the shrink-to-fit search. Nothing below this is legible, and
/// without it a box the text can never fit into makes the search unbounded.
const _minGlyphSize = 4.0;

/// Narrowest width [_horizontalPainter] will lay out at. The fit test must use
/// this, not the caller's box: `TextPainter.width` reports the layout
/// constraint, so comparing against a narrower value is never satisfiable.
const _minLayoutWidth = 8.0;

TextStyle _fillStyle(ui.Color color, double fontSize) => TextStyle(
  color: color,
  fontSize: fontSize,
  height: 1.2,
  fontWeight: FontWeight.w500,
);

TextStyle _strokeStyle(ui.Color outline, double fontSize) => TextStyle(
  fontSize: fontSize,
  height: 1.2,
  fontWeight: FontWeight.w500,
  foreground: ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = _strokeWidth(fontSize)
    ..strokeJoin = ui.StrokeJoin.round
    ..color = outline,
);

TextPainter _horizontalPainter(
  String text,
  double fontSize,
  TextStyle style,
  double maxWidth,
) {
  var painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  );
  painter.layout(maxWidth: math.max(_minLayoutWidth, maxWidth));
  return painter;
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
/// character per cell, wrapping to a new column on the left when full. When
/// [outline] is set each glyph is stroked behind its fill for legibility.
void _drawVerticalText(
  ui.Canvas canvas,
  String text,
  ui.Color color,
  ui.Rect rect, {
  ui.Color? outline,
  ui.Color? background,
  int lineHeight = 0,
}) {
  var chars = text.runes
      .map((r) => String.fromCharCode(r))
      .where((c) => c.trim().isNotEmpty)
      .toList();
  if (chars.isEmpty) return;

  var maxWidth = rect.width - 4;
  var maxHeight = rect.height - 4;

  TextPainter glyph(String c, double fontSize, TextStyle style) {
    var painter = TextPainter(
      text: TextSpan(text: c, style: style),
      textDirection: TextDirection.ltr,
    );
    painter.layout();
    return painter;
  }

  // Cap by the original lettering size when known, so a small vertical caption
  // stays small instead of growing to fill the column width.
  var cap = 42.0;
  if (lineHeight > 0) {
    cap = math.min(cap, math.max(10.0, lineHeight * 0.9));
  }
  var upper = math.max(10.0, math.min(cap, maxWidth * 0.9));
  var size = upper;
  var chosen = _minGlyphSize;
  var perColumn = 1;
  var columns = chars.length;
  while (true) {
    var cell = size * 1.15;
    perColumn = math.max(1, (maxHeight / cell).floor());
    columns = (chars.length / perColumn).ceil();
    if (columns * cell <= maxWidth || size <= _minGlyphSize) {
      chosen = math.max(_minGlyphSize, size);
      break;
    }
    size *= 0.8;
  }

  var cellH = chosen * 1.15;
  var cellW = chosen * 1.15;
  perColumn = math.max(1, (maxHeight / cellH).floor());
  columns = (chars.length / perColumn).ceil();

  var blockW = columns * cellW;
  var blockH = math.min(maxHeight, perColumn * cellH);
  var startRight = rect.left + (rect.width + blockW) / 2;
  var top = rect.top + (rect.height - blockH) / 2;

  var fillStyle = _fillStyle(
    color,
    chosen,
  ).copyWith(height: 1.0, backgroundColor: background);
  var strokeStyle = outline == null
      ? null
      : _strokeStyle(outline, chosen).copyWith(height: 1.0);

  for (var col = 0; col < columns; col++) {
    var colCenterX = startRight - (col + 0.5) * cellW;
    for (var row = 0; row < perColumn; row++) {
      var index = col * perColumn + row;
      if (index >= chars.length) break;
      var dyBase = top + row * cellH;
      if (strokeStyle != null) {
        var sp = glyph(chars[index], chosen, strokeStyle);
        sp.paint(
          canvas,
          ui.Offset(
            colCenterX - sp.width / 2,
            dyBase + (cellH - sp.height) / 2,
          ),
        );
        sp.dispose();
      }
      var painter = glyph(chars[index], chosen, fillStyle);
      var dx = colCenterX - painter.width / 2;
      var dy = dyBase + (cellH - painter.height) / 2;
      painter.paint(canvas, ui.Offset(dx, dy));
      painter.dispose();
    }
  }
}

/// Largest font size whose wrapped horizontal layout fits [maxWidth]x[maxHeight].
///
/// [lineHeight] is the original lettering's approximate size (px, 0 = unknown).
/// When known it caps the glyph size so the translation stays close to the
/// source scale — a small caption stays small instead of being blown up to fill
/// the detected box. The detector's line box already spans the full line with
/// leading and CJK glyphs fill the em, so the cap sits slightly *below* the box
/// height (0.9x) to keep the translation from reading larger than the source.
double _fitFontSize(
  String text,
  double maxWidth,
  double maxHeight, {
  int lineHeight = 0,
}) {
  var cap = 42.0;
  if (lineHeight > 0) {
    cap = math.min(cap, math.max(10.0, lineHeight * 0.9));
  }
  var upper = math.max(10.0, math.min(cap, maxHeight * 0.8));
  var layoutWidth = math.max(_minLayoutWidth, maxWidth);
  var size = upper;
  while (size > _minGlyphSize) {
    var painter = _horizontalPainter(
      text,
      size,
      _fillStyle(const ui.Color(0xFF000000), size),
      maxWidth,
    );
    var fits = painter.height <= maxHeight && painter.width <= layoutWidth;
    painter.dispose();
    if (fits) return size;
    size *= 0.8;
  }
  return _minGlyphSize;
}

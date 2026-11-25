import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/widgets.dart';
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
  void Function(List<TranslatedRegion>)? onSkipped,
}) async {
  var visible = List<int>.empty();
  var backed = <int>{};
  if (regions.isNotEmpty) {
    var (cleaned, indices, fallback) = await compute(_cleanPage, (
      decoded,
      regions,
      mode,
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
  final layouts = translationLayoutRects(regions);
  try {
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    canvas.drawImage(base, ui.Offset.zero, ui.Paint());
    for (var index in visible) {
      var region = regions[index];
      final layout = layouts[index];
      if (backed.contains(index)) {
        final dark = _regionIsDark(decoded, region.rect);
        _drawText(
          canvas,
          region,
          layout,
          dark ? const ui.Color(0xFFF5F5F5) : const ui.Color(0xFF202020),
          background: dark
              ? const ui.Color(0xFF202020)
              : const ui.Color(0xFFF5F5F5),
        );
      } else if (mode == InpaintMode.patch) {
        _drawText(canvas, region, layout, ui.Color(region.textColor));
      } else {
        _drawErasedRegion(canvas, decoded, region, layout);
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
  (RgbaImage, List<TranslatedRegion>, InpaintMode) work,
) {
  var (image, regions, mode) = work;
  var visible = <int>[];
  var backed = <int>[];
  final source = RgbaImage(
    image.width,
    image.height,
    Uint8List.fromList(image.pixels),
  );
  final textRegions = <(int, int, int, int), IntRect>{
    for (final region in regions)
      for (final r in region.eraseRects) (r.left, r.top, r.right, r.bottom): r,
  }.values.toList();
  final erased = <(int, int, int, int), bool>{};
  for (var index = 0; index < regions.length; index++) {
    var region = regions[index];
    if (region.text.trim().isEmpty ||
        region.rect.width <= 4 ||
        region.rect.height <= 4) {
      continue;
    }
    var complete = region.eraseRects.isNotEmpty;
    for (var line in region.eraseRects) {
      final key = (line.left, line.top, line.right, line.bottom);
      if (erased.containsKey(key)) {
        complete = complete && erased[key]!;
        continue;
      }
      var flat = mode == InpaintMode.patch;
      var mask = TextInpainter.computeMask(
        source,
        line,
        flatFill: flat,
        textRegions: textRegions,
      );
      if (mask == null && flat) {
        flat = false;
        mask = TextInpainter.computeMask(
          source,
          line,
          textRegions: textRegions,
        );
      }
      erased[key] = mask != null;
      if (mask == null) {
        complete = false;
      } else if (flat) {
        TextInpainter.fillWithBackground(image, mask);
      } else {
        TextInpainter.eraseWithMask(image, mask);
      }
    }
    // A difficult line must not suppress the whole translation. Keep the art
    // in that line and back only the translated glyphs where it is drawn.
    if (!complete) {
      backed.add(index);
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

/// Detector padding can make adjacent blocks overlap. Divide only that shared
/// layout space; source erasure keeps the original per-line rectangles.
@visibleForTesting
List<ui.Rect> translationLayoutRects(List<TranslatedRegion> regions) {
  final result = regions.map(_rectOf).toList();
  for (var i = 0; i < result.length; i++) {
    if (regions[i].text.trim().isEmpty ||
        result[i].width <= 4 ||
        result[i].height <= 4) {
      continue;
    }
    for (var j = i + 1; j < result.length; j++) {
      if (regions[j].text.trim().isEmpty ||
          result[j].width <= 4 ||
          result[j].height <= 4) {
        continue;
      }
      var a = result[i], b = result[j];
      final overlap = a.intersect(b);
      if (overlap.width <= 0 || overlap.height <= 0) continue;
      final across =
          overlap.width / math.min(a.width, b.width) <=
          overlap.height / math.min(a.height, b.height);
      if (across) {
        final first = a.center.dx <= b.center.dx;
        final left = first ? a : b, right = first ? b : a;
        final boundary = (overlap.left + overlap.right) / 2;
        if (boundary - left.left < 10 || right.right - boundary < 10) continue;
        final l = ui.Rect.fromLTRB(
          left.left,
          left.top,
          boundary - 1,
          left.bottom,
        );
        final r = ui.Rect.fromLTRB(
          boundary + 1,
          right.top,
          right.right,
          right.bottom,
        );
        result[i] = first ? l : r;
        result[j] = first ? r : l;
      } else {
        final first = a.center.dy <= b.center.dy;
        final top = first ? a : b, bottom = first ? b : a;
        final boundary = (overlap.top + overlap.bottom) / 2;
        if (boundary - top.top < 10 || bottom.bottom - boundary < 10) continue;
        final t = ui.Rect.fromLTRB(top.left, top.top, top.right, boundary - 1);
        final btm = ui.Rect.fromLTRB(
          bottom.left,
          boundary + 1,
          bottom.right,
          bottom.bottom,
        );
        result[i] = first ? t : btm;
        result[j] = first ? btm : t;
      }
    }
  }
  return result;
}

/// Erase mode: the base is already clean, so the text only needs a contrast
/// outline (never an opaque plate) to stay readable over minor screentone or
/// gradient the erase left behind.
void _drawErasedRegion(
  ui.Canvas canvas,
  RgbaImage decoded,
  TranslatedRegion region,
  ui.Rect rect,
) {
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
    final columns = sourceTranslationColumns(region, rect);
    if (columns.isNotEmpty) {
      for (final column in columns) {
        final step = column.rect.height / column.glyphs.length;
        _paintVerticalColumn(
          canvas,
          column.glyphs,
          color,
          column.rect.center.dx,
          column.rect.top,
          step,
          math.min(42, math.min(step, column.rect.width) * .92),
          outline: outline,
          background: background,
        );
      }
      return;
    }
    if ((_sourceIsVertical(region.eraseRects) ||
            (rect.height >= rect.width * 1.6 &&
                !region.eraseRects.every(
                  (line) => line.width > line.height,
                ))) &&
        _hasVerticalScript(region.text)) {
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
    var size = fittedTranslationFontSize(
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

/// Small glyphs need proportionally thin outlines to keep adjacent lines apart.
double _strokeWidth(double fontSize) => fontSize * 0.14;

/// A final fallback for exceptionally long replies in tiny cached rectangles.
const _minGlyphSize = 1.0;

/// Keep text layout constraints positive for narrow legacy rectangles.
const _minLayoutWidth = 0.1;

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

/// Fits translated glyphs to the source columns in OCR reading order.
@visibleForTesting
List<({List<String> glyphs, ui.Rect rect})> sourceTranslationColumns(
  TranslatedRegion region,
  ui.Rect layout,
) {
  final lines = region.eraseRects;
  if (!_sourceIsVertical(lines) ||
      (lines.length == 1 && region.sourceText == null) ||
      !_hasVerticalScript(region.text)) {
    return [];
  }
  final boxes = [
    for (final r in lines)
      ui.Rect.fromLTRB(
        r.left.toDouble(),
        r.top.toDouble(),
        r.right.toDouble(),
        r.bottom.toDouble(),
      ).intersect(layout),
  ];
  if (boxes.any((r) => r.width <= 4 || r.height < r.width)) return [];

  final glyphs = _verticalGlyphs(region.text);
  final parts = region.sourceText?.trim().split(RegExp(r'\s+'));
  // Line OCR joins its results with spaces. Older results or block OCR may
  // lack those boundaries; use column proportions when they are unavailable.
  final hasLineText = parts != null && parts.length == lines.length;
  final weights = hasLineText
      ? [for (final part in parts) part.characters.length.toDouble()]
      : [for (final r in lines) r.height / r.width];
  var total = weights.reduce((a, b) => a + b);
  if (total <= 0) return [];
  if (hasLineText && glyphs.length != total) {
    int trailingMarks(List<String> chars) =>
        chars.reversed.takeWhile((c) => !_letterOrDigit.hasMatch(c)).length;
    final difference = glyphs.length - total;
    if (difference ==
        trailingMarks(glyphs) - trailingMarks(_verticalGlyphs(parts.last))) {
      // A provider may add or remove final punctuation without changing any
      // preceding column break.
      weights.last += difference;
      total = glyphs.length.toDouble();
    }
  }
  final ends = <int>[];
  var cumulative = 0.0;
  var pitch = double.infinity;
  for (var i = 0; i < boxes.length; i++) {
    cumulative += weights[i];
    final end = (glyphs.length * cumulative / total).round();
    final count = end - (ends.isEmpty ? 0 : ends.last);
    ends.add(end);
    if (count > 0) {
      final box = boxes[i];
      // OCR includes a margin above and below the printed glyphs.
      pitch = math.min(
        pitch,
        math.min(
          box.width,
          (box.height - box.width * .5) /
              math.max(count, hasLineText ? weights[i] : count),
        ),
      );
      for (var j = 0; j < i; j++) {
        final other = boxes[j];
        if (other.overlaps(box)) {
          pitch = math.min(pitch, (box.center.dx - other.center.dx).abs());
        }
      }
    }
  }
  // A much longer translation fits better by wrapping within the whole bubble.
  final sourceSize = region.lineHeight > 0
      ? region.lineHeight.toDouble()
      : boxes.map((r) => r.width).reduce(math.min);
  if (pitch < math.min(10.0, sourceSize * .5)) return [];
  final columns = <({List<String> glyphs, ui.Rect rect})>[];
  var start = 0;
  for (var i = 0; i < boxes.length; i++) {
    final end = ends[i];
    if (end == start) continue;
    final box = boxes[i];
    final top = box.top + box.width * .25;
    columns.add((
      glyphs: glyphs.sublist(start, end),
      rect: ui.Rect.fromLTWH(box.left, top, box.width, pitch * (end - start)),
    ));
    start = end;
  }
  return columns;
}

List<String> _verticalGlyphs(String text) =>
    text.characters.where((c) => c.trim().isNotEmpty).toList();

bool _sourceIsVertical(List<IntRect> lines) =>
    lines.any((r) => r.height >= r.width * 1.5) &&
    lines.every((r) => r.width > 0 && r.height >= r.width);

// Kana share their prolonged sound mark, whose primary script is Common.
final _verticalLetter = RegExp(
  r'[\p{Script_Extensions=Han}\p{Script_Extensions=Hiragana}'
  r'\p{Script_Extensions=Katakana}\p{Script_Extensions=Hangul}]',
  unicode: true,
);
final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _hasVerticalScript(String text) {
  var total = 0, cjk = 0;
  for (final letter in _letterOrDigit.allMatches(text)) {
    total++;
    if (_verticalLetter.hasMatch(letter[0]!)) cjk++;
  }
  return cjk > 0 && cjk >= total * .7;
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
  var chars = _verticalGlyphs(text);
  if (chars.isEmpty) return;

  var maxWidth = rect.width - 4;
  var maxHeight = rect.height - 4;

  // Cap by the original lettering size when known, so a small vertical caption
  // stays small instead of growing to fill the column width.
  var cap = 42.0;
  if (lineHeight > 0) {
    cap = math.min(cap, math.max(10.0, lineHeight * 0.9));
  }
  var upper = math.max(10.0, math.min(cap, maxWidth * 0.9));
  var low = _minGlyphSize, high = upper;
  var chosen = low;
  var perColumn = 1;
  var columns = chars.length;
  // A fixed number of measurements avoids 20% jumps that make a translation
  // needlessly small when it is just too wide for one more column.
  for (var attempt = 0; attempt < 10; attempt++) {
    final size = attempt == 0 ? high : (low + high) / 2;
    var cell = size * 1.15;
    perColumn = math.max(1, (maxHeight / cell).floor());
    columns = (chars.length / perColumn).ceil();
    if (columns * cell <= maxWidth && cell <= maxHeight) {
      chosen = size;
      low = size;
      if (attempt == 0) break;
    } else {
      high = size;
    }
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
    final first = col * perColumn;
    _paintVerticalColumn(
      canvas,
      chars.sublist(first, math.min(first + perColumn, chars.length)),
      color,
      startRight - (col + .5) * cellW,
      top,
      cellH,
      chosen,
      outline: outline,
      background: background,
    );
  }
}

void _paintVerticalColumn(
  ui.Canvas canvas,
  List<String> glyphs,
  ui.Color color,
  double centerX,
  double top,
  double step,
  double fontSize, {
  ui.Color? outline,
  ui.Color? background,
}) {
  final styles = [
    if (outline != null) _strokeStyle(outline, fontSize).copyWith(height: 1),
    _fillStyle(
      color,
      fontSize,
    ).copyWith(height: 1, backgroundColor: background),
  ];
  for (var i = 0; i < glyphs.length; i++) {
    final glyph = glyphs[i];
    var center = ui.Offset(centerX, top + (i + .5) * step);
    final rotate = glyph == 'ー' || glyph == 'ｰ';
    if (rotate) {
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(math.pi / 2);
      center = ui.Offset.zero;
    }
    for (final style in styles) {
      final painter = TextPainter(
        text: TextSpan(text: glyph == '…' ? '⋮' : glyph, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(
        canvas,
        center - ui.Offset(painter.width / 2, painter.height / 2),
      );
      painter.dispose();
    }
    if (rotate) canvas.restore();
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
@visibleForTesting
double fittedTranslationFontSize(
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
  var low = _minGlyphSize, high = upper;
  for (var attempt = 0; attempt < 10; attempt++) {
    final size = attempt == 0 ? high : (low + high) / 2;
    var painter = _horizontalPainter(
      text,
      size,
      _fillStyle(const ui.Color(0xFF000000), size),
      maxWidth,
    );
    // The painter width is clamped to the constraint even if a glyph spills.
    // Line metrics retain the actual glyph width.
    var fits =
        painter.height <= maxHeight &&
        painter.computeLineMetrics().every((line) => line.width <= layoutWidth);
    painter.dispose();
    if (fits) {
      low = size;
      if (attempt == 0) return size;
    } else {
      high = size;
    }
  }
  return low;
}

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Fraction of the detected region the text is laid out within. The region is
/// the axis-aligned bounds of a round/oval bubble, so its corners sit outside
/// the bubble; keeping the text inside this centered inset stops it spilling
/// over the bubble edge onto the artwork.
const _fillRatio = 0.82;

/// Upper bound on the translated glyph size. The original English lettering is
/// small; letting CJK text grow to fill a large bubble makes it overpower the
/// panel and, once wrapped, spill past the bubble. A calm cap keeps it readable
/// without dominating.
const _maxFontSize = 30.0;

/// Renders the translated page: draws the original image, covers each text
/// region with a rounded patch in the sampled background colour, then lays the
/// translated text inside it. Returns PNG bytes.
Future<Uint8List> renderTranslatedPage(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions,
) async {
  var buffer = await ui.ImmutableBuffer.fromUint8List(originalBytes);
  var descriptor = await ui.ImageDescriptor.encoded(buffer);
  var codec = await descriptor.instantiateCodec(
    targetWidth: decoded.width,
    targetHeight: decoded.height,
  );
  var frame = await codec.getNextFrame();
  var base = frame.image;
  try {
    var recorder = ui.PictureRecorder();
    var canvas = ui.Canvas(recorder);
    canvas.drawImage(base, ui.Offset.zero, ui.Paint());
    for (var region in regions) {
      _drawRegion(canvas, region);
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

/// Covers the region with an opaque rounded plate (sampled background colour)
/// sized to the text actually laid out, then draws the text. The plate hugs the
/// text rather than filling the whole detected box, so it no longer stamps a
/// large block over the panel; a feathered halo blends its edge into the art.
void _drawRegion(ui.Canvas canvas, TranslatedRegion region) {
  var rect = _rectOf(region);
  var background = ui.Color(region.backgroundColor);
  var textColor = ui.Color(region.textColor);

  var layout = _layoutText(region.text, rect);

  // Plate bounds: the laid-out text plus a small padding, clamped to the
  // detected region so a short translation gets a small plate instead of one
  // spanning the whole bubble box.
  var pad = math.max(3.0, layout.fontSize * 0.35);
  var plate = ui.Rect.fromCenter(
    center: rect.center,
    width: math.min(rect.width + pad, layout.width + pad * 2),
    height: math.min(rect.height + pad, layout.height + pad * 2),
  );
  var radius = ui.Radius.circular(math.min(plate.shortestSide * 0.5, 12.0));

  var sigma = math.max(1.5, pad * 0.6);
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(plate.inflate(sigma * 0.5), radius),
    ui.Paint()
      ..color = background
      ..maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, sigma),
  );
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(plate, radius),
    ui.Paint()..color = background,
  );

  layout.paint(canvas, rect.center, textColor);
}

/// The result of fitting a region's text: a horizontal wrapped block or a
/// vertical column block. Knows its own size (for the backing plate) and can
/// paint itself centered on a point.
abstract class _TextLayout {
  double get width;
  double get height;
  double get fontSize;
  void paint(ui.Canvas canvas, ui.Offset center, ui.Color color);
}

_TextLayout _layoutText(String text, ui.Rect rect) {
  var maxWidth = rect.width * _fillRatio;
  var maxHeight = rect.height * _fillRatio;
  if (_prefersVertical(text, rect)) {
    return _VerticalLayout(text, maxWidth, maxHeight);
  }
  return _HorizontalLayout(text, maxWidth, maxHeight);
}

TextStyle _style(ui.Color color, double fontSize, double height) => TextStyle(
  color: color,
  fontSize: fontSize,
  height: height,
  fontWeight: FontWeight.w500,
);

/// Horizontal wrapped text fitted to the inset area.
class _HorizontalLayout implements _TextLayout {
  _HorizontalLayout(this.text, this.maxWidth, this.maxHeight) {
    fontSize = _fitFontSize(text, maxWidth, maxHeight);
  }

  final String text;
  final double maxWidth;
  final double maxHeight;
  @override
  late final double fontSize;

  TextPainter _painter(ui.Color color) {
    var painter = TextPainter(
      text: TextSpan(text: text, style: _style(color, fontSize, 1.2)),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    painter.layout(maxWidth: math.max(8, maxWidth));
    return painter;
  }

  @override
  double get width {
    var p = _painter(const ui.Color(0xFF000000));
    var w = p.width;
    p.dispose();
    return w;
  }

  @override
  double get height {
    var p = _painter(const ui.Color(0xFF000000));
    var h = p.height;
    p.dispose();
    return h;
  }

  @override
  void paint(ui.Canvas canvas, ui.Offset center, ui.Color color) {
    var painter = _painter(color);
    painter.paint(
      canvas,
      ui.Offset(center.dx - painter.width / 2, center.dy - painter.height / 2),
    );
    painter.dispose();
  }
}

/// Vertical right-to-left column text, one character per cell.
class _VerticalLayout implements _TextLayout {
  _VerticalLayout(String text, this.maxWidth, this.maxHeight)
    : chars = text.runes
          .map((r) => String.fromCharCode(r))
          .where((c) => c.trim().isNotEmpty)
          .toList() {
    _fit();
  }

  final List<String> chars;
  final double maxWidth;
  final double maxHeight;
  @override
  late double fontSize;
  late int _perColumn;
  late int _columns;

  void _fit() {
    var upper = math.max(10.0, math.min(_maxFontSize, maxWidth * 0.9));
    const lower = 7.0;
    var size = upper;
    var chosen = lower;
    while (size >= lower) {
      var cell = size * 1.15;
      var perColumn = math.max(1, (maxHeight / cell).floor());
      var columns = (chars.length / perColumn).ceil();
      chosen = size;
      if (columns * cell <= maxWidth) break;
      size -= 1.5;
    }
    fontSize = chosen;
    var cell = chosen * 1.15;
    _perColumn = math.max(1, (maxHeight / cell).floor());
    _columns = (chars.length / _perColumn).ceil();
  }

  @override
  double get width => _columns * fontSize * 1.15;

  @override
  double get height => math.min(maxHeight, _perColumn * fontSize * 1.15);

  @override
  void paint(ui.Canvas canvas, ui.Offset center, ui.Color color) {
    if (chars.isEmpty) return;
    var cell = fontSize * 1.15;
    var startRight = center.dx + width / 2;
    var top = center.dy - height / 2;
    var style = _style(color, fontSize, 1.0);

    for (var col = 0; col < _columns; col++) {
      var colCenterX = startRight - (col + 0.5) * cell;
      for (var row = 0; row < _perColumn; row++) {
        var index = col * _perColumn + row;
        if (index >= chars.length) break;
        var painter = TextPainter(
          text: TextSpan(text: chars[index], style: style),
          textDirection: TextDirection.ltr,
        );
        painter.layout();
        var dx = colCenterX - painter.width / 2;
        var dy = top + row * cell + (cell - painter.height) / 2;
        painter.paint(canvas, ui.Offset(dx, dy));
        painter.dispose();
      }
    }
  }
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

/// Largest font size whose wrapped horizontal layout fits [maxWidth]x[maxHeight].
double _fitFontSize(String text, double maxWidth, double maxHeight) {
  var upper = math.max(10.0, math.min(_maxFontSize, maxHeight * 0.8));
  const lower = 7.0;
  var size = upper;
  while (size > lower) {
    var painter = TextPainter(
      text: TextSpan(
        text: text,
        style: _style(const ui.Color(0xFF000000), size, 1.2),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    painter.layout(maxWidth: math.max(8, maxWidth));
    var fits = painter.height <= maxHeight && painter.width <= maxWidth;
    painter.dispose();
    if (fits) return size;
    size -= 1.5;
  }
  return lower;
}

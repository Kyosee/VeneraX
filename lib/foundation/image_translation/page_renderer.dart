import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Renders the translated page: the original image with each text region
/// covered by a rounded patch in the sampled background color and the
/// translated text laid out to fit inside it. Returns PNG bytes.
Future<Uint8List> renderTranslatedPage(
  Uint8List originalBytes,
  RgbaImage decoded,
  List<TranslatedRegion> regions,
) async {
  // Decode again through the codec at the pipeline's working resolution so
  // the drawn base matches the region coordinates.
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

void _drawRegion(ui.Canvas canvas, TranslatedRegion region) {
  var rect = ui.Rect.fromLTRB(
    region.rect.left.toDouble(),
    region.rect.top.toDouble(),
    region.rect.right.toDouble(),
    region.rect.bottom.toDouble(),
  );
  var background = ui.Color(region.backgroundColor);

  // Coverage margin scales with the region so the original text — which
  // routinely bleeds a few pixels past the detected box — is fully hidden
  // instead of leaving edges/corners poking out. A fixed 2px was far too
  // small for large bubbles.
  var minSide = math.min(rect.width, rect.height);
  var margin = math.max(3.0, minSide * 0.14);
  var core = rect.inflate(margin);

  // Small corner radius: a large radius leaves the original text's square
  // corners uncovered (the visible "漏边角"). Keep corners nearly square.
  var radius = ui.Radius.circular(math.min(margin, 4.0));

  // Feathered halo first: a blurred patch in the sampled surrounding color
  // blends the fill into the artwork, so a semi-transparent or textured
  // bubble no longer gets a hard, pasted-on opaque rectangle. The opaque
  // core drawn on top still guarantees the original text is covered.
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

  var painter = _fitText(
    region.text,
    ui.Color(region.textColor),
    rect.width - 4,
    rect.height - 4,
  );
  var offset = ui.Offset(
    rect.left + (rect.width - painter.width) / 2,
    rect.top + (rect.height - painter.height) / 2,
  );
  painter.paint(canvas, offset);
  painter.dispose();
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

  // Start from a size proportional to the region and shrink until it fits.
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

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';

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
  var background = ui.Paint()..color = ui.Color(region.backgroundColor);
  canvas.drawRRect(
    ui.RRect.fromRectAndRadius(rect.inflate(2), const ui.Radius.circular(6)),
    background,
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

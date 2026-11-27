import 'dart:ffi' show FloatPointer;
import 'dart:math' as math;
import 'dart:typed_data';

import 'detector_preprocess.dart';
import 'ort_ffi.dart';
import 'translation_types.dart';

/// PP-OCR DBNet preprocessing: long side <= 1280 (small/stylized lettering
/// survives better than at the stock 960), multiple of 32, ImageNet
/// normalization. [allowRust] controls use of the optional native backend.
OrtInput prepareDetectorInput(
  RgbaImage tile, {
  bool rotate = false,
  bool allowRust = true,
}) {
  const maxSide = 1280.0;
  var scale = math.min(1.0, maxSide / math.max(tile.width, tile.height));
  int round32(double v) => math.max(32, (v / 32).round() * 32);
  var inW = round32((rotate ? tile.height : tile.width) * scale);
  var inH = round32((rotate ? tile.width : tile.height) * scale);
  final shape = [1, 3, inH, inW];
  Float32List dartTensor() => _dartDetectorTensor(tile, inW, inH, rotate);
  if (!allowRust ||
      !canUseRustDetector(tile.pixels.lengthInBytes, 3 * inH * inW)) {
    return OrtInput.float32(dartTensor(), shape);
  }
  return OrtInput.fillFloat32(shape, (output, count) {
    final filled = fillRustDetectorTensor(
      tile.pixels,
      tile.width,
      tile.height,
      inW,
      inH,
      output,
      count,
      rotate: rotate,
    );
    if (!filled) output.asTypedList(count).setAll(0, dartTensor());
  });
}

Float32List _dartDetectorTensor(RgbaImage tile, int inW, int inH, bool rotate) {
  var resized = resizeTextLine(
    tile,
    IntRect(0, 0, tile.width, tile.height),
    inW,
    inH,
    rotate: rotate,
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
  return tensor;
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
        var p00 = src
            .pixels[((region.top + y0) * src.width + region.left + x0) * 4 + c];
        var p01 = src
            .pixels[((region.top + y0) * src.width + region.left + x1) * 4 + c];
        var p10 = src
            .pixels[((region.top + y1) * src.width + region.left + x0) * 4 + c];
        var p11 = src
            .pixels[((region.top + y1) * src.width + region.left + x1) * 4 + c];
        var top = p00 + (p01 - p00) * wx;
        var bottom = p10 + (p11 - p10) * wx;
        out[outIndex + c] = (top + (bottom - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}

/// Resamples [region] to [outW]x[outH] RGBA. With [rotate] the region is
/// turned 90° counter-clockwise first, so a vertical column reads left to
/// right with its top glyph first.
Uint8List resizeTextLine(
  RgbaImage src,
  IntRect region,
  int outW,
  int outH, {
  bool rotate = false,
}) {
  if (!rotate) return _resizeRegion(src, region, outW, outH);
  var out = Uint8List(outW * outH * 4);
  var srcW = region.width;
  var srcH = region.height;
  for (var y = 0; y < outH; y++) {
    // Output rows walk the source columns from right to left.
    var fx = srcW - 0.5 - (y + 0.5) * srcW / outH;
    var x0 = fx.floor().clamp(0, srcW - 1);
    var x1 = (x0 + 1).clamp(0, srcW - 1);
    var wx = fx - fx.floor();
    for (var x = 0; x < outW; x++) {
      // Output columns walk the source rows from top to bottom.
      var fy = (x + 0.5) * srcH / outW - 0.5;
      var y0 = fy.floor().clamp(0, srcH - 1);
      var y1 = (y0 + 1).clamp(0, srcH - 1);
      var wy = fy - fy.floor();
      var outIndex = (y * outW + x) * 4;
      for (var c = 0; c < 4; c++) {
        int px(int sy, int sx) =>
            src.pixels[((region.top + sy) * src.width + region.left + sx) * 4 +
                c];
        var top = px(y0, x0) + (px(y0, x1) - px(y0, x0)) * wx;
        var bottom = px(y1, x0) + (px(y1, x1) - px(y1, x0)) * wx;
        out[outIndex + c] = (top + (bottom - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}

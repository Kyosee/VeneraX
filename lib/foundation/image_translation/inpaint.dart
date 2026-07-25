import 'dart:math' as math;
import 'dart:typed_data';

import 'package:venera/foundation/image_translation/translation_types.dart';

/// Working window + per-pixel 0/1 stroke mask for one text region.
class TextMask {
  TextMask(this.left, this.top, this.rw, this.rh, this.mask);

  final int left;
  final int top;
  final int rw;
  final int rh;
  final Uint8List mask;
}

/// Pure-Dart text removal: erases the original lettering inside each text region
/// and reconstructs the pixels underneath from the surrounding artwork, so the
/// translated text sits on a clean background instead of a pasted-on patch.
/// Keeps bubble shape, screentone and gradients intact, at zero model download.
///
/// No `dart:ui` — runs on the render path and could run in the worker isolate,
/// and stays unit-testable with a plain RGBA buffer. [image.pixels] is mutated
/// in place to avoid cloning a possibly-huge page.
abstract final class TextInpainter {
  static RgbaImage erase(RgbaImage image, List<IntRect> regions) {
    for (var rect in regions) {
      var m = computeMask(image, rect);
      if (m == null) continue;
      eraseWithMask(image, m);
    }
    return image;
  }

  /// Erases a single already-computed mask. Used by the AI path as a fallback
  /// when the model rejects a tile, so both paths share the fill.
  static void eraseWithMask(RgbaImage image, TextMask m) {
    _fillNearest(image.pixels, image.width, m.left, m.top, m.rw, m.rh, m.mask);
    _relax(image.pixels, image.width, m.left, m.top, m.rw, m.rh, m.mask, 2);
  }

  /// Splits the region's luminance (Otsu) into background and text strokes,
  /// then dilates to swallow anti-aliased edges. Returns null when nothing
  /// plausible should be erased (too small, or the "text" class swallows the
  /// window — a near-uniform crop or heavy screentone the threshold misread).
  /// Shared by the Dart fill and the AI model path so both agree on what is text.
  static TextMask? computeMask(RgbaImage image, IntRect region) {
    var w = image.width;
    var h = image.height;
    // Region plus a border: the fill needs known pixels to borrow, and the ring
    // sampling needs to see the true background.
    var pad =
        math.max(4, (math.min(region.width, region.height) * 0.25).round());
    var left = (region.left - pad).clamp(0, w - 1);
    var top = (region.top - pad).clamp(0, h - 1);
    var right = (region.right + pad).clamp(1, w);
    var bottom = (region.bottom + pad).clamp(1, h);
    var rw = right - left;
    var rh = bottom - top;
    if (rw < 6 || rh < 6) return null;

    var pixels = image.pixels;
    var n = rw * rh;

    var lum = Uint8List(n);
    for (var y = 0; y < rh; y++) {
      var srcRow = (top + y) * w + left;
      var dstRow = y * rw;
      for (var x = 0; x < rw; x++) {
        var i = (srcRow + x) * 4;
        lum[dstRow + x] =
            (0.299 * pixels[i] + 0.587 * pixels[i + 1] + 0.114 * pixels[i + 2])
                .round()
                .clamp(0, 255);
      }
    }

    var bgLum = _ringMeanLuminance(lum, rw, rh);
    var threshold = _otsu(lum);

    // Class means around the split, so the text class is chosen by which mean
    // sits farther from the background — robust when the threshold lands on the
    // background value itself (a clean two-tone crop), where a threshold sign
    // test would misclassify.
    var (lowMean, highMean) = _classMeans(lum, threshold);
    var bgIsHigh = (highMean - bgLum).abs() <= (lowMean - bgLum).abs();
    var textMean = bgIsHigh ? lowMean : highMean;

    // A contrast margin keeps low-contrast noise from being erased.
    const minMargin = 24;
    var mask = Uint8List(n);
    var maskCount = 0;
    var textIsDark = textMean < bgLum;
    for (var i = 0; i < n; i++) {
      var l = lum[i];
      var isText = textIsDark
          ? l <= threshold && (bgLum - l) >= minMargin
          : l > threshold && (l - bgLum) >= minMargin;
      if (isText) {
        mask[i] = 1;
        maskCount++;
      }
    }
    if (maskCount == 0 || maskCount > n * 0.6) return null;

    mask = _dilate(mask, rw, rh, 2);
    return TextMask(left, top, rw, rh, mask);
  }

  static int _ringMeanLuminance(Uint8List lum, int rw, int rh) {
    var sum = 0, count = 0;
    for (var x = 0; x < rw; x++) {
      sum += lum[x];
      sum += lum[(rh - 1) * rw + x];
      count += 2;
    }
    for (var y = 1; y < rh - 1; y++) {
      sum += lum[y * rw];
      sum += lum[y * rw + rw - 1];
      count += 2;
    }
    return count == 0 ? 255 : (sum / count).round();
  }

  /// Otsu's method: luminance threshold maximising between-class variance.
  static int _otsu(Uint8List lum) {
    var hist = Int32List(256);
    for (var l in lum) {
      hist[l]++;
    }
    var total = lum.length;
    var sum = 0.0;
    for (var t = 0; t < 256; t++) {
      sum += t * hist[t];
    }
    var sumB = 0.0;
    var wB = 0;
    var maxVar = -1.0;
    var threshold = 127;
    for (var t = 0; t < 256; t++) {
      wB += hist[t];
      if (wB == 0) continue;
      var wF = total - wB;
      if (wF == 0) break;
      sumB += t * hist[t];
      var mB = sumB / wB;
      var mF = (sum - sumB) / wF;
      var between = wB * wF * (mB - mF) * (mB - mF);
      if (between > maxVar) {
        maxVar = between;
        threshold = t;
      }
    }
    return threshold;
  }

  /// Mean luminance of the pixels at or below [threshold] and above it. Empty
  /// classes fall back to the threshold value.
  static (double, double) _classMeans(Uint8List lum, int threshold) {
    var loSum = 0, loN = 0, hiSum = 0, hiN = 0;
    for (var l in lum) {
      if (l <= threshold) {
        loSum += l;
        loN++;
      } else {
        hiSum += l;
        hiN++;
      }
    }
    var lo = loN == 0 ? threshold.toDouble() : loSum / loN;
    var hi = hiN == 0 ? threshold.toDouble() : hiSum / hiN;
    return (lo, hi);
  }

  /// Separable box dilation (two 1-D passes).
  static Uint8List _dilate(Uint8List mask, int rw, int rh, int radius) {
    var tmp = Uint8List(mask.length);
    for (var y = 0; y < rh; y++) {
      var row = y * rw;
      for (var x = 0; x < rw; x++) {
        var on = false;
        for (var dx = -radius; dx <= radius && !on; dx++) {
          var nx = x + dx;
          if (nx >= 0 && nx < rw && mask[row + nx] == 1) on = true;
        }
        tmp[row + x] = on ? 1 : 0;
      }
    }
    var out = Uint8List(mask.length);
    for (var x = 0; x < rw; x++) {
      for (var y = 0; y < rh; y++) {
        var on = false;
        for (var dy = -radius; dy <= radius && !on; dy++) {
          var ny = y + dy;
          if (ny >= 0 && ny < rh && tmp[ny * rw + x] == 1) on = true;
        }
        out[y * rw + x] = on ? 1 : 0;
      }
    }
    return out;
  }

  /// Fills each masked pixel with its nearest non-masked colour via a two-pass
  /// chamfer sweep. Clean flat fill on solid bubbles, good over gradients.
  static void _fillNearest(
    Uint8List pixels,
    int imgW,
    int left,
    int top,
    int rw,
    int rh,
    Uint8List mask,
  ) {
    const inf = 1 << 29;
    var dist = Int32List(rw * rh);
    var srcOf = Int32List(rw * rh);
    for (var i = 0; i < rw * rh; i++) {
      if (mask[i] == 0) {
        dist[i] = 0;
        var x = i % rw, y = i ~/ rw;
        srcOf[i] = (top + y) * imgW + (left + x);
      } else {
        dist[i] = inf;
        srcOf[i] = -1;
      }
    }

    void consider(int i, int fromIndex, int stepCost) {
      if (dist[fromIndex] >= inf) return;
      var nd = dist[fromIndex] + stepCost;
      if (nd < dist[i]) {
        dist[i] = nd;
        srcOf[i] = srcOf[fromIndex];
      }
    }

    // Chamfer weights 3 (orthogonal) / 4 (diagonal).
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        var i = y * rw + x;
        if (mask[i] == 0) continue;
        if (x > 0) consider(i, i - 1, 3);
        if (y > 0) consider(i, i - rw, 3);
        if (x > 0 && y > 0) consider(i, i - rw - 1, 4);
        if (x < rw - 1 && y > 0) consider(i, i - rw + 1, 4);
      }
    }
    for (var y = rh - 1; y >= 0; y--) {
      for (var x = rw - 1; x >= 0; x--) {
        var i = y * rw + x;
        if (mask[i] == 0) continue;
        if (x < rw - 1) consider(i, i + 1, 3);
        if (y < rh - 1) consider(i, i + rw, 3);
        if (x < rw - 1 && y < rh - 1) consider(i, i + rw + 1, 4);
        if (x > 0 && y < rh - 1) consider(i, i + rw - 1, 4);
      }
    }

    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        var i = y * rw + x;
        if (mask[i] == 0) continue;
        var src = srcOf[i];
        if (src < 0) continue;
        var di = ((top + y) * imgW + (left + x)) * 4;
        var si = src * 4;
        pixels[di] = pixels[si];
        pixels[di + 1] = pixels[si + 1];
        pixels[di + 2] = pixels[si + 2];
        pixels[di + 3] = pixels[si + 3];
      }
    }
  }

  /// Jacobi relaxation over masked pixels only: softens seams left by the
  /// nearest-fill along the boundary between two source regions.
  static void _relax(
    Uint8List pixels,
    int imgW,
    int left,
    int top,
    int rw,
    int rh,
    Uint8List mask,
    int passes,
  ) {
    for (var p = 0; p < passes; p++) {
      var snap = Uint8List(rw * rh * 4);
      for (var y = 0; y < rh; y++) {
        for (var x = 0; x < rw; x++) {
          var di = ((top + y) * imgW + (left + x)) * 4;
          var oi = (y * rw + x) * 4;
          snap[oi] = pixels[di];
          snap[oi + 1] = pixels[di + 1];
          snap[oi + 2] = pixels[di + 2];
          snap[oi + 3] = pixels[di + 3];
        }
      }
      for (var y = 0; y < rh; y++) {
        for (var x = 0; x < rw; x++) {
          var i = y * rw + x;
          if (mask[i] == 0) continue;
          var r = 0, g = 0, b = 0, a = 0, c = 0;
          void acc(int nx, int ny) {
            if (nx < 0 || ny < 0 || nx >= rw || ny >= rh) return;
            var oi = (ny * rw + nx) * 4;
            r += snap[oi];
            g += snap[oi + 1];
            b += snap[oi + 2];
            a += snap[oi + 3];
            c++;
          }

          acc(x - 1, y);
          acc(x + 1, y);
          acc(x, y - 1);
          acc(x, y + 1);
          if (c == 0) continue;
          var di = ((top + y) * imgW + (left + x)) * 4;
          pixels[di] = (r / c).round();
          pixels[di + 1] = (g / c).round();
          pixels[di + 2] = (b / c).round();
          pixels[di + 3] = (a / c).round();
        }
      }
    }
  }
}

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
  static TextMask? computeMask(
    RgbaImage image,
    IntRect region, {
    StrokeMask? strokeMask,
    bool flatFill = false,
    List<IntRect> textRegions = const [],
  }) {
    var w = image.width;
    var h = image.height;
    // Region plus a border: the fill needs known pixels to borrow, and the ring
    // sampling needs to see the true background.
    var pad = math.max(
      4,
      (math.min(region.width, region.height) * 0.25).round(),
    );
    var left = (region.left - pad).clamp(0, w - 1);
    var top = (region.top - pad).clamp(0, h - 1);
    var right = (region.right + pad).clamp(1, w);
    var bottom = (region.bottom + pad).clamp(1, h);
    var rw = right - left;
    var rh = bottom - top;
    // Distance, colour and component buffers all scale with the window. A
    // corrupted or page-sized cached OCR box must not allocate them.
    if (rw < 6 || rh < 6 || rw * rh > 768 * 1024) return null;

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

    final neighbors = textRegions
        .where(
          (r) =>
              r.right + 2 >= left &&
              r.left - 2 < right &&
              r.bottom + 2 >= top &&
              r.top - 2 < bottom,
        )
        .toList();
    final (bgLum, unstableRing) = _backgroundRing(
      lum,
      rw,
      rh,
      left,
      top,
      neighbors,
      flatFill,
    );
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
    // The padded window is context for background sampling and filling only.
    // Candidate strokes must stay close to the detector's text rectangle;
    // otherwise high-contrast line art in that context gets erased as well.
    var guard = math
        .max(1, (math.min(region.width, region.height) * 0.04).round())
        .clamp(1, 3);
    var allowedLeft = (region.left - guard - left).clamp(0, rw);
    var allowedTop = (region.top - guard - top).clamp(0, rh);
    var allowedRight = (region.right + guard - left).clamp(0, rw);
    var allowedBottom = (region.bottom + guard - top).clamp(0, rh);
    var model = strokeMask;
    var modelCount = 0, overlap = 0;
    for (var y = allowedTop; y < allowedBottom; y++) {
      for (var x = allowedLeft; x < allowedRight; x++) {
        var i = y * rw + x;
        var l = lum[i];
        var isText = textIsDark
            ? l <= threshold && (bgLum - l) >= minMargin
            : l > threshold && (l - bgLum) >= minMargin;
        if (isText) {
          mask[i] = 1;
          maskCount++;
        }
        if (model != null && model.contains(left + x, top + y, w, h)) {
          modelCount++;
          if (isText) overlap++;
        }
      }
    }
    // Judge density against the detector rectangle, not the padded sampling
    // window. Near a page edge that padding is clipped; using the smaller
    // clipped window made dense title lettering look like an invalid mask and
    // left the source text underneath the translation. Still reject a crop
    // where almost the whole OCR rectangle became foreground, which is much
    // more likely to be line art or screentone than glyphs.
    var allowedArea = math.max(
      1,
      (allowedRight - allowedLeft) * (allowedBottom - allowedTop),
    );
    if (maskCount == 0 || maskCount > allowedArea * 0.85) return null;

    // A missed reverse-colour line or a mask covering the whole box should
    // never replace the local detector. A credible mask can isolate text
    // even when the surrounding artwork has two strongly contrasting colours.
    var useModel =
        model != null &&
        overlap >= maskCount * .65 &&
        overlap >= modelCount * .45 &&
        modelCount < allowedArea * .65;
    if (unstableRing && (flatFill || !useModel || overlap > maskCount * .90)) {
      return null;
    }
    final (kept, protected) = _filterComponents(
      mask,
      rw,
      math.min(allowedRight - allowedLeft, allowedBottom - allowedTop),
    );
    if (kept == 0) return null;
    if (useModel) {
      var supported = 0;
      for (var y = allowedTop; y < allowedBottom; y++) {
        for (var x = allowedLeft; x < allowedRight; x++) {
          var i = y * rw + x;
          if (mask[i] == 0) continue;
          if (model.contains(left + x, top + y, w, h)) {
            supported++;
          } else {
            mask[i] = 0;
          }
        }
      }
      if (supported == 0) return null;
    }

    // Dilate to swallow the anti-aliased halo around each stroke — leftover
    // grey fringe reads as "text not fully erased". The radius scales with the
    // stroke thickness (approximated from the region size) so thin lettering
    // gets a tight grow and bold/large text a wider one, instead of a fixed 2px
    // that under-covers big glyphs.
    var radius = math.max(2, (math.min(rw, rh) * 0.03).round()).clamp(2, 5);
    mask = _dilate(mask, rw, rh, radius);
    // Dilation covers anti-aliased glyph edges but must not grow into artwork.
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        if (x < allowedLeft ||
            x >= allowedRight ||
            y < allowedTop ||
            y >= allowedBottom ||
            protected?[y * rw + x] == 1) {
          mask[y * rw + x] = 0;
        }
      }
    }
    return TextMask(left, top, rw, rh, mask);
  }

  static (int, bool) _backgroundRing(
    Uint8List values,
    int w,
    int h,
    int left,
    int top,
    List<IntRect> textRegions,
    bool flatFill,
  ) {
    // Neighboring OCR lines are foreground, even when they touch this line's
    // sampling border. Including them misclassifies dense dialogue as texture.
    final ring = <int>[];
    void sample(int x, int y) {
      final px = left + x, py = top + y;
      final isText = textRegions.any(
        (r) =>
            px >= r.left - 2 &&
            px < r.right + 2 &&
            py >= r.top - 2 &&
            py < r.bottom + 2,
      );
      ring.add(isText ? -1 : values[y * w + x]);
    }

    for (var x = 0; x < w; x++) {
      sample(x, 0);
    }
    for (var y = 1; y < h; y++) {
      sample(w - 1, y);
    }
    for (var x = w - 2; x >= 0; x--) {
      sample(x, h - 1);
    }
    for (var y = h - 2; y > 0; y--) {
      sample(0, y);
    }
    var count = 0, sum = 0;
    for (final value in ring) {
      if (value < 0) continue;
      count++;
      sum += value;
    }
    if (count < 8) return (255, true);
    final mean = (sum / count).round();
    var tolerance = flatFill ? 24 : 35;
    var varied = 0;
    var abrupt = 0;
    for (var i = 0; i < ring.length; i++) {
      final value = ring[i],
          previous = ring[(i + ring.length - 1) % ring.length];
      if (value < 0) continue;
      if ((value - mean).abs() > tolerance) varied++;
      if (previous >= 0 && (value - previous).abs() > tolerance) abrupt++;
    }
    return (mean, varied > count * .33 && (flatFill || abrupt > count * .10));
  }

  static void fillWithBackground(RgbaImage image, TextMask mask) {
    var colors = <int, int>{};
    var best = 0, occurrences = 0;
    void sample(int x, int y) {
      var i = ((mask.top + y) * image.width + mask.left + x) * 4;
      var color =
          (image.pixels[i] << 16) |
          (image.pixels[i + 1] << 8) |
          image.pixels[i + 2];
      var bucket = color & 0xf8f8f8;
      var count = (colors[bucket] ?? 0) + 1;
      colors[bucket] = count;
      if (count > occurrences) {
        best = color;
        occurrences = count;
      }
    }

    for (var x = 0; x < mask.rw; x++) {
      sample(x, 0);
      sample(x, mask.rh - 1);
    }
    for (var y = 1; y < mask.rh - 1; y++) {
      sample(0, y);
      sample(mask.rw - 1, y);
    }
    var red = (best >> 16) & 255, green = (best >> 8) & 255, blue = best & 255;
    for (var y = 0; y < mask.rh; y++) {
      var offset = ((y + mask.top) * image.width + mask.left) * 4;
      for (var x = 0; x < mask.rw; x++) {
        if (mask.mask[y * mask.rw + x] == 0) continue;
        var i = offset + x * 4;
        image.pixels[i] = red;
        image.pixels[i + 1] = green;
        image.pixels[i + 2] = blue;
      }
    }
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

  /// Checks 8-connected components so a diagonal or curved line stays whole.
  /// A thin run several glyphs long is artwork. If it joins a thick stroke,
  /// keeping the original block avoids cutting the line where they meet.
  static (int, Uint8List?) _filterComponents(
    Uint8List mask,
    int width,
    int shortSide,
  ) {
    final n = mask.length;
    final minimumPixels = math.max(6, (n * .0008).round());
    final minimumSpan = math.max(16, (shortSide * 1.65).ceil());
    final thinWidth = (shortSide * .08).round().clamp(2, 4);
    final seen = Uint8List(n);
    final members = <int>[];
    final profile = Int32List(math.max(width, n ~/ width));
    Uint8List? protected;
    var kept = 0;
    for (var start = 0; start < n; start++) {
      if (mask[start] == 0 || seen[start] != 0) continue;
      members
        ..clear()
        ..add(start);
      seen[start] = 1;
      var minX = start % width, maxX = minX;
      var minY = start ~/ width, maxY = minY;
      for (var pos = 0; pos < members.length; pos++) {
        final i = members[pos];
        final x = i % width, y = i ~/ width;
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        minY = math.min(minY, y);
        maxY = math.max(maxY, y);
        final firstX = math.max(0, x - 1), lastX = math.min(width - 1, x + 1);
        for (
          var row = math.max(0, i - x - width);
          row < n && row <= i - x + width;
          row += width
        ) {
          for (var next = row + firstX; next <= row + lastX; next++) {
            if (mask[next] == 0 || seen[next] != 0) continue;
            seen[next] = 1;
            members.add(next);
          }
        }
      }

      // Remove isolated dust but retain solid bold lettering and punctuation.
      if (members.length < minimumPixels) {
        for (final i in members) {
          mask[i] = 0;
        }
        continue;
      }
      final horizontal = maxX - minX >= maxY - minY;
      final span = horizontal ? maxX - minX + 1 : maxY - minY + 1;
      if (span >= minimumSpan) {
        profile.fillRange(0, span, 0);
        for (final i in members) {
          final at = horizontal ? i % width - minX : i ~/ width - minY;
          profile[at]++;
        }
        var thin = 0, thick = 0;
        for (var j = 0; j < span; j++) {
          if (profile[j] <= thinWidth) thin++;
          if (profile[j] > thinWidth + 2) thick++;
        }
        if (thin >= span * .55) {
          if (thick >= 2) return (0, null);
          final keep = protected ??= Uint8List(n);
          for (final i in members) {
            mask[i] = 0;
            keep[i] = 1;
          }
          continue;
        }
      }
      kept += members.length;
    }
    return (kept, protected);
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

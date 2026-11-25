import 'dart:math' as math;
import 'dart:typed_data';

import 'package:venera/foundation/image_translation/translation_types.dart';

/// Working window + per-pixel 0/1 stroke mask for one text region.
class TextMask {
  TextMask(
    this.left,
    this.top,
    this.rw,
    this.rh,
    this.mask, {
    this.backgroundColor,
  });

  final int left;
  final int top;
  final int rw;
  final int rh;
  final Uint8List mask;
  final int? backgroundColor;
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

  /// Fills a previously selected set of lettering pixels.
  static void eraseWithMask(RgbaImage image, TextMask m) {
    if (m.backgroundColor != null) {
      fillWithBackground(image, m);
      return;
    }
    final remaining = _fillPattern(image, m);
    _fillNearest(
      image.pixels,
      image.width,
      m.left,
      m.top,
      m.rw,
      m.rh,
      remaining,
    );
    _relax(image.pixels, image.width, m.left, m.top, m.rw, m.rh, remaining, 2);
  }

  /// Splits the region's luminance (Otsu) into background and text strokes,
  /// then dilates to swallow anti-aliased edges. Returns null when nothing
  /// plausible should be erased (too small, or the "text" class swallows the
  /// window — a near-uniform crop or heavy screentone the threshold misread).
  static TextMask? computeMask(
    RgbaImage image,
    IntRect region, {
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
    var (bgLum, unstableRing) = _backgroundRing(
      lum,
      rw,
      rh,
      left,
      top,
      neighbors,
      flatFill,
    );
    int? backgroundColor;
    int? colorCandidate;
    {
      // A bubble outline may cross the sampling border while the actual text
      // still sits on uniform paper. Require a dominant colour inside the
      // detector rectangle before trusting that paper instead of the border.
      final histogram = Int32List(32);
      final colors = <int, int>{};
      var dominant = 0, occurrences = 0;
      var samples = 0;
      for (
        var y = math.max(top, region.top);
        y < math.min(bottom, region.bottom);
        y++
      ) {
        for (
          var x = math.max(left, region.left);
          x < math.min(right, region.right);
          x++
        ) {
          histogram[lum[(y - top) * rw + x - left] ~/ 8]++;
          final p = (y * image.width + x) * 4;
          final color =
              (pixels[p] << 16) | (pixels[p + 1] << 8) | pixels[p + 2];
          final bucket = color & 0xf0f0f0;
          final count = (colors[bucket] ?? 0) + 1;
          colors[bucket] = count;
          if (count > occurrences) {
            dominant = color;
            occurrences = count;
          }
          samples++;
        }
      }
      var peak = 0;
      for (var i = 1; i < histogram.length; i++) {
        if (histogram[i] > histogram[peak]) peak = i;
      }
      var matching = 0, sum = 0;
      for (var i = math.max(0, peak - 2); i <= math.min(31, peak + 2); i++) {
        matching += histogram[i];
        sum += histogram[i] * (i * 8 + 4);
      }
      // Dense neighbouring columns can leave only grey ink on the ring.
      // Trust the clearly dominant light paper inside that narrow column.
      final lightPaper = peak >= 28 && bgLum >= 96 && bgLum < 224;
      if ((unstableRing || lightPaper) &&
          samples > 0 &&
          matching * 3 >= samples * 2) {
        bgLum = (sum / matching).round().clamp(0, 255);
        unstableRing = false;
      }
      final dominantLum =
          .299 * ((dominant >> 16) & 255) +
          .587 * ((dominant >> 8) & 255) +
          .114 * (dominant & 255);
      if (samples > 0 &&
          occurrences * 2 > samples &&
          (dominantLum - bgLum).abs() <= 16) {
        colorCandidate = dominant;
      }
      if (samples > 0 &&
          occurrences * 3 >= samples * 2 &&
          (dominantLum - bgLum).abs() <= 16) {
        backgroundColor = dominant;
      }
    }
    // At a page edge the sampling ring may include the panel frame. Accept
    // the majority paper colour when it also agrees with the ring median.
    final atPageEdge =
        region.top <= 0 ||
        region.left <= 0 ||
        region.bottom >= h ||
        region.right >= w;
    if (atPageEdge && unstableRing && colorCandidate != null) {
      unstableRing = false;
      backgroundColor = colorCandidate;
    }
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
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        var i = y * rw + x;
        var l = lum[i];
        var isText = textIsDark
            ? l <= threshold && (bgLum - l) >= minMargin
            : l > threshold && (l - bgLum) >= minMargin;
        if (isText) {
          mask[i] = 1;
        }
        // Include context when following connected artwork, but only count
        // candidates inside the detector rectangle as possible text.
        if (x < allowedLeft ||
            x >= allowedRight ||
            y < allowedTop ||
            y >= allowedBottom) {
          continue;
        }
        if (isText) maskCount++;
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
    if (maskCount == 0 && backgroundColor == null && colorCandidate != null) {
      // Dense coloured letters may occupy more than one third of the box.
      // Confirm the interior's majority colour against its sampling border.
      var matching = 0, samples = 0;
      for (var y = 0; y < rh; y++) {
        for (var x = 0; x < rw; x += y == 0 || y == rh - 1 ? 1 : rw - 1) {
          final p = ((top + y) * w + left + x) * 4;
          final color = pixels[p] << 16 | pixels[p + 1] << 8 | pixels[p + 2];
          if ((color & 0xf0f0f0) == (colorCandidate & 0xf0f0f0)) matching++;
          samples++;
        }
      }
      if (matching * 3 >= samples * 2) backgroundColor = colorCandidate;
    }
    if (maskCount == 0 && backgroundColor != null) {
      final red = backgroundColor >> 16;
      final green = (backgroundColor >> 8) & 255;
      final blue = backgroundColor & 255;
      // Equal-luminance coloured ink can disappear in the grayscale split.
      // Use colour contrast only when a dominant paper colour is established.
      for (var y = 0; y < rh; y++) {
        for (var x = 0; x < rw; x++) {
          final p = ((top + y) * image.width + left + x) * 4;
          if ((pixels[p] - red).abs() < 48 &&
              (pixels[p + 1] - green).abs() < 48 &&
              (pixels[p + 2] - blue).abs() < 48) {
            continue;
          }
          mask[y * rw + x] = 1;
          if (x >= allowedLeft &&
              x < allowedRight &&
              y >= allowedTop &&
              y < allowedBottom) {
            maskCount++;
          }
        }
      }
    }
    if (maskCount == 0 || maskCount > allowedArea * 0.85) return null;

    final separateInk = _isolateLetteringColor(
      image,
      mask,
      left,
      top,
      rw,
      rh,
      IntRect(allowedLeft, allowedTop, allowedRight, allowedBottom),
    );
    if (unstableRing && !separateInk) return null;
    final (kept, protected) = _filterComponents(
      mask,
      rw,
      math.min(allowedRight - allowedLeft, allowedBottom - allowedTop),
      uniformPaper: backgroundColor != null,
    );
    if (kept == 0) return null;

    // Dilate to swallow the anti-aliased halo around each stroke — leftover
    // grey fringe reads as "text not fully erased". The radius scales with the
    // stroke thickness (approximated from the region size) so thin lettering
    // gets a tight grow and bold/large text a wider one, instead of a fixed 2px
    // that under-covers big glyphs.
    var radius = math.max(2, (math.min(rw, rh) * 0.03).round()).clamp(2, 5);
    for (var y = 0; y < rh; y++) {
      for (var x = 0; x < rw; x++) {
        if (x < allowedLeft ||
            x >= allowedRight ||
            y < allowedTop ||
            y >= allowedBottom) {
          mask[y * rw + x] = 0;
        }
      }
    }
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
    {
      final colors = <int, int>{};
      var most = 0, samples = 0;
      int? paper;
      for (var y = allowedTop; y < allowedBottom; y++) {
        for (var x = allowedLeft; x < allowedRight; x++) {
          if (mask[y * rw + x] != 0) continue;
          final i = ((top + y) * image.width + left + x) * 4;
          final color = pixels[i] << 16 | pixels[i + 1] << 8 | pixels[i + 2];
          final key = color & 0xf0f0f0;
          final count = (colors[key] ?? 0) + 1;
          colors[key] = count;
          samples++;
          if (count > most) {
            paper = color;
            most = count;
          }
        }
      }
      if (samples >= 8 && most * 3 >= samples * 2) backgroundColor = paper;
    }
    if (backgroundColor != null) {
      final red = backgroundColor >> 16;
      final green = (backgroundColor >> 8) & 255;
      final blue = backgroundColor & 255;
      var known = 0, different = 0;
      for (var y = allowedTop; y < allowedBottom; y++) {
        for (var x = allowedLeft; x < allowedRight; x++) {
          if (mask[y * rw + x] != 0) continue;
          final i = ((top + y) * image.width + left + x) * 4;
          known++;
          if ((pixels[i] - red).abs() > 24 ||
              (pixels[i + 1] - green).abs() > 24 ||
              (pixels[i + 2] - blue).abs() > 24) {
            different++;
          }
        }
      }
      if (different > known * .08) backgroundColor = null;
    }
    return TextMask(left, top, rw, rh, mask, backgroundColor: backgroundColor);
  }

  // Reuse nearby matching screentone only when its repeated pattern can be
  // measured on known pixels. Smooth paper and isolated artwork use the fill.
  static Uint8List _fillPattern(RgbaImage image, TextMask m) {
    final w = m.rw, h = m.rh, source = image.pixels;
    final samples = <int>[];
    final step = math.max(1, math.sqrt(w * h / 160).ceil());
    var minLum = 255, maxLum = 0;
    for (var y = 0; y < h; y += step) {
      for (var x = 0; x < w; x += step) {
        final at = y * w + x;
        if (m.mask[at] != 0) continue;
        samples.add(at);
        final value = source[((m.top + y) * image.width + m.left + x) * 4];
        minLum = math.min(minLum, value);
        maxLum = math.max(maxLum, value);
      }
    }
    if (samples.length < 24 || maxLum - minLum < 64) return m.mask;
    final middle = (maxLum + minLum) ~/ 2;
    var dark = 0;
    for (final at in samples) {
      final i = ((m.top + at ~/ w) * image.width + m.left + at % w) * 4;
      if (source[i] < middle) dark++;
    }
    if (dark < samples.length * .15 || dark > samples.length * .85) {
      return m.mask;
    }
    final candidates = <(double, int, int)>[];
    final distance = math.min(36, math.min(w, h) ~/ 2);
    for (var dy = -distance; dy <= distance; dy++) {
      for (var dx = -distance; dx <= distance; dx++) {
        if (dx * dx + dy * dy < 36) continue;
        var score = 0, count = 0;
        for (final at in samples) {
          final x = at % w, y = at ~/ w, sx = x + dx, sy = y + dy;
          if (sx < 0 ||
              sx >= w ||
              sy < 0 ||
              sy >= h ||
              m.mask[sy * w + sx] != 0) {
            continue;
          }
          final a = ((m.top + y) * image.width + m.left + x) * 4;
          final b = ((m.top + sy) * image.width + m.left + sx) * 4;
          for (var c = 0; c < 3; c++) {
            score += (source[a + c] - source[b + c]).abs();
          }
          count++;
        }
        if (count >= samples.length * .35 && score < count * 24) {
          candidates.add((score / count, dx, dy));
        }
      }
    }
    if (candidates.isEmpty) return m.mask;
    candidates.sort((a, b) => a.$1.compareTo(b.$1));
    final remaining = Uint8List.fromList(m.mask);
    for (final (_, dx, dy) in candidates.take(12)) {
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (remaining[y * w + x] == 0) continue;
          final sx = x + dx, sy = y + dy;
          if (sx < 0 ||
              sx >= w ||
              sy < 0 ||
              sy >= h ||
              m.mask[sy * w + sx] != 0) {
            continue;
          }
          final a = ((m.top + y) * image.width + m.left + x) * 4;
          final b = ((m.top + sy) * image.width + m.left + sx) * 4;
          source.setRange(a, a + 3, source, b);
          remaining[y * w + x] = 0;
        }
      }
    }
    return remaining;
  }

  // Printed ink sometimes has a different pigment from the lines beneath it.
  // Use a recurring ink colour only when the surrounding artwork has a clearly
  // separate foreground colour. Monochrome line art keeps the geometry check.
  static bool _isolateLetteringColor(
    RgbaImage image,
    Uint8List mask,
    int left,
    int top,
    int w,
    int h,
    IntRect area,
  ) {
    final counts = <int, int>{};
    final outside = <int>{};
    var count = 0;
    int rgb(int x, int y) {
      final i = ((top + y) * image.width + left + x) * 4;
      final p = image.pixels;
      return p[i] << 16 | p[i + 1] << 8 | p[i + 2];
    }

    int distance(int a, int b) => math.max(
      ((a >> 16) - (b >> 16)).abs(),
      math.max(
        (((a >> 8) & 255) - ((b >> 8) & 255)).abs(),
        ((a & 255) - (b & 255)).abs(),
      ),
    );
    final step = math.max(1, math.sqrt(w * h / 12000).ceil());
    for (var y = 0; y < h; y += step) {
      for (var x = 0; x < w; x += step) {
        if (mask[y * w + x] == 0) continue;
        final color = rgb(x, y);
        if (x < area.left ||
            x >= area.right ||
            y < area.top ||
            y >= area.bottom) {
          outside.add(color);
        } else {
          count++;
          final frequency = (counts[color] ?? 0) + 1;
          counts[color] = frequency;
        }
      }
    }
    if (outside.isEmpty) return false;
    final inks = <(int, int)>[];
    for (final entry in counts.entries) {
      if (entry.value < 12 || entry.value < count * .12) continue;
      var gap = 255;
      for (final color in outside) {
        gap = math.min(gap, distance(entry.key, color));
      }
      if (gap >= 9) inks.add((entry.key, (gap * .55).round().clamp(4, 36)));
    }
    if (inks.isEmpty) return false;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (mask[i] != 0 &&
            !inks.any((ink) => distance(ink.$1, rgb(x, y)) <= ink.$2)) {
          mask[i] = 0;
        }
      }
    }
    return true;
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
    var count = 0;
    final histogram = Int32List(256);
    for (final value in ring) {
      if (value < 0) continue;
      count++;
      histogram[value]++;
    }
    if (count < 8) return (255, true);
    var median = 0, cumulative = 0;
    for (; median < 255; median++) {
      cumulative += histogram[median];
      if (cumulative * 2 >= count) break;
    }
    var tolerance = flatFill ? 24 : 35;
    var varied = 0;
    var abrupt = 0;
    for (var i = 0; i < ring.length; i++) {
      final value = ring[i],
          previous = ring[(i + ring.length - 1) % ring.length];
      if (value < 0) continue;
      if ((value - median).abs() > tolerance) varied++;
      if (previous >= 0 && (value - previous).abs() > tolerance) abrupt++;
    }
    return (median, varied > count * .33 && (flatFill || abrupt > count * .10));
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
    best = mask.backgroundColor ?? best;
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
  /// Protects a long thin line and any strokes touching it, while allowing
  /// disconnected glyphs in the same OCR rectangle to be erased.
  static (int, Uint8List?) _filterComponents(
    Uint8List mask,
    int width,
    int shortSide, {
    required bool uniformPaper,
  }) {
    final n = mask.length;
    // A printed ellipsis can be a row of 2x2 dots on plain bubble paper.
    final minimumPixels = uniformPaper ? 2 : math.max(6, (n * .0008).round());
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
      final edges = [
        minX == 0,
        maxX == width - 1,
        minY == 0,
        maxY == n ~/ width - 1,
      ].where((touches) => touches).length;
      final crossesWindow = edges >= 2;
      if (span >= minimumSpan || crossesWindow) {
        profile.fillRange(0, span, 0);
        for (final i in members) {
          final at = horizontal ? i % width - minX : i ~/ width - minY;
          profile[at]++;
        }
        var thin = 0;
        for (var j = 0; j < span; j++) {
          if (profile[j] <= thinWidth) thin++;
        }
        if (crossesWindow || thin >= span * .55) {
          final keep = protected ??= Uint8List(n);
          // When a line continues through both edges, its thin sections tell
          // us where it passes through the lettering. Protect that trace and
          // erase the rest of the glyphs attached to it.
          final trace = crossesWindow
              ? _crossingLine(members, width, horizontal, span, shortSide)
              : null;
          for (final i in members) {
            if (trace != null) {
              final axis = horizontal ? i % width : i ~/ width;
              final across = horizontal ? i ~/ width : i % width;
              if ((across - trace[axis]).abs() > thinWidth / 2 + 1) {
                kept++;
                continue;
              }
            }
            mask[i] = 0;
            // Leave a one-pixel background rim for the nearest-colour fill.
            final x = i % width, y = i ~/ width;
            final left = math.max(0, x - 1), right = math.min(width, x + 2);
            final bottom = math.min(n ~/ width - 1, y + 1);
            for (var row = math.max(0, y - 1); row <= bottom; row++) {
              keep.fillRange(row * width + left, row * width + right, 1);
            }
          }
          continue;
        }
      }
      kept += members.length;
    }
    return (kept, protected);
  }

  /// Interpolates the centre of a line between unambiguous, thin sections.
  static List<double>? _crossingLine(
    List<int> pixels,
    int width,
    bool horizontal,
    int span,
    int shortSide,
  ) {
    final lo = List<int>.filled(span, 1 << 30);
    final hi = List<int>.filled(span, -1);
    for (final i in pixels) {
      final axis = horizontal ? i % width : i ~/ width;
      // A component touching two edges on its shorter axis can be a cluster
      // of letters or multiple intersecting lines. Preserve it conservatively.
      if (axis >= span) return null;
      final across = horizontal ? i ~/ width : i % width;
      lo[axis] = math.min(lo[axis], across);
      hi[axis] = math.max(hi[axis], across);
    }
    final maxWidth = (shortSide * .08).round().clamp(2, 4) + 2;
    final anchors = [
      for (var i = 0; i < span; i++)
        if (hi[i] >= lo[i] && hi[i] - lo[i] < maxWidth) i,
    ];
    if (anchors.length < span * .18 ||
        anchors.first > 2 ||
        anchors.last < span - 3) {
      return null;
    }
    double center(int i) => (lo[i] + hi[i]) / 2;
    final trace = List<double>.filled(span, center(anchors.first));
    var previous = anchors.first;
    for (final next in anchors.skip(1)) {
      final delta = center(next) - center(previous);
      if (next - previous > shortSide * 2 ||
          delta.abs() > (next - previous) * 1.5 + 2) {
        return null;
      }
      for (var i = previous + 1; i <= next; i++) {
        trace[i] =
            center(previous) + delta * (i - previous) / (next - previous);
      }
      previous = next;
    }
    trace.fillRange(previous, span, center(previous));
    return trace;
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

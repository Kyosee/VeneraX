import 'dart:math' as math;
import 'dart:typed_data';

import 'package:venera/foundation/image_translation/translation_types.dart';

/// Scores and expands DBNet's text kernels in their own orientation. The
/// returned page coordinates follow [IntRect]'s exclusive right/bottom edges.
List<IntRect> postprocessTextDetections(
  Float32List probs,
  int w,
  int h,
  int tileWidth,
  int tileHeight,
) {
  if (w < 3 ||
      h < 3 ||
      tileWidth <= 0 ||
      tileHeight <= 0 ||
      probs.length < w * h) {
    return [];
  }
  final foreground = Uint8List(w * h);
  for (var i = 0; i < foreground.length; i++) {
    if (probs[i] >= .3) foreground[i] = 1;
  }
  final left = Int32List(h)..fillRange(0, h, w);
  final right = Int32List(h);
  final seeds = <int>[];
  final result = <IntRect>[];
  for (var start = 0; start < foreground.length; start++) {
    if (foreground[start] == 0) continue;
    var top = start ~/ w, bottom = top;
    var count = 0;
    seeds.add(start);
    while (seeds.isNotEmpty) {
      final seed = seeds.removeLast();
      if (foreground[seed] == 0) continue;
      final y = seed ~/ w, row = y * w;
      var from = seed - row, end = from + 1;
      while (from > 0 && foreground[row + from - 1] != 0) {
        from--;
      }
      while (end < w && foreground[row + end] != 0) {
        end++;
      }
      foreground.fillRange(row + from, row + end, 0);
      count += end - from;
      top = math.min(top, y);
      bottom = math.max(bottom, y);
      left[y] = math.min(left[y], from);
      right[y] = math.max(right[y], end - 1);
      // A neighbouring span can join at a corner, including at either end.
      final first = math.max(0, from - 1), last = math.min(w - 1, end);
      for (var ny = y - 1; ny <= y + 1; ny += 2) {
        if (ny < 0 || ny >= h) continue;
        final other = ny * w;
        var inRun = false;
        for (var x = first; x <= last; x++) {
          final on = foreground[other + x] != 0;
          if (on && !inRun) seeds.add(other + x);
          inRun = on;
        }
      }
    }
    if (count >= 12 && bottom - top >= 2) {
      final box = _minimumBox(_hull(left, right, top, bottom));
      if (box != null &&
          math.min(box.uMax - box.uMin, box.vMax - box.vMin) >= 2 - _epsilon &&
          box.mean(probs, w, h) >= .5) {
        final rect = box.expandedBounds(tileWidth, tileHeight, w, h);
        if (rect.width > 0 && rect.height > 0) result.add(rect);
      }
    }
    left.fillRange(top, bottom + 1, w);
    right.fillRange(top, bottom + 1, 0);
  }
  return result;
}

const _epsilon = 1e-7;
typedef _Point = math.Point<int>;

/// Row extrema contain every vertex of the component's convex hull.
List<_Point> _hull(Int32List left, Int32List right, int top, int bottom) {
  final points = <_Point>[];
  for (var y = top; y <= bottom; y++) {
    points.add(_Point(left[y], y));
    if (right[y] != left[y]) points.add(_Point(right[y], y));
  }
  List<_Point> chain(Iterable<_Point> ordered) {
    final half = <_Point>[];
    for (final p in ordered) {
      while (half.length >= 2) {
        final a = half[half.length - 2], b = half.last;
        final cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
        if (cross > 0) break;
        half.removeLast();
      }
      half.add(p);
    }
    return half..removeLast();
  }

  return chain(points)..addAll(chain(points.reversed));
}

_OrientedBox? _minimumBox(List<_Point> hull) {
  if (hull.length < 3) return null;
  var bestArea = double.infinity;
  _OrientedBox? best;
  // At least one side of the minimum-area rectangle lies on a hull edge.
  var a = hull.last;
  for (final b in hull) {
    final dx = b.x - a.x, dy = b.y - a.y;
    a = b;
    final length = math.sqrt((dx * dx + dy * dy).toDouble());
    final ux = dx / length, uy = dy / length;
    var uMin = double.infinity, uMax = double.negativeInfinity;
    var vMin = double.infinity, vMax = double.negativeInfinity;
    for (final p in hull) {
      final u = p.x * ux + p.y * uy, v = -p.x * uy + p.y * ux;
      uMin = math.min(uMin, u);
      uMax = math.max(uMax, u);
      vMin = math.min(vMin, v);
      vMax = math.max(vMax, v);
    }
    final area = (uMax - uMin) * (vMax - vMin);
    if (area < bestArea - _epsilon) {
      bestArea = area;
      best = _OrientedBox(ux, uy, uMin, uMax, vMin, vMax);
    }
  }
  return best;
}

class _OrientedBox {
  const _OrientedBox(
    this.ux,
    this.uy,
    this.uMin,
    this.uMax,
    this.vMin,
    this.vMax,
  );

  final double ux, uy, uMin, uMax, vMin, vMax;

  double mean(Float32List probs, int w, int h) {
    // Intersect each image row with the two projection intervals. Only
    // pixels inside the rotated rectangle contribute to its confidence.
    final y0 = math.min(uMin * uy, uMax * uy) + math.min(vMin * ux, vMax * ux);
    final y1 = math.max(uMin * uy, uMax * uy) + math.max(vMin * ux, vMax * ux);
    var sum = 0.0, count = 0;
    final endY = math.min(h - 1, (y1 + _epsilon).floor());
    for (var y = math.max(0, (y0 - _epsilon).ceil()); y <= endY; y++) {
      var lo = 0.0, hi = (w - 1).toDouble();
      if (ux.abs() > _epsilon) {
        final a = (uMin - y * uy) / ux, b = (uMax - y * uy) / ux;
        lo = math.max(lo, math.min(a, b));
        hi = math.min(hi, math.max(a, b));
      }
      if (uy.abs() > _epsilon) {
        final a = (vMin - y * ux) / -uy, b = (vMax - y * ux) / -uy;
        lo = math.max(lo, math.min(a, b));
        hi = math.min(hi, math.max(a, b));
      }
      final start = (lo - _epsilon).ceil(), end = (hi + _epsilon).floor();
      if (start > end) continue;
      final row = y * w;
      for (var x = start; x <= end; x++) {
        sum += probs[row + x];
      }
      count += end - start + 1;
    }
    return count == 0 ? 0 : sum / count;
  }

  IntRect expandedBounds(int tileWidth, int tileHeight, int w, int h) {
    final length = uMax - uMin, thickness = vMax - vMin;
    final offset = length * thickness * 1.8 / (2 * (length + thickness));
    final cu = (uMax + uMin) * .5, cv = (vMax + vMin) * .5;
    final x = cu * ux - cv * uy, y = cu * uy + cv * ux;
    final ru = length * .5 + offset, rv = thickness * .5 + offset;
    final ex = ru * ux.abs() + rv * uy.abs(),
        ey = ru * uy.abs() + rv * ux.abs();
    final sx = tileWidth / w, sy = tileHeight / h;
    return IntRect(
      ((x - ex) * sx).round().clamp(0, tileWidth),
      ((y - ey) * sy).round().clamp(0, tileHeight),
      ((x + ex + 1) * sx).round().clamp(0, tileWidth),
      ((y + ey + 1) * sy).round().clamp(0, tileHeight),
    );
  }
}

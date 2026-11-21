part of 'translation_worker.dart';

/// The CTD probe peaked near 600 MiB before counting the reader and RGBA
/// copies. Check fresh headroom before transferring or loading its tensors.
Future<bool> _hasStrokeMemory(int pageBytes) async {
  const reserve = 768 * 1024 * 1024;
  final needed = reserve + 2 * pageBytes;
  if (Platform.isIOS) {
    final system = DynamicLibrary.process();
    if (!system.providesSymbol('os_proc_available_memory')) return false;
    final available = system.lookupFunction<Size Function(), int Function()>(
      'os_proc_available_memory',
    );
    return available() >= needed;
  }
  if (Platform.isAndroid || Platform.operatingSystem == 'ohos') {
    try {
      final stats = await File('/proc/meminfo').readAsString();
      final available = RegExp(
        r'^MemAvailable:\s+(\d+)\s+kB',
        multiLine: true,
      ).firstMatch(stats);
      return available != null && int.parse(available[1]!) * 1024 >= needed;
    } on FileSystemException {
      return false;
    }
  }
  return true;
}

bool _fitsBubbleModel(RgbaImage image) =>
    image.width * 3 >= image.height && image.height * 2 >= image.width;

(int, int) _fitPage(RgbaImage image, int w, int h) {
  var scale = math.min(w / image.width, h / image.height);
  return (
    (image.width * scale).round().clamp(1, w),
    (image.height * scale).round().clamp(1, h),
  );
}

StrokeMask _ctdMask(RgbaImage image, OrtFfiSession session) {
  const size = 1024;
  const plane = size * size;
  var (w, h) = _fitPage(image, size, size);
  var pixels = _resizeRegion(
    image,
    IntRect(0, 0, image.width, image.height),
    w,
    h,
  );
  // dmMaze's letterbox pads only the right and bottom with black.
  var tensor = Float32List(3 * plane);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var i = y * size + x;
      var p = (y * w + x) * 4;
      tensor[i] = pixels[p] / 255;
      tensor[i + plane] = pixels[p + 1] / 255;
      tensor[i + plane * 2] = pixels[p + 2] / 255;
    }
  }
  return session.runMapped(
    {
      'images': OrtInput.float32(tensor, const [1, 3, size, size]),
    },
    'seg',
    (data, shape) {
      if (data is! Float32List ||
          !listEquals(shape, const [1, 1, size, size])) {
        throw StateError('Unexpected CTD stroke mask');
      }
      var mask = Uint8List(w * h);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          var value = data[y * size + x];
          mask[y * w + x] = value.isFinite
              ? (value.clamp(0, 1) * 255).round()
              : 0;
        }
      }
      return StrokeMask(w, h, mask);
    },
  );
}

// Only 256 input values and 65,536 distinct output values exist in this model.
final _normalizedGray = _grayTable();
final _logitProbability = _probabilityTable();

Uint16List _grayTable() {
  var normalized = Float32List(256);
  var bits = Uint32List.view(normalized.buffer);
  var result = Uint16List(256);
  for (var i = 0; i < 256; i++) {
    normalized[i] = (i / 255 - .449) / .226;
    var value = bits[i];
    // Every nonzero normalized byte is within the normal binary16 range.
    var biased = (value & 0x7fffffff) - 0x38000000;
    var rounded = (biased + 0xfff + ((biased >> 13) & 1)) >> 13;
    result[i] = ((value >> 16) & 0x8000) | rounded;
  }
  return result;
}

Uint8List _probabilityTable() {
  var scores = Uint8List(65536);
  for (var exponent = 0; exponent < 32; exponent++) {
    var unit = math.pow(2, math.max(1, exponent) - 25);
    for (var fraction = 0; fraction < 1024; fraction++) {
      var index = exponent * 1024 + fraction;
      if (exponent == 31 && fraction != 0) continue;
      var magnitude = exponent == 31
          ? double.infinity
          : (exponent == 0 ? fraction : fraction + 1024) * unit;
      var score = (255 / (1 + math.exp(-magnitude))).round();
      scores[index] = score;
      scores[index + 32768] = 255 - score;
    }
  }
  return scores;
}

/// Assign each OCR line to one instance in the author's fixed NHWC model.
List<List<IntRect>> modelDialogueGroups(
  RgbaImage image,
  List<IntRect> boxes,
  OrtFfiSession session,
) {
  const width = bubblePopWidth, height = bubblePopHeight;
  var (w, h) = _fitPage(image, width, height);
  var dx = (width - w) ~/ 2, dy = (height - h) ~/ 2;
  var page = IntRect(0, 0, image.width, image.height);
  var resized = _resizeRegion(image, page, w, h);
  var input = Uint16List(width * height)
    ..fillRange(0, width * height, _normalizedGray[255]);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var p = (y * w + x) * 4;
      var gray =
          (77 * resized[p] +
              150 * resized[p + 1] +
              29 * resized[p + 2] +
              128) >>
          8;
      input[(y + dy) * width + x + dx] = _normalizedGray[gray];
    }
  }
  return session.runMapped(
    {
      'image': OrtInput.float16(input, const [1, height, width, 1]),
    },
    'logits',
    (data, shape) {
      if (data is! Uint16List ||
          !listEquals(shape, const [1, height, width, 3])) {
        throw StateError('Unexpected BubblePop logits');
      }
      // Merge mask and confidence on a half-scale grid; never upsample to a
      // potentially huge page, or copy the full 3-channel native output.
      var mw = (w + 1) ~/ 2, mh = (h + 1) ~/ 2;
      var scores = Uint8List(mw * mh);
      for (var y = 0; y < mh; y++) {
        for (var x = 0; x < mw; x++) {
          var p = ((dy + y * 2) * width + dx + x * 2) * 3;
          var mask = _logitProbability[data[p]];
          if (mask >= 128) {
            scores[y * mw + x] = (mask + _logitProbability[data[p + 2]]) ~/ 2;
          }
        }
      }
      return _DialogueMap(mw, mh, scores: scores).groups(page, boxes);
    },
  );
}

/// Comic Translate predicts bubble, inside-text and outside-text boxes together.
List<List<IntRect>> rtDetrDialogueGroups(
  RgbaImage image,
  List<IntRect> lines,
  OrtFfiSession session,
) {
  const size = 640, plane = size * size;
  final page = IntRect(0, 0, image.width, image.height);
  final resized = _resizeRegion(image, page, size, size);
  final rgb = Float32List(3 * plane);
  for (var i = 0; i < plane; i++) {
    rgb[i] = resized[4 * i] / 255;
    rgb[plane + i] = resized[4 * i + 1] / 255;
    rgb[2 * plane + i] = resized[4 * i + 2] / 255;
  }
  return session.runMappedOutputs(
    {
      'images': OrtInput.float32(rgb, const [1, 3, size, size]),
      'orig_target_sizes': OrtInput.int64(
        Int64List.fromList([image.width, image.height]),
        const [1, 2],
      ),
    },
    const ['labels', 'boxes', 'scores'],
    (outputs) {
      final (labels, ls) = outputs[0];
      final (boxes, bs) = outputs[1];
      final (scores, ss) = outputs[2];
      if (labels is! Int64List ||
          boxes is! Float32List ||
          scores is! Float32List ||
          !listEquals(ls, [1, labels.length]) ||
          !listEquals(ls, ss) ||
          !listEquals(bs, [1, labels.length, 4])) {
        throw StateError('Unexpected Comic Translate detection tensors');
      }
      final bubbles = <IntRect>[];
      final captions = <IntRect>[];
      final text = <({IntRect rect, bool inside, double score})>[];
      for (var i = 0; i < scores.length; i++) {
        if (!scores[i].isFinite || scores[i] < .3) continue;
        final p = i * 4;
        if (!boxes[p].isFinite ||
            !boxes[p + 1].isFinite ||
            !boxes[p + 2].isFinite ||
            !boxes[p + 3].isFinite) {
          continue;
        }
        final rect = IntRect(
          boxes[p].floor().clamp(0, page.right),
          boxes[p + 1].floor().clamp(0, page.bottom),
          boxes[p + 2].ceil().clamp(0, page.right),
          boxes[p + 3].ceil().clamp(0, page.bottom),
        );
        if (rect.width <= 0 || rect.height <= 0) continue;
        if (labels[i] == 0) {
          (_hasCaptionBorder(image, rect) ? captions : bubbles).add(rect);
        } else if (labels[i] == 1 || labels[i] == 2) {
          text.add((rect: rect, inside: labels[i] == 1, score: scores[i]));
        }
      }
      return groupDetectedDialogue(
        image,
        lines,
        bubbles,
        text,
        captions: captions,
      );
    },
  );
}

@visibleForTesting
List<List<IntRect>> groupDetectedDialogue(
  RgbaImage image,
  List<IntRect> lines,
  List<IntRect> bubbles,
  List<({IntRect rect, bool inside, double score})> text, {
  List<IntRect> captions = const [],
}) {
  final groups = <IntRect, List<IntRect>>{};
  final undecided = <IntRect>[];
  final owners = <IntRect, IntRect>{};
  for (final line in lines) {
    if (line.area <= 0) continue;
    double coverage(IntRect box) {
      final w = math.min(line.right, box.right) - math.max(line.left, box.left);
      final h = math.min(line.bottom, box.bottom) - math.max(line.top, box.top);
      return w > 0 && h > 0 ? w * h / line.area : 0;
    }

    // Competing text predictions near adjacent bubbles can overlap. Prefer
    // the label that explains more of this OCR line at higher confidence.
    var inside = 0.0, outside = 0.0;
    IntRect? insideRect;
    for (final prediction in text) {
      final overlap = coverage(prediction.rect);
      if (overlap < .5) continue;
      final score = overlap * prediction.score;
      if (prediction.inside) {
        if (score > inside) {
          inside = score;
          insideRect = prediction.rect;
        }
      } else {
        outside = math.max(outside, score);
      }
    }
    IntRect? owner;
    for (final bubble in bubbles) {
      if (coverage(bubble) >= .85 &&
          (owner == null || bubble.area < owner.area)) {
        owner = bubble;
      }
    }
    if (owner == null && captions.any((box) => coverage(box) >= .85)) continue;
    if (inside > outside) {
      (groups[owner ?? insideRect!] ??= []).add(line);
    } else if (outside == 0 || owner != null) {
      // Partial detections must still get the default closed-bubble check.
      // A detected bubble can also corroborate a misclassified text line.
      undecided.add(line);
      if (owner != null) owners[line] = owner;
    }
  }
  for (final fallback in dialogueGroups(image, undecided)) {
    final owner = owners[fallback.first] ?? fallback.first;
    (groups[owner] ??= []).addAll(fallback);
  }
  return groups.values.toList();
}

/// The detector also calls boxed narration a bubble. Look for straight edges
/// near all four sides, including thin outlines on a same-colour background.
bool _hasCaptionBorder(RgbaImage image, IntRect box) {
  if (box.width < 16 || box.height < 16) return false;
  bool straight(bool horizontal, int edge) {
    final length = horizontal ? box.width : box.height;
    final depth = horizontal ? box.height : box.width;
    final start = horizontal ? box.left : box.top;
    final limit = horizontal ? image.height : image.width;
    final search = (depth * .05).ceil().clamp(3, 12);
    final stride = (depth * .012).round().clamp(2, 5);
    for (
      var pos = math.max(stride, edge - search);
      pos <= math.min(limit - 1 - stride, edge + search);
      pos++
    ) {
      var edges = 0;
      for (var i = 1; i <= 11; i++) {
        final along = start + length * i ~/ 12;
        int sample(int at) =>
            horizontal ? _rgbAt(image, along, at) : _rgbAt(image, at, along);
        final center = sample(pos);
        if (!_nearColor(center, sample(pos - stride), 38) ||
            !_nearColor(center, sample(pos + stride), 38)) {
          edges++;
        }
      }
      if (edges >= 10) return true;
    }
    return false;
  }

  return straight(true, box.top) &&
      straight(true, box.bottom) &&
      straight(false, box.left) &&
      straight(false, box.right);
}

/// Lightweight closed-background detection for pages without model evidence.
List<List<IntRect>> dialogueGroups(RgbaImage image, List<IntRect> boxes) {
  if (boxes.isEmpty) return [];
  var vertical = image.height >= image.width;
  var along = vertical ? image.height : image.width;
  var across = vertical ? image.width : image.height;
  var slice = math.min(along, math.max(32, across * 2));
  var overlap = slice ~/ 4;
  var groups = <Set<IntRect>>[];
  for (var start = 0; start < along; start += slice - overlap) {
    var end = math.min(along, start + slice);
    var tile = vertical
        ? IntRect(0, start, across, end)
        : IntRect(start, 0, end, across);
    var boxesInTile = boxes
        .where(
          (b) =>
              b.left >= tile.left &&
              b.right <= tile.right &&
              b.top >= tile.top &&
              b.bottom <= tile.bottom,
        )
        .toList();
    if (boxesInTile.isNotEmpty) {
      for (var group in _backgroundMap(image, tile).groups(tile, boxesInTile)) {
        var shared = groups
            .where((prior) => group.any(prior.contains))
            .toList();
        if (shared.isEmpty) {
          groups.add(group.toSet());
        } else {
          shared.first.addAll(group);
          for (var other in shared.skip(1)) {
            shared.first.addAll(other);
            groups.remove(other);
          }
        }
      }
    }
    if (end == along) break;
  }
  return [for (var group in groups) group.toList()];
}

// Bit 24 distinguishes a uniform black cell from a blocked edge.
int _rgbAt(RgbaImage image, int x, int y) {
  var p = (y * image.width + x) * 4;
  return 0x1000000 |
      (image.pixels[p] << 16) |
      (image.pixels[p + 1] << 8) |
      image.pixels[p + 2];
}

bool _nearColor(int a, int b, int tolerance) =>
    ((a & 255) - (b & 255)).abs() <= tolerance &&
    (((a >> 8) & 255) - ((b >> 8) & 255)).abs() <= tolerance &&
    (((a >> 16) & 255) - ((b >> 16) & 255)).abs() <= tolerance;

_DialogueMap _backgroundMap(RgbaImage image, IntRect tile) {
  var scale = math.min(1.0, 768 / math.max(tile.width, tile.height));
  var width = math.max(1, (tile.width * scale).round());
  var height = math.max(1, (tile.height * scale).round());
  var colors = Uint32List(width * height);
  for (var y = 0; y < height; y++) {
    var top = tile.top + y * tile.height ~/ height;
    var bottom = tile.top + (y + 1) * tile.height ~/ height - 1;
    for (var x = 0; x < width; x++) {
      var left = tile.left + x * tile.width ~/ width;
      var right = tile.left + (x + 1) * tile.width ~/ width - 1;
      var color = _rgbAt(image, (left + right) ~/ 2, (top + bottom) ~/ 2);
      // Preserve thin outlines during reduction: any contrasting corner is
      // a barrier, even when the sample at the centre missed the ink.
      if ((left == right && top == bottom) ||
          (_nearColor(color, _rgbAt(image, left, top), 36) &&
              _nearColor(color, _rgbAt(image, right, top), 36) &&
              _nearColor(color, _rgbAt(image, left, bottom), 36) &&
              _nearColor(color, _rgbAt(image, right, bottom), 36))) {
        colors[y * width + x] = color;
      }
    }
  }
  return _DialogueMap(width, height, colors: colors);
}

class _DialogueMap {
  _DialogueMap(this.w, this.h, {this.colors, this.scores})
    : labels = Int32List(w * h),
      queue = Int32List(w * h);
  final int w, h;
  final Uint32List? colors;
  final Uint8List? scores;
  final Int32List labels, queue;
  final bounds = <IntRect>[];

  int _component(int seed) {
    if (labels[seed] != 0) return labels[seed];
    var color = colors?[seed];
    if (color == 0 || scores?[seed] == 0) return -1;
    var head = 0, tail = 1;
    var l = w, t = h, r = 0, b = 0, total = 0;
    labels[seed] = -1;
    queue[0] = seed;
    void visit(int i) {
      if (labels[i] != 0) return;
      if (color != null) {
        var candidate = colors![i];
        if (candidate == 0 || !_nearColor(color, candidate, 25)) return;
      } else if (scores![i] == 0) {
        return;
      }
      labels[i] = -1;
      queue[tail++] = i;
    }

    while (head < tail) {
      var i = queue[head++];
      var y = i ~/ w, x = i - y * w;
      if (x < l) l = x;
      if (y < t) t = y;
      if (x > r) r = x;
      if (y > b) b = y;
      total += scores?[i] ?? 0;
      if (x != 0) visit(i - 1);
      if (x != w - 1) visit(i + 1);
      if (y != 0) visit(i - w);
      if (y != h - 1) visit(i + w);
    }
    var bw = r - l + 1, bh = b - t + 1;
    if (l == 0 ||
        t == 0 ||
        r == w - 1 ||
        b == h - 1 ||
        bw < 8 ||
        bh < 8 ||
        tail < bw * bh * .30 ||
        (scores != null && total < 160 * tail)) {
      return -1;
    }
    // Row spans measure the outer silhouette without counting text holes.
    // Dense lettering alone must never make a rectangular caption look round.
    var left = Int32List(bh)..fillRange(0, bh, w);
    var right = Int32List(bh);
    for (var j = 0; j < tail; j++) {
      var i = queue[j], y = i ~/ w - t, x = i % w;
      left[y] = math.min(x, left[y]);
      right[y] = math.max(x, right[y]);
    }
    var area = 0;
    for (var y = 0; y < bh; y++) {
      area += right[y] - left[y] + 1;
    }
    var fill = area / (bw * bh);
    if (fill < .45 || fill > .93) return -1;
    bounds.add(IntRect(l, t, r + 1, b + 1));
    for (var j = 0; j < tail; j++) {
      labels[queue[j]] = bounds.length;
    }
    return bounds.length;
  }

  List<List<IntRect>> groups(IntRect tile, List<IntRect> lines) {
    var groups = <int, List<IntRect>>{};
    for (var line in lines) {
      var l = ((line.left - tile.left) * w / tile.width).floor().clamp(
        0,
        w - 1,
      );
      var r = ((line.right - tile.left) * w / tile.width).ceil().clamp(
        l + 1,
        w,
      );
      var t = ((line.top - tile.top) * h / tile.height).floor().clamp(0, h - 1);
      var b = ((line.bottom - tile.top) * h / tile.height).ceil().clamp(
        t + 1,
        h,
      );
      var votes = <int, int>{};
      var area = (r - l) * (b - t);
      for (var row = 0; row < 7; row++) {
        var y = t + ((2 * row + 1) * (b - t) ~/ 14);
        for (var col = 0; col < 7; col++) {
          var x = l + ((2 * col + 1) * (r - l) ~/ 14);
          var id = _component(y * w + x);
          if (id < 1) continue;
          var rect = bounds[id - 1];
          var inside =
              (math.min(r, rect.right) - math.max(l, rect.left)) *
              (math.min(b, rect.bottom) - math.max(t, rect.top));
          if (rect.area >= area * 1.3 && inside >= area * .90) {
            votes[id] = (votes[id] ?? 0) + 1;
          }
        }
      }
      if (votes.isEmpty) continue;
      var winner = votes.entries.reduce((a, b) => a.value >= b.value ? a : b);
      var runner =
          votes.values.fold(0, (total, value) => total + value) - winner.value;
      if (winner.value >= (scores == null ? 16 : 32) &&
          winner.value > runner * 2) {
        (groups[winner.key] ??= []).add(line);
      }
    }
    return groups.values.toList();
  }
}

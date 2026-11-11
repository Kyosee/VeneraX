import 'dart:async';
import 'dart:ui';

enum AdaptiveReadingLayout { paged, strip }

/// A single cover or spread cannot decide the reading direction.
AdaptiveReadingLayout? detectReadingLayout(Iterable<Size> sizes) {
  final valid = sizes
      .where((s) => s.isFinite && s.width > 0 && s.height > 0)
      .toList();
  if (valid.length < 3) return null;
  final ratios = valid.map((s) => s.height / s.width).toList();
  final tall = ratios.where((r) => r >= 2.4).length;
  final short = ratios.where((r) => r <= 0.45).length;
  final required = (valid.length * 0.8).ceil();
  if (tall >= required) return AdaptiveReadingLayout.strip;
  // Repeated shallow slices with a shared column width also form a strip.
  final widths = valid.map((s) => s.width).toList()..sort();
  if (short >= required && widths.last / widths.first <= 1.1) {
    return AdaptiveReadingLayout.strip;
  }
  if (tall == 0 &&
      short == 0 &&
      ratios.where((r) => r <= 2).length >= required) {
    return AdaptiveReadingLayout.paged;
  }
  return null;
}

/// Reads a small body sample before showing the chapter. Late results never
/// switch modes underneath an active reader, and failures use the saved mode.
Future<AdaptiveReadingLayout?> probeReadingLayout({
  required int imageCount,
  required Future<Size?> Function(int index) readSize,
  required bool Function() isCancelled,
  Duration timeout = const Duration(seconds: 4),
}) async {
  if (imageCount < 4 || isCancelled()) return null;
  final sizes = <Size>[];
  var next = 1;
  var expired = false;
  final end = imageCount.clamp(0, 6);
  Future<void> worker() async {
    while (!expired && !isCancelled() && next < end) {
      final index = next++;
      try {
        final size = await readSize(index);
        if (!expired && !isCancelled() && size != null) sizes.add(size);
      } catch (_) {
        // An unreadable sample must not stop the chapter opening.
      }
    }
  }

  await Future.wait([worker(), worker()]).timeout(
    timeout,
    onTimeout: () {
      expired = true;
      return <void>[];
    },
  );
  if (isCancelled()) return null;
  return detectReadingLayout(sizes);
}

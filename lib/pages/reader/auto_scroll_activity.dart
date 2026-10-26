import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Moves a scroll view by a caller-computed amount every frame.
///
/// A real activity rather than per-frame jumps: one start and one end
/// notification for the whole run, and any touch, fling, wheel or animated
/// scroll replaces it the way it would replace a fling. Unlike
/// [DrivenScrollActivity] it lets pointers through, so taps keep reaching the
/// page while it runs.
class AutoScrollActivity extends ScrollActivity {
  AutoScrollActivity(
    super.delegate, {
    required TickerProvider vsync,
    required this.nextPixels,
    required this.onDispose,
  }) {
    _ticker = vsync.createTicker(_tick)..start();
  }

  /// Target pixels given the seconds since the previous frame, or null to
  /// stop and let the position settle.
  final double? Function(double seconds) nextPixels;

  final VoidCallback onDispose;

  late final Ticker _ticker;

  Duration _last = Duration.zero;

  bool _disposed = false;

  void _tick(Duration elapsed) {
    // A long frame must not turn into a visible jump.
    final seconds = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = elapsed;
    final target = nextPixels(seconds);
    if (_disposed) return;
    if (target == null) {
      delegate.goBallistic(0.0);
    } else {
      delegate.setPixels(target);
    }
  }

  @override
  bool get shouldIgnorePointer => false;

  @override
  bool get isScrolling => true;

  // Reported as still so a drag taking over starts without fling momentum.
  @override
  double get velocity => 0.0;

  @override
  void dispose() {
    _disposed = true;
    _ticker.dispose();
    onDispose();
    super.dispose();
  }
}

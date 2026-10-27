typedef ContinuousPageTurnAction<T> =
    Future<void> Function(T target, bool Function() isCurrent);

double estimateContinuousTurnOffset({
  required double currentPixels,
  required double referenceDelta,
  required int targetIndex,
  required int referenceIndex,
  required double itemExtent,
  required double minScrollExtent,
  required double maxScrollExtent,
  double? maxStepExtent,
}) {
  var estimate =
      currentPixels +
      referenceDelta +
      (targetIndex - referenceIndex) * itemExtent;
  if (maxStepExtent != null) {
    final delta = (estimate - currentPixels).clamp(
      -maxStepExtent,
      maxStepExtent,
    );
    estimate = currentPixels + delta;
  }
  return estimate.clamp(minScrollExtent, maxScrollExtent).toDouble();
}

/// For a page shown as two stacked halves and turned one half at a time,
/// whether the reader is on its lower half. [pageStart] is the page's leading
/// edge relative to the viewport's, [readingLine] the line the current page is
/// resolved against.
///
/// A page whose remainder already fits on screen also counts as lower, so a
/// turn at the end of the content, where the list cannot scroll the midpoint
/// up to the reading line, moves on instead of repeating the same half.
bool isReadingLowerHalf({
  required double pageStart,
  required double pageExtent,
  required double viewExtent,
  required double readingLine,
}) {
  // 1px of slack absorbs rounding in the scroll offset a turn lands on.
  if (pageStart + pageExtent / 2 <= readingLine + 1) return true;
  return pageStart + pageExtent <= viewExtent + 1;
}

/// Serializes continuous-reader page turns and coalesces queued requests to
/// the latest intended target.
class ContinuousPageTurnCoordinator<T> {
  ContinuousPageTurnCoordinator({
    required ContinuousPageTurnAction<T> prepare,
    required ContinuousPageTurnAction<T> navigate,
  }) : _prepare = prepare,
       _navigate = navigate;

  final ContinuousPageTurnAction<T> _prepare;
  final ContinuousPageTurnAction<T> _navigate;

  T? _activeTarget;
  T? _pendingTarget;
  Future<void>? _drainFuture;
  int _generation = 0;

  T? get intendedTarget => _pendingTarget ?? _activeTarget;

  Future<void> request(T target) {
    _pendingTarget = target;
    return _drainFuture ??= _drain();
  }

  Future<void> _drain() async {
    try {
      while (_pendingTarget != null) {
        final generation = _generation;
        final target = _pendingTarget as T;
        _pendingTarget = null;
        _activeTarget = target;
        bool isCurrent() => generation == _generation;
        await _prepare(target, isCurrent);

        if (!isCurrent()) {
          _activeTarget = null;
          continue;
        }

        // A newer request arrived while preparing. Skip scrolling to the stale
        // target and prepare the latest target instead.
        if (_pendingTarget != null) {
          _activeTarget = null;
          continue;
        }

        await _navigate(target, isCurrent);
        _activeTarget = null;
      }
    } finally {
      _activeTarget = null;
      _drainFuture = null;
      // A request can arrive between the loop condition and the finally block.
      if (_pendingTarget != null) {
        _drainFuture = _drain();
        await _drainFuture;
      }
    }
  }

  void cancel() {
    _generation++;
    _pendingTarget = null;
    _activeTarget = null;
  }
}

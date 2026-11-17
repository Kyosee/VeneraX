import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Crossfades the last painted reader frame over the new orientation.
class ReaderRotationTransition extends StatefulWidget {
  const ReaderRotationTransition({
    super.key,
    required this.backgroundColor,
    required this.child,
    this.enabled = true,
  });

  final Color backgroundColor;
  final Widget child;
  final bool enabled;

  @override
  State<ReaderRotationTransition> createState() =>
      _ReaderRotationTransitionState();
}

class _ReaderRotationTransitionState extends State<ReaderRotationTransition>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _contentKey = GlobalKey();
  late final _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );
  late final _opacity = ReverseAnimation(_animation);
  ui.FlutterView? _view;
  Size? _lastViewSize;
  ui.Image? _snapshot;
  bool _allowAnimation = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animation.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(_clearSnapshot);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final view = View.of(context);
    if (_view != view) {
      _view = view;
      _lastViewSize = view.physicalSize;
      _clearSnapshot();
    }
    _allowAnimation =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (!_allowAnimation) _clearSnapshot();
  }

  @override
  void didUpdateWidget(ReaderRotationTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _clearSnapshot();
  }

  void _clearSnapshot() {
    _animation.stop();
    _snapshot?.dispose();
    _snapshot = null;
  }

  @override
  void didChangeMetrics() {
    final previous = _lastViewSize;
    final next = _view?.physicalSize;
    _lastViewSize = next;
    if (previous == null || next == null) return;
    if (next.isEmpty) {
      setState(_clearSnapshot);
      return;
    }
    if (!widget.enabled ||
        !_allowAnimation ||
        previous.isEmpty ||
        (previous.width > previous.height) == (next.width > next.height)) {
      return;
    }

    final boundary =
        _contentKey.currentContext?.findRenderObject() as _ReaderFrameBoundary?;
    ui.Image? snapshot;
    try {
      snapshot = boundary?.capture();
    } catch (error) {
      debugPrint('Reader rotation snapshot unavailable: $error');
    }
    setState(() {
      _clearSnapshot();
      _snapshot = snapshot;
      if (snapshot != null) _animation.forward(from: 0);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clearSnapshot();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _ReaderFrame(key: _contentKey, child: widget.child),
        if (_snapshot != null)
          IgnorePointer(
            child: ExcludeSemantics(
              child: FadeTransition(
                opacity: _opacity,
                child: ColoredBox(
                  color: widget.backgroundColor,
                  child: RawImage(image: _snapshot, fit: BoxFit.contain),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ReaderFrame extends SingleChildRenderObjectWidget {
  const _ReaderFrame({super.key, required super.child});

  @override
  RenderRepaintBoundary createRenderObject(BuildContext context) =>
      _ReaderFrameBoundary();
}

class _ReaderFrameBoundary extends RenderRepaintBoundary {
  ui.Image? capture() {
    final paintedLayer = layer;
    if (!attached ||
        !hasSize ||
        size.isEmpty ||
        paintedLayer is! OffsetLayer ||
        !paintedLayer.supportsRasterization()) {
      return null;
    }
    // Metrics may dirty layout; the retained layer still holds the old frame.
    // Limit temporary GPU memory on large desktop and tablet viewports.
    return paintedLayer.toImageSync(
      Offset.zero & size,
      pixelRatio: math.min(1.0, 2048 / size.longestSide),
    );
  }
}

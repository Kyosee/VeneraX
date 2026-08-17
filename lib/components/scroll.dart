part of 'components.dart';

class SmoothCustomScrollView extends StatelessWidget {
  const SmoothCustomScrollView({
    super.key,
    required this.slivers,
    this.controller,
    this.scrollbar = true,
    this.scrollbarTopPadding = 0,
    this.physics,
  });

  final ScrollController? controller;

  final List<Widget> slivers;

  /// Overlays a draggable [AppScrollBar] on the right edge for fast jumping
  /// through long lists. It auto-hides when the content fits, so every
  /// vertically-scrolling page keeps the same thumb by default.
  final bool scrollbar;

  /// Top inset for the scrollbar thumb so it clears a top app bar. Only used
  /// when [scrollbar] is true.
  final double scrollbarTopPadding;

  /// Optional page-specific physics layered over the platform scroll behavior.
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    return SmoothScrollProvider(
      controller: controller,
      builder: (context, controller, physics) {
        Widget view = CustomScrollView(
          controller: controller,
          physics: this.physics?.applyTo(physics) ?? physics,
          slivers: [
            ...slivers,
            SliverPadding(
              padding: EdgeInsets.only(bottom: context.padding.bottom),
            ),
          ],
        );
        if (scrollbar) {
          view = AppScrollBar(
            controller: controller,
            topPadding: scrollbarTopPadding,
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: view,
            ),
          );
        }
        return view;
      },
    );
  }
}

class SmoothScrollProvider extends StatefulWidget {
  const SmoothScrollProvider({
    super.key,
    this.controller,
    required this.builder,
  });

  final ScrollController? controller;

  final Widget Function(BuildContext, ScrollController, ScrollPhysics) builder;

  static bool get isMouseScroll => _SmoothScrollProviderState._isMouseScroll;

  @override
  State<SmoothScrollProvider> createState() => _SmoothScrollProviderState();
}

class _SmoothScrollProviderState extends State<SmoothScrollProvider> {
  late final ScrollController _controller;

  double? _futurePosition;

  int _scrollAnimationToken = 0;

  static bool _isMouseScroll = App.isDesktop;

  late int id;

  static int _id = 0;

  var activeChildren = <int>{};

  ScrollState? parent;

  @override
  void initState() {
    _controller = widget.controller ?? ScrollController();
    super.initState();
    id = _id;
    _id++;
  }

  @override
  void didChangeDependencies() {
    parent = ScrollState.maybeOf(context);
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    parent?.onChildInactive(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (App.isMacOS) {
      return widget.builder(
        context,
        _controller,
        const BouncingScrollPhysics(),
      );
    }
    var child = Listener(
      onPointerDown: (event) {
        _futurePosition = null;
        _scrollAnimationToken++;
        if (_isMouseScroll) {
          setState(() {
            _isMouseScroll = false;
          });
        }
      },
      onPointerSignal: (pointerSignal) {
        if (activeChildren.isNotEmpty) {
          return;
        }
        if (pointerSignal is PointerScrollEvent) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            return;
          }
          if (pointerSignal.kind == PointerDeviceKind.mouse &&
              !_isMouseScroll) {
            setState(() {
              _isMouseScroll = true;
            });
          }
          if (!_isMouseScroll) return;
          var currentLocation = _controller.position.pixels;
          var old = _futurePosition;
          _futurePosition ??= currentLocation;
          double k = (_futurePosition! - currentLocation).abs() / 1600 + 1;
          _futurePosition = _futurePosition! + pointerSignal.scrollDelta.dy * k;
          var beforeOffset = (_futurePosition! - currentLocation).abs();
          _futurePosition = _futurePosition!.clamp(
            _controller.position.minScrollExtent,
            _controller.position.maxScrollExtent,
          );
          var afterOffset = (_futurePosition! - currentLocation).abs();
          if (_futurePosition == old) return;
          var target = _futurePosition!;
          var token = ++_scrollAnimationToken;
          var duration = _fastAnimationDuration;
          if (afterOffset < beforeOffset) {
            duration = duration * (afterOffset / beforeOffset);
            if (duration < const Duration(milliseconds: 8)) {
              duration = const Duration(milliseconds: 8);
            }
          }
          _controller
              .animateTo(
                _futurePosition!,
                duration: duration,
                curve: Curves.easeOutCubic,
              )
              .then((_) {
                if (token != _scrollAnimationToken) {
                  return;
                }
                var current = _controller.position.pixels;
                if (current == target && current == _futurePosition) {
                  _futurePosition = null;
                }
              });
        }
      },
      child: ScrollState._(
        controller: _controller,
        onChildActive: (id) {
          activeChildren.add(id);
        },
        onChildInactive: (id) {
          activeChildren.remove(id);
        },
        child: widget.builder(
          context,
          _controller,
          _isMouseScroll
              ? const NeverScrollableScrollPhysics()
              : const BouncingScrollPhysics(),
        ),
      ),
    );

    if (parent != null) {
      return MouseRegion(
        onEnter: (_) {
          parent!.onChildActive(id);
        },
        onExit: (_) {
          parent!.onChildInactive(id);
        },
        child: child,
      );
    }

    return child;
  }
}

class ScrollState extends InheritedWidget {
  const ScrollState._({
    required this.controller,
    required super.child,
    required this.onChildActive,
    required this.onChildInactive,
  });

  final ScrollController controller;

  final void Function(int id) onChildActive;

  final void Function(int id) onChildInactive;

  static ScrollState of(BuildContext context) {
    final ScrollState? provider = context
        .dependOnInheritedWidgetOfExactType<ScrollState>();
    return provider!;
  }

  static ScrollState? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<ScrollState>();
  }

  @override
  bool updateShouldNotify(ScrollState oldWidget) {
    return oldWidget.controller != controller;
  }
}

class AppScrollBar extends StatefulWidget {
  const AppScrollBar({
    super.key,
    required this.controller,
    required this.child,
    this.topPadding = 0,
  });

  final ScrollController controller;

  final Widget child;

  final double topPadding;

  @override
  State<AppScrollBar> createState() => _AppScrollBarState();
}

class _AppScrollBarState extends State<AppScrollBar> {
  late final ScrollController _scrollController;

  double minExtent = 0;
  double maxExtent = 0;
  double position = 0;

  double viewHeight = 0;

  final _scrollIndicatorSize = App.isDesktop ? 36.0 : 54.0;

  late final VerticalDragGestureRecognizer _dragGestureRecognizer;

  bool _isVisible = false;
  Timer? _hideTimer;
  DateTime _lastActivityAt = DateTime.now();
  static const _hideDuration = Duration(seconds: 2);

  /// Repaint signal for the thumb. The scroll listener fires on every scrolled
  /// frame; poking this rebuilds only the thumb subtree instead of setState on
  /// the whole scrollbar (which re-ran the LayoutBuilder and Stack each frame).
  final _thumbSignal = _RepaintSignal();

  @override
  void initState() {
    super.initState();
    _scrollController = widget.controller;
    _scrollController.addListener(onChanged);
    Future.microtask(onChanged);
    _dragGestureRecognizer = VerticalDragGestureRecognizer()
      ..onUpdate = onUpdate
      ..onStart = (_) {
        _showScrollbar(holdOpen: true);
      }
      ..onEnd = (_) {
        _scheduleHide();
      };
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _scrollController.removeListener(onChanged);
    _dragGestureRecognizer.dispose();
    _thumbSignal.dispose();
    super.dispose();
  }

  /// [holdOpen] cancels the pending auto-hide, for hover/drag interactions
  /// that must keep the thumb visible until they end.
  void _showScrollbar({bool holdOpen = false}) {
    if (!_isVisible && mounted) {
      setState(() {
        _isVisible = true;
      });
    }
    if (holdOpen) {
      _hideTimer?.cancel();
      _hideTimer = null;
    }
  }

  /// Refreshes the auto-hide deadline. A single timer re-checks the deadline
  /// when it fires, instead of being cancelled and re-created on every scroll
  /// tick.
  void _scheduleHide() {
    _lastActivityAt = DateTime.now();
    _hideTimer ??= Timer(_hideDuration, _onHideTimeout);
  }

  void _onHideTimeout() {
    _hideTimer = null;
    if (!mounted) return;
    final idle = DateTime.now().difference(_lastActivityAt);
    if (idle < _hideDuration) {
      _hideTimer = Timer(_hideDuration - idle, _onHideTimeout);
      return;
    }
    if (_isVisible) {
      setState(() {
        _isVisible = false;
      });
    }
  }

  void onUpdate(DragUpdateDetails details) {
    if (maxExtent - minExtent <= 0 ||
        viewHeight == 0 ||
        details.primaryDelta == null) {
      return;
    }
    var offset = details.primaryDelta!;
    var positionOffset =
        offset / (viewHeight - _scrollIndicatorSize) * (maxExtent - minExtent);
    _scrollController.jumpTo(
      (position + positionOffset).clamp(minExtent, maxExtent),
    );
  }

  void onChanged() {
    if (_scrollController.positions.isEmpty) return;
    var position = _scrollController.position;

    if (position.minScrollExtent == minExtent &&
        position.maxScrollExtent == maxExtent &&
        position.pixels == this.position) {
      return;
    }
    minExtent = position.minScrollExtent;
    maxExtent = position.maxScrollExtent;
    this.position = position.pixels;

    _thumbSignal.notify();
    _showScrollbar();
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constrains) {
        var height = constrains.maxHeight - widget.topPadding;
        viewHeight = height;
        return Stack(
          children: [
            Positioned.fill(child: widget.child),
            ListenableBuilder(
              listenable: _thumbSignal,
              builder: (context, _) {
                var scrollHeight = (maxExtent - minExtent);
                var top = scrollHeight == 0
                    ? 0.0
                    : (position - minExtent) /
                          scrollHeight *
                          (height - _scrollIndicatorSize);
                return Positioned(
                  top: top + widget.topPadding,
                  right: 0,
                  child: AnimatedOpacity(
                    opacity: _isVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      onEnter: (_) => _showScrollbar(holdOpen: true),
                      onExit: (_) => _scheduleHide(),
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (event) {
                          // A faded-out thumb still hit-tests, so without this
                          // it would fight page gestures (reorder handles,
                          // swipe actions) for drags near the right edge.
                          if (!_isVisible) return;
                          _dragGestureRecognizer.addPointer(event);
                        },
                        child: SizedBox(
                          width: _scrollIndicatorSize / 2,
                          height: _scrollIndicatorSize,
                          child: CustomPaint(
                            painter: _ScrollIndicatorPainter(
                              backgroundColor: context.colorScheme.surface,
                              shadowColor: context.colorScheme.shadow,
                            ),
                            child: Column(
                              children: [
                                const Spacer(),
                                Icon(Icons.arrow_drop_up, size: 18),
                                Icon(Icons.arrow_drop_down, size: 18),
                                const Spacer(),
                              ],
                            ).paddingLeft(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

/// A [ChangeNotifier] whose only job is exposing [notifyListeners] as a
/// public repaint signal for a scoped [ListenableBuilder].
class _RepaintSignal extends ChangeNotifier {
  void notify() => notifyListeners();
}

class _ScrollIndicatorPainter extends CustomPainter {
  final Color backgroundColor;

  final Color shadowColor;

  const _ScrollIndicatorPainter({
    required this.backgroundColor,
    required this.shadowColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    var path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..arcToPoint(Offset(size.width, 0), radius: Radius.circular(size.width));
    canvas.drawShadow(path, shadowColor, 2, true);
    var backgroundPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;
    path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..arcToPoint(Offset(size.width, 0), radius: Radius.circular(size.width));
    canvas.drawPath(path, backgroundPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ScrollIndicatorPainter ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.shadowColor != shadowColor;
  }
}

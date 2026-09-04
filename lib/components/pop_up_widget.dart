part of 'components.dart';

class PopUpWidget<T> extends PopupRoute<T> {
  PopUpWidget(this.widget);

  final Widget widget;

  @override
  Color? get barrierColor => Colors.black54;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => "exit";

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    var height = MediaQuery.sizeOf(context).height * 0.9;
    bool showPopUp = MediaQuery.sizeOf(context).width > 500;
    Widget body = PopupIndicatorWidget(
      child: Container(
        decoration: showPopUp
            ? BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                boxShadow: context.brightness == ui.Brightness.dark
                    ? [
                        BoxShadow(
                          color: Colors.white.withAlpha(50),
                          blurRadius: 10,
                          offset: Offset(0, 2),
                        ),
                      ]
                    : null,
              )
            : null,
        clipBehavior: showPopUp ? Clip.antiAlias : Clip.none,
        width: showPopUp ? 500 : double.infinity,
        height: showPopUp ? height : double.infinity,
        child: ClipRect(
          child: Navigator(
            onGenerateRoute: (settings) =>
                MaterialPageRoute(builder: (context) => widget),
          ),
        ),
      ),
    );
    if (App.isIOS) {
      body = IOSBackGestureDetector(
        enabledCallback: () => true,
        gestureWidth: 20.0,
        onStartPopGesture: () =>
            IOSBackGestureController(controller!, navigator!),
        child: body,
      );
    }
    if (showPopUp) {
      return MediaQuery.removePadding(
        removeTop: true,
        context: context,
        child: Center(child: body),
      );
    }
    return body;
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 220);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation.drive(
        Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
      ),
      child: RepaintBoundary(child: child),
    );
  }
}

class PopupIndicatorWidget extends InheritedWidget {
  const PopupIndicatorWidget({super.key, required super.child});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;

  static PopupIndicatorWidget? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PopupIndicatorWidget>();
  }
}

Future<T> showPopUpWidget<T>(BuildContext context, Widget widget) async {
  return await Navigator.of(
    context,
    rootNavigator: true,
  ).push(PopUpWidget(widget));
}

class PopUpWidgetScaffold extends StatefulWidget {
  const PopUpWidgetScaffold({
    required this.title,
    required this.body,
    this.tailing,
    super.key,
  });

  final Widget body;
  final List<Widget>? tailing;
  final String title;

  @override
  State<PopUpWidgetScaffold> createState() => _PopUpWidgetScaffoldState();
}

class _PopUpWidgetScaffoldState extends State<PopUpWidgetScaffold> {
  bool top = true;

  /// Keeps the last row of content clear of the navigation bar / gesture area.
  /// On wide screens the pop up is a centered card, so only a small gap is
  /// needed; the system inset belongs to the page behind it.
  double _bottomPadding(BuildContext context) {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      // Keyboard is up: the spacer below already reserves room.
      return 8;
    }
    var isCard = MediaQuery.sizeOf(context).width > 500;
    return (isCard ? 0 : context.padding.bottom) + 8;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surface,
      child: Column(
        children: [
          Container(
            height: 56 + context.padding.top,
            padding: EdgeInsets.only(top: context.padding.top),
            width: double.infinity,
            decoration: BoxDecoration(
              color: top
                  ? colorScheme.surface
                  : Color.alphaBlend(
                      colorScheme.surfaceTint.withAlpha(20),
                      colorScheme.surface,
                    ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 8),
                Tooltip(
                  message: "Back".tl,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_sharp),
                    onPressed: () =>
                        context.canPop() ? context.pop() : App.pop(),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.tailing != null) ...widget.tailing!,
                const SizedBox(width: 8),
              ],
            ),
          ),
          NotificationListener<ScrollNotification>(
            onNotification: (notifications) {
              if (notifications.metrics.axisDirection != AxisDirection.down) {
                return false;
              }
              if (notifications.metrics.pixels ==
                      notifications.metrics.minScrollExtent &&
                  !top) {
                setState(() {
                  top = true;
                });
              } else if (notifications.metrics.pixels !=
                      notifications.metrics.minScrollExtent &&
                  top) {
                setState(() {
                  top = false;
                });
              }
              return false;
            },
            child: MediaQuery.removePadding(
              removeTop: true,
              context: context,
              child: Expanded(
                child: Padding(
                  padding: EdgeInsets.only(bottom: _bottomPadding(context)),
                  child: widget.body,
                ),
              ),
            ),
          ),
          SizedBox(
            height:
                MediaQuery.viewInsetsOf(context).bottom -
                        0.05 * MediaQuery.sizeOf(context).height >
                    0
                ? MediaQuery.viewInsetsOf(context).bottom -
                      0.05 * MediaQuery.sizeOf(context).height
                : 0,
          ),
        ],
      ),
    );
  }
}

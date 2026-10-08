part of 'settings_page.dart';

/// Makes collapsed groups searchable only while opening a search result.
class _SettingsJumpScope extends InheritedWidget {
  const _SettingsJumpScope({required this.title, required super.child});
  final String title;
  static String? targetOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SettingsJumpScope>()?.title;
  @override
  bool updateShouldNotify(_SettingsJumpScope oldWidget) =>
      title != oldWidget.title;
}

class _SettingsDestination extends StatefulWidget {
  const _SettingsDestination({
    required this.child,
    required this.title,
    this.fallback,
  });
  final Widget child;
  final String title;
  final String? fallback;
  @override
  State<_SettingsDestination> createState() => _SettingsDestinationState();
}

class _SettingsDestinationState extends State<_SettingsDestination> {
  final _content = GlobalKey();
  final _stack = GlobalKey();
  Rect? _highlight;
  Timer? _timer;
  bool _unavailable = false;
  bool _locating = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  Element? _find(String title) {
    Element? found;
    void visit(Element element) {
      if (found != null) return;
      final widget = element.widget;
      if (widget is Text && widget.data == title.tl) {
        found = element;
      } else {
        element.visitChildren(visit);
      }
    }

    final root = _content.currentContext;
    if (root is Element) root.visitChildren(visit);
    return found;
  }

  ScrollPosition? _scrollPosition() {
    ScrollPosition? found;
    void visit(Element element) {
      if (found != null) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (axisDirectionToAxis(position.axisDirection) == Axis.vertical) {
          found = position;
        }
      }
      if (found == null) element.visitChildren(visit);
    }

    final root = _content.currentContext;
    if (root is Element) root.visitChildren(visit);
    return found;
  }

  Future<Element?> _locate(String title) async {
    for (var step = 0; step < 80 && mounted; step++) {
      final target = _find(title);
      if (target != null) return target;
      final position = _scrollPosition();
      if (position == null ||
          !position.hasContentDimensions ||
          position.pixels >= position.maxScrollExtent) {
        return null;
      }
      position.jumpTo(
        (position.pixels + position.viewportDimension * 0.8).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
      await WidgetsBinding.instance.endOfFrame;
    }
    return null;
  }

  Future<void> _reveal() async {
    try {
      await _revealTarget();
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _revealTarget() async {
    if (!mounted) return;
    var target = await _locate(widget.title);
    if (!mounted) return;
    if (target == null) {
      setState(() => _unavailable = true);
      final position = _scrollPosition();
      position?.jumpTo(0);
      await WidgetsBinding.instance.endOfFrame;
      if (widget.fallback != null) target = await _locate(widget.fallback!);
    }
    if (target == null) return;
    final controllers = <ExpansibleController>{};
    target.visitAncestorElements((element) {
      final controller = ExpansibleController.maybeOf(element);
      if (controller != null) controllers.add(controller);
      return true;
    });
    for (final controller in controllers) {
      controller.expand();
    }
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      alignment: 0.15,
      duration: const Duration(milliseconds: 200),
    );
    if (!mounted || !target.mounted) return;
    BuildContext row = target;
    target.visitAncestorElements((element) {
      if (element.widget is ListTile || element.widget is SwitchListTile) {
        row = element;
        return false;
      }
      return element != _content.currentContext;
    });
    final box = row.findRenderObject();
    final stack = _stack.currentContext?.findRenderObject();
    if (box is! RenderBox || stack is! RenderBox || !box.hasSize) return;
    setState(
      () => _highlight =
          box.localToGlobal(Offset.zero, ancestor: stack) & box.size,
    );
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SettingsJumpScope(
    title: widget.title,
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (_highlight != null && notification is ScrollUpdateNotification) {
          setState(() => _highlight = null);
        }
        return false;
      },
      child: Stack(
        key: _stack,
        children: [
          IgnorePointer(
            ignoring: _locating,
            child: Opacity(
              opacity: _locating ? 0 : 1,
              child: Column(
                children: [
                  if (_unavailable)
                    Material(
                      color: context.colorScheme.secondaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          'This option is unavailable in the current mode. Check the related controls below.'
                              .tl,
                        ),
                      ),
                    ),
                  Expanded(
                    child: KeyedSubtree(key: _content, child: widget.child),
                  ),
                ],
              ),
            ),
          ),
          if (_locating) const Center(child: CircularProgressIndicator()),
          if (_highlight != null)
            Positioned.fromRect(
              rect: _highlight!,
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('settings-search-highlight'),
                  decoration: BoxDecoration(
                    color: context.colorScheme.primary.withValues(alpha: 0.09),
                    border: Border.all(
                      color: context.colorScheme.primary,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

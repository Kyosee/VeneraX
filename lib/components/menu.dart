part of "components.dart";

Future<void> showMenuX(
  BuildContext context,
  Offset location,
  List<MenuEntry> entries, {
  String? title,
  String? subtitle,
  Widget? leading,
}) async {
  // Keep each action in place while allowing page-specific callbacks to win.
  final actions = <MenuAction, MenuEntry>{};
  for (final entry in entries) {
    if (entry.action != null) actions[entry.action!] = entry;
  }
  final used = <MenuAction>{};
  final resolved = <MenuEntry>[
    for (final entry in entries)
      if (entry.action == null)
        entry
      else if (used.add(entry.action!))
        actions[entry.action!]!,
  ];
  if (resolved.isEmpty) return;
  final MenuEntry? selected;
  if (App.isMobile) {
    selected = await showModalBottomSheet<MenuEntry>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      builder: (context) => _MobileMenu(
        entries: resolved,
        title: title,
        subtitle: subtitle,
        leading: leading,
      ),
    );
  } else {
    selected = await Navigator.of(
      context,
      rootNavigator: true,
    ).push<MenuEntry>(_MenuRoute(resolved, location));
  }
  selected?.onClick();
}

class _MenuRoute extends PopupRoute<MenuEntry> {
  final List<MenuEntry> entries;

  final Offset location;

  _MenuRoute(this.entries, this.location);

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => 'Close'.tl;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => _DesktopMenu(entries: entries, location: location);

  @override
  Duration get transitionDuration => Duration.zero;
}

class _DesktopMenu extends StatefulWidget {
  const _DesktopMenu({required this.entries, required this.location});

  final List<MenuEntry> entries;
  final Offset location;

  @override
  State<_DesktopMenu> createState() => _DesktopMenuState();
}

class _DesktopMenuState extends State<_DesktopMenu> {
  static const _buttonStyle = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size(0, 44)),
    padding: WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    ),
    textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 15)),
  );

  final _controller = MenuController();
  final _focusNode = FocusNode();
  final _itemFocusNodes = <FocusNode>[];
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.open(position: widget.location);
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    for (final node in _itemFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _close([MenuEntry? entry]) {
    if (!mounted || _closing) return;
    _closing = true;
    _controller.close();
    Navigator.of(context).pop(entry);
  }

  Widget _item(MenuEntry entry, {FocusNode? focusNode}) {
    final color = entry.destructive ? context.colorScheme.error : entry.color;
    return MenuItemButton(
      focusNode: focusNode,
      closeOnActivate: false,
      onPressed: () => _close(entry),
      leadingIcon: entry.icon == null ? null : Icon(entry.icon, size: 20),
      style: _buttonStyle.copyWith(
        foregroundColor: color == null ? null : WidgetStatePropertyAll(color),
      ),
      child: Text(entry.text, softWrap: true),
    );
  }

  List<Widget> _items() {
    final entries = widget.entries;
    var focusIndex = 0;
    FocusNode nextFocusNode() {
      if (focusIndex == _itemFocusNodes.length) {
        _itemFocusNodes.add(FocusNode());
      }
      return _itemFocusNodes[focusIndex++];
    }

    final result = <Widget>[
      for (final entry in entries)
        if (entry.group == null && !entry.destructive)
          _item(entry, focusNode: nextFocusNode()),
    ];
    final grouped = <Widget>[];
    for (final group in MenuGroup.values) {
      final items = entries
          .where((entry) => entry.group == group && !entry.destructive)
          .toList();
      if (items.isEmpty) continue;
      grouped.add(
        items.length == 1
            ? _item(items.single, focusNode: nextFocusNode())
            : SubmenuButton(
                focusNode: nextFocusNode(),
                style: _buttonStyle,
                leadingIcon: Icon(group.icon, size: 20),
                menuChildren: items.map(_item).toList(),
                child: Text(group.label),
              ),
      );
    }
    if (result.isNotEmpty && grouped.isNotEmpty) {
      result.add(const Divider(height: 12));
    }
    result.addAll(grouped);
    final destructive = entries.where((entry) => entry.destructive).toList();
    if (result.isNotEmpty && destructive.isNotEmpty) {
      result.add(const Divider(height: 12));
    }
    for (final entry in destructive) {
      result.add(_item(entry, focusNode: nextFocusNode()));
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final width = math.min(360.0, MediaQuery.sizeOf(context).width - 24);
    final style = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(
        context.colorScheme.surfaceContainer,
      ),
      minimumSize: WidgetStatePropertyAll(Size(math.min(272, width), 0)),
      maximumSize: WidgetStatePropertyAll(Size(width, double.infinity)),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
    return MenuTheme(
      data: MenuThemeData(style: style),
      child: MenuAnchor(
        controller: _controller,
        childFocusNode: _focusNode,
        consumeOutsideTap: true,
        onClose: _close,
        menuChildren: _items(),
        child: Focus(
          focusNode: _focusNode,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                _itemFocusNodes.first.requestFocus();
                return KeyEventResult.handled;
              }
              if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                _itemFocusNodes.last.requestFocus();
                return KeyEventResult.handled;
              }
            }
            return KeyEventResult.ignored;
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

enum MenuAction {
  read,
  details,
  favorite,
  readLater,
  collection,
  select,
  download,
  migrate,
  remove,
}

enum MenuGroup {
  organize,
  source,
  export,
  more;

  String get label => switch (this) {
    organize => 'Organize'.tl,
    source => 'Source'.tl,
    export => 'Export'.tl,
    more => 'more'.tl,
  };

  IconData get icon => switch (this) {
    organize => Icons.folder_outlined,
    source => Icons.hub_outlined,
    export => Icons.ios_share_outlined,
    more => Icons.more_horiz,
  };
}

enum MenuEntryRole { normal, primary, quick }

class MenuEntry {
  final String text;
  final IconData? icon;
  final Color? color;
  final void Function() onClick;
  final MenuAction? action;
  final MenuGroup? group;
  final MenuEntryRole role;
  final bool destructive;
  final bool isSelected;
  final String? compactText;
  final String? subtitle;

  const MenuEntry({
    required this.text,
    this.icon,
    this.color,
    required this.onClick,
    this.action,
    this.group,
    this.role = MenuEntryRole.normal,
    this.destructive = false,
    this.isSelected = false,
    this.compactText,
    this.subtitle,
  });
}

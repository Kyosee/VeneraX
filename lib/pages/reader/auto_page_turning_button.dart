import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/auto_page_turning.dart';
import 'package:venera/utils/translations.dart';

class ReaderAutoPageTurningButton extends StatefulWidget {
  const ReaderAutoPageTurningButton({
    super.key,
    required this.tooltip,
    required this.isSelected,
    required this.readerMode,
    required this.comicId,
    required this.comicSource,
    required this.onPressed,
    required this.onChanged,
  });

  final String tooltip;
  final bool isSelected;
  final String readerMode;
  final String comicId;
  final String comicSource;
  final VoidCallback onPressed;
  final VoidCallback onChanged;

  @override
  State<ReaderAutoPageTurningButton> createState() =>
      _ReaderAutoPageTurningButtonState();
}

class _ReaderAutoPageTurningButtonState
    extends State<ReaderAutoPageTurningButton> {
  final _menuController = MenuController();
  LocalHistoryEntry? _historyEntry;

  void _onOpen() {
    final route = ModalRoute.of(context);
    if (route == null) return;
    _historyEntry = LocalHistoryEntry(
      impliesAppBarDismissal: false,
      onRemove: () {
        _historyEntry = null;
        _menuController.close();
      },
    );
    route.addLocalHistoryEntry(_historyEntry!);
  }

  void _onClose() {
    final entry = _historyEntry;
    _historyEntry = null;
    entry?.remove();
  }

  @override
  void dispose() {
    _onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canScroll = widget.readerMode.startsWith('continuous');
    final mode =
        autoTurnScrolls(
          widget.readerMode,
          appdata.settings.getReaderSetting(
            widget.comicId,
            widget.comicSource,
            'autoPageTurningMode',
          ),
        )
        ? autoTurnModeScroll
        : autoTurnModePage;
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      controller: _menuController,
      consumeOutsideTap: true,
      onOpen: _onOpen,
      onClose: _onClose,
      style: MenuStyle(
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
      ),
      menuChildren: [
        Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          child: SizedBox(
            width: math.min(280, MediaQuery.sizeOf(context).width - 32),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 18,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text('Auto page turning mode'.tl)),
                      ],
                    ),
                  ),
                  for (final (value, title, icon) in [
                    (
                      autoTurnModePage,
                      'Turn pages',
                      Icons.auto_stories_outlined,
                    ),
                    (autoTurnModeScroll, 'Scroll', Icons.swap_vert),
                  ])
                    MenuItemButton(
                      autofocus: value == mode,
                      leadingIcon: Icon(icon),
                      trailingIcon: value == mode
                          ? const Icon(Icons.check)
                          : null,
                      onPressed: value == autoTurnModeScroll && !canScroll
                          ? null
                          : () {
                              _menuController.close();
                              if (!mounted || value == mode) return;
                              setState(() {
                                appdata.settings.setEffectiveReaderSetting(
                                  widget.comicId,
                                  widget.comicSource,
                                  'autoPageTurningMode',
                                  value,
                                );
                              });
                              appdata.saveData();
                              widget.onChanged();
                            },
                      child: Text(title.tl),
                    ),
                  if (!canScroll)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: Text(
                        'Scrolling is available in continuous reading modes'.tl,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => Tooltip(
        message:
            '${widget.tooltip}\n${"Long press to choose auto page turning mode".tl}',
        triggerMode: TooltipTriggerMode.manual,
        child: IconButton(
          isSelected: widget.isSelected,
          icon: const Icon(Icons.timer_outlined),
          selectedIcon: const Icon(Icons.timer),
          onPressed: () {
            controller.close();
            widget.onPressed();
          },
          onLongPress: controller.open,
        ),
      ),
    );
  }
}

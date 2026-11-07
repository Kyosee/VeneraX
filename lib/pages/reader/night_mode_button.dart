import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/translations.dart';

class ReaderNightModeButton extends StatefulWidget {
  const ReaderNightModeButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.onChanged,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final VoidCallback onChanged;

  @override
  State<ReaderNightModeButton> createState() => _ReaderNightModeButtonState();
}

class _ReaderNightModeButtonState extends State<ReaderNightModeButton> {
  final _menuController = MenuController();
  LocalHistoryEntry? _historyEntry;
  bool _needsSave = false;

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
    _save();
  }

  void _save() {
    if (!_needsSave) return;
    _needsSave = false;
    appdata.saveData();
  }

  @override
  void dispose() {
    _onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final raw = appdata.settings['readerNightModeIntensity'];
    final intensity = (raw is num ? raw.toDouble() : 0.45).clamp(0.1, 0.85);
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
        SizedBox(
          width: math.min(280, MediaQuery.sizeOf(context).width - 32),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.nightlight_round,
                      size: 18,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text('Night mode intensity'.tl)),
                    const SizedBox(width: 8),
                    Text(
                      '${(intensity * 100).round()}%',
                      style: TextStyle(color: colors.primary),
                    ),
                  ],
                ),
                Semantics(
                  label: 'Night mode intensity'.tl,
                  child: Slider(
                    autofocus: true,
                    min: 0.1,
                    max: 0.85,
                    divisions: 15,
                    value: intensity,
                    semanticFormatterCallback: (value) =>
                        '${(value * 100).round()}%',
                    onChanged: (value) {
                      setState(() {
                        appdata.settings['readerNightModeIntensity'] =
                            (value * 100).round() / 100;
                        // Adjusting is a manual choice and must preview now.
                        appdata.settings['readerNightMode'] = true;
                        appdata.settings['readerNightModeFollowSystem'] = false;
                        _needsSave = true;
                      });
                      widget.onChanged();
                    },
                    onChangeEnd: (_) => _save(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) => Tooltip(
        message: '${widget.tooltip}\n${"Long press to adjust intensity".tl}',
        triggerMode: TooltipTriggerMode.manual,
        child: IconButton(
          icon: Icon(
            appdata.settings['readerNightMode'] == true
                ? Icons.nightlight_round
                : Icons.nightlight_outlined,
          ),
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

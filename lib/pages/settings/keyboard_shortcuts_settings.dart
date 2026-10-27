part of 'settings_page.dart';

/// Desktop shortcut bindings. Tap a row to record a new combination.
class KeyboardShortcutsSettings extends StatefulWidget {
  const KeyboardShortcutsSettings({super.key});

  @override
  State<KeyboardShortcutsSettings> createState() =>
      _KeyboardShortcutsSettingsState();
}

class _KeyboardShortcutsSettingsState extends State<KeyboardShortcutsSettings> {
  Future<void> _edit(ShortcutAction action) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (context) => _ShortcutRecorderDialog(action: action),
    );
    if (changed != true || !mounted) return;
    setState(() {});
    if (GlobalHotkeys.failed.contains(action)) {
      context.showMessage(
        message: "This combination is in use by another program".tl,
      );
    }
  }

  Future<void> _resetAll() async {
    AppShortcuts.resetAll();
    await GlobalHotkeys.sync();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final actions = ShortcutAction.values.where((a) => a.isAvailable);
    return Scaffold(
      appBar: Appbar(
        title: Text("Keyboard shortcuts".tl),
        actions: [
          Tooltip(
            message: "Reset to Default".tl,
            child: IconButton(
              icon: const Icon(Icons.restart_alt),
              onPressed: _resetAll,
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _ShortcutGroupHeader("General".tl),
          for (final a in actions.where((a) => a.scope != ShortcutScope.reader))
            _buildTile(a),
          _ShortcutGroupHeader("Reader".tl),
          for (final a in actions.where((a) => a.scope == ShortcutScope.reader))
            _buildTile(a),
          Text(
            "Arrow keys turn pages in the reading direction; Esc leaves the reader."
                .tl,
            style: ts.s12.copyWith(color: context.colorScheme.outline),
          ).paddingHorizontal(16).paddingTop(8),
        ],
      ),
    );
  }

  Widget _buildTile(ShortcutAction action) {
    final binding = AppShortcuts.bindingOf(action);
    String? subtitle;
    if (action.scope == ShortcutScope.global) {
      subtitle = GlobalHotkeys.failed.contains(action)
          ? "This combination is in use by another program".tl
          : "Works even while the window is hidden".tl;
    }
    return ListTile(
      title: Text(action.title.tl),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: binding == null
          ? Text(
              "Not set".tl,
              style: TextStyle(color: context.colorScheme.outline),
            )
          : _KeyCap(binding.label),
      onTap: () => _edit(action),
    );
  }
}

class _ShortcutGroupHeader extends StatelessWidget {
  const _ShortcutGroupHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: ts.s14.copyWith(
        color: context.colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ).paddingHorizontal(16).paddingTop(16).paddingBottom(4);
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.colorScheme.outlineVariant),
      ),
      child: Text(label, style: ts.s14),
    );
  }
}

/// Records one combination for [action]. Pops true once the binding changed.
class _ShortcutRecorderDialog extends StatefulWidget {
  const _ShortcutRecorderDialog({required this.action});

  final ShortcutAction action;

  @override
  State<_ShortcutRecorderDialog> createState() =>
      _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<_ShortcutRecorderDialog> {
  final _focusNode = FocusNode();

  /// The last combination pressed, shown in place of the current binding.
  KeyBinding? _pressed;

  String? _error;

  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Nothing may fire while recording, including the global hotkey that is
    // being replaced.
    AppShortcuts.suspended = true;
    GlobalHotkeys.pause();
  }

  @override
  void dispose() {
    // Cancel / Esc / the close button; _finish has already resumed otherwise.
    if (!_done) _release();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _release() {
    AppShortcuts.suspended = false;
    return GlobalHotkeys.resume();
  }

  Future<void> _finish(KeyBinding? binding) async {
    if (_done) return;
    _done = true;
    AppShortcuts.setBinding(widget.action, binding);
    // Re-register before closing so the page sees whether the system took it.
    await _release();
    if (mounted) context.pop(true);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_done) return KeyEventResult.handled;
    // Let Esc close the dialog.
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent ||
        KeyBinding.modifierKeys.contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    final binding = KeyBinding.fromEvent(event);
    var error = AppShortcuts.validate(widget.action, binding)?.tl;
    if (error == null) {
      final other = AppShortcuts.conflictOf(binding, except: widget.action);
      if (other != null) {
        error = "Already used by @a".tlParams({'a': other.title.tl});
      }
    }
    if (error == null) {
      _finish(binding);
    } else {
      setState(() {
        _pressed = binding;
        _error = error;
      });
    }
    return KeyEventResult.handled;
  }

  void _resetToDefault() {
    final binding = AppShortcuts.defaultBinding(widget.action);
    final other = binding == null
        ? null
        : AppShortcuts.conflictOf(binding, except: widget.action);
    if (other != null) {
      setState(() {
        _pressed = binding;
        _error = "Already used by @a".tlParams({'a': other.title.tl});
      });
      return;
    }
    _finish(binding);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _pressed ?? AppShortcuts.bindingOf(widget.action);
    return ContentDialog(
      title: widget.action.title.tl,
      content: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _focusNode.requestFocus,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Press the new key combination".tl, style: ts.s14),
                const SizedBox(height: 16),
                if (shown == null)
                  Text(
                    "Not set".tl,
                    style: TextStyle(color: context.colorScheme.outline),
                  )
                else
                  _KeyCap(shown.label),
                const SizedBox(height: 12),
                Text(
                  _error ?? '',
                  textAlign: TextAlign.center,
                  style: ts.s12.copyWith(color: context.colorScheme.error),
                ),
              ],
            ).paddingVertical(8),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => _finish(null), child: Text("Clear".tl)),
        TextButton(
          onPressed: _resetToDefault,
          child: Text("Reset to Default".tl),
        ),
        const SizedBox(width: 8),
        FilledButton(onPressed: () => context.pop(), child: Text("Cancel".tl)),
      ],
    );
  }
}

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/tray.dart';

enum ShortcutScope {
  /// Anywhere in the app while the window has focus.
  app,

  /// Only while the reader is open.
  reader,

  /// System-wide, even while the window is hidden. Windows only.
  global,
}

/// Desktop keyboard shortcuts the user can rebind. [title] is the English
/// source string; translate it with `.tl` at the call site.
enum ShortcutAction {
  toggleFullscreen(ShortcutScope.app, "Toggle fullscreen"),
  toggleWindow(ShortcutScope.global, "Hide to tray / show window"),
  nextPage(ShortcutScope.reader, "Next page"),
  prevPage(ShortcutScope.reader, "Previous page"),
  nextChapter(ShortcutScope.reader, "Next Chapter"),
  prevChapter(ShortcutScope.reader, "Previous Chapter"),
  toggleReaderMenu(ShortcutScope.reader, "Show / hide reader menu"),
  toggleAutoPageTurning(ShortcutScope.reader, "Auto Page Turning"),
  toggleNightMode(ShortcutScope.reader, "Night mode"),
  collectImage(ShortcutScope.reader, "Collect the image");

  const ShortcutAction(this.scope, this.title);

  final ShortcutScope scope;

  final String title;

  /// The tray lives on Windows only, and so does the system-wide hotkey.
  bool get isAvailable => switch (this) {
    toggleWindow => App.isWindows,
    _ => App.isDesktop,
  };
}

/// A non-modifier key plus the modifiers held with it.
@immutable
class KeyBinding {
  const KeyBinding(
    this.key, {
    this.control = false,
    this.shift = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool shift;
  final bool alt;
  final bool meta;

  /// Reads the modifiers from [HardwareKeyboard], which is already up to date
  /// when the event is dispatched.
  factory KeyBinding.fromEvent(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return KeyBinding(
      event.logicalKey,
      control: keyboard.isControlPressed,
      shift: keyboard.isShiftPressed,
      alt: keyboard.isAltPressed,
      meta: keyboard.isMetaPressed,
    );
  }

  /// `ctrl+shift+<keyId>`; the key id is stable across platforms and builds.
  String encode() => [
    if (control) 'ctrl',
    if (shift) 'shift',
    if (alt) 'alt',
    if (meta) 'meta',
    key.keyId.toString(),
  ].join('+');

  static KeyBinding? decode(String? value) {
    if (value == null || value.isEmpty) return null;
    final parts = value.split('+');
    final keyId = int.tryParse(parts.last);
    if (keyId == null) return null;
    final modifiers = parts.sublist(0, parts.length - 1).toSet();
    const known = {'ctrl', 'shift', 'alt', 'meta'};
    if (!known.containsAll(modifiers)) return null;
    return KeyBinding(
      LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId),
      control: modifiers.contains('ctrl'),
      shift: modifiers.contains('shift'),
      alt: modifiers.contains('alt'),
      meta: modifiers.contains('meta'),
    );
  }

  bool matches(KeyEvent event) => KeyBinding.fromEvent(event) == this;

  /// Combinations a text field never turns into input.
  bool get hasCommandModifier => control || alt || meta;

  bool get isFunctionKey =>
      key.keyId >= LogicalKeyboardKey.f1.keyId &&
      key.keyId <= LogicalKeyboardKey.f24.keyId;

  static final modifierKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.capsLock,
    LogicalKeyboardKey.fn,
    LogicalKeyboardKey.fnLock,
  };

  String get label {
    final name = keyLabel(key);
    if (App.isMacOS) {
      return [
        if (control) '⌃',
        if (alt) '⌥',
        if (shift) '⇧',
        if (meta) '⌘',
        name,
      ].join();
    }
    return [
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) App.isLinux ? 'Super' : 'Win',
      name,
    ].join(' + ');
  }

  static String keyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    final label = key.keyLabel;
    if (label.isEmpty) {
      return '0x${key.keyId.toRadixString(16)}';
    }
    return label.length == 1 ? label.toUpperCase() : label;
  }

  @override
  bool operator ==(Object other) =>
      other is KeyBinding &&
      other.key == key &&
      other.control == control &&
      other.shift == shift &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, control, shift, alt, meta);
}

/// Windows virtual-key code for [key], or null when a global hotkey can't use
/// it. Letters and digits carry their lowercase ASCII as the logical key id.
int? windowsVirtualKey(LogicalKeyboardKey key) {
  final id = key.keyId;
  if (id >= 0x61 && id <= 0x7a) return id - 0x20;
  if (id >= 0x30 && id <= 0x39) return id;
  final f1 = LogicalKeyboardKey.f1.keyId;
  if (id >= f1 && id <= LogicalKeyboardKey.f24.keyId) return 0x70 + id - f1;
  return _windowsVirtualKeys[key];
}

final _windowsVirtualKeys = <LogicalKeyboardKey, int>{
  LogicalKeyboardKey.space: 0x20,
  LogicalKeyboardKey.enter: 0x0D,
  LogicalKeyboardKey.backspace: 0x08,
  LogicalKeyboardKey.pageUp: 0x21,
  LogicalKeyboardKey.pageDown: 0x22,
  LogicalKeyboardKey.end: 0x23,
  LogicalKeyboardKey.home: 0x24,
  LogicalKeyboardKey.arrowLeft: 0x25,
  LogicalKeyboardKey.arrowUp: 0x26,
  LogicalKeyboardKey.arrowRight: 0x27,
  LogicalKeyboardKey.arrowDown: 0x28,
  LogicalKeyboardKey.insert: 0x2D,
  LogicalKeyboardKey.delete: 0x2E,
  LogicalKeyboardKey.pause: 0x13,
  LogicalKeyboardKey.numpad0: 0x60,
  LogicalKeyboardKey.numpad1: 0x61,
  LogicalKeyboardKey.numpad2: 0x62,
  LogicalKeyboardKey.numpad3: 0x63,
  LogicalKeyboardKey.numpad4: 0x64,
  LogicalKeyboardKey.numpad5: 0x65,
  LogicalKeyboardKey.numpad6: 0x66,
  LogicalKeyboardKey.numpad7: 0x67,
  LogicalKeyboardKey.numpad8: 0x68,
  LogicalKeyboardKey.numpad9: 0x69,
  LogicalKeyboardKey.numpadMultiply: 0x6A,
  LogicalKeyboardKey.numpadAdd: 0x6B,
  LogicalKeyboardKey.numpadSubtract: 0x6D,
  LogicalKeyboardKey.numpadDecimal: 0x6E,
  LogicalKeyboardKey.numpadDivide: 0x6F,
  LogicalKeyboardKey.semicolon: 0xBA,
  LogicalKeyboardKey.equal: 0xBB,
  LogicalKeyboardKey.comma: 0xBC,
  LogicalKeyboardKey.minus: 0xBD,
  LogicalKeyboardKey.period: 0xBE,
  LogicalKeyboardKey.slash: 0xBF,
  LogicalKeyboardKey.backquote: 0xC0,
  LogicalKeyboardKey.bracketLeft: 0xDB,
  LogicalKeyboardKey.backslash: 0xDC,
  LogicalKeyboardKey.bracketRight: 0xDD,
  LogicalKeyboardKey.quote: 0xDE,
};

/// Bindings live in `keyboardShortcuts` as overrides only: action name →
/// encoded binding, '' for unbound. Anything absent follows [defaultBinding].
class AppShortcuts {
  AppShortcuts._();

  static const _settingKey = 'keyboardShortcuts';

  /// Set while the binding editor records a key, so nothing fires meanwhile.
  static bool suspended = false;

  static KeyBinding? defaultBinding(ShortcutAction action) => switch (action) {
    ShortcutAction.toggleFullscreen =>
      App.isMacOS
          ? const KeyBinding(LogicalKeyboardKey.keyF, control: true, meta: true)
          : const KeyBinding(LogicalKeyboardKey.f11),
    ShortcutAction.nextPage => const KeyBinding(LogicalKeyboardKey.space),
    ShortcutAction.prevPage => const KeyBinding(
      LogicalKeyboardKey.space,
      shift: true,
    ),
    ShortcutAction.nextChapter => const KeyBinding(
      LogicalKeyboardKey.bracketRight,
    ),
    ShortcutAction.prevChapter => const KeyBinding(
      LogicalKeyboardKey.bracketLeft,
    ),
    ShortcutAction.toggleReaderMenu => const KeyBinding(
      LogicalKeyboardKey.enter,
    ),
    // A system-wide hotkey takes the combination away from every other
    // program, so it stays off until the user picks one.
    ShortcutAction.toggleWindow ||
    ShortcutAction.toggleAutoPageTurning ||
    ShortcutAction.toggleNightMode ||
    ShortcutAction.collectImage => null,
  };

  static Map _stored() {
    final value = appdata.settings[_settingKey];
    return value is Map ? value : const {};
  }

  static KeyBinding? bindingOf(ShortcutAction action) {
    final stored = _stored()[action.name];
    if (stored is! String) return defaultBinding(action);
    if (stored.isEmpty) return null;
    return KeyBinding.decode(stored) ?? defaultBinding(action);
  }

  static bool isCustomized(ShortcutAction action) =>
      _stored().containsKey(action.name);

  /// Null unbinds. Re-sync [GlobalHotkeys] after changing a global binding.
  static void setBinding(ShortcutAction action, KeyBinding? binding) {
    final overrides = Map<String, dynamic>.from(_stored());
    if (binding == defaultBinding(action)) {
      overrides.remove(action.name);
    } else {
      overrides[action.name] = binding?.encode() ?? '';
    }
    appdata.settings[_settingKey] = overrides;
    appdata.saveData(false);
  }

  static void resetAll() {
    appdata.settings[_settingKey] = <String, dynamic>{};
    appdata.saveData(false);
  }

  /// Every binding shares one namespace: a global hotkey swallows the key
  /// before the window sees it, and app shortcuts also fire in the reader.
  static ShortcutAction? conflictOf(
    KeyBinding binding, {
    ShortcutAction? except,
  }) {
    for (final action in ShortcutAction.values) {
      if (action == except || !action.isAvailable) continue;
      if (bindingOf(action) == binding) return action;
    }
    return null;
  }

  /// Why [binding] can't be used for [action], as an English source string to
  /// translate, or null when it's fine. Conflicts are checked separately.
  static String? validate(ShortcutAction action, KeyBinding binding) {
    final key = binding.key;
    // Esc backs out of pages and dialogs, Tab moves focus, Alt+F4 closes the
    // window; none of them may be taken over.
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.tab ||
        (binding.alt && key == LogicalKeyboardKey.f4) ||
        _isReservedCombination(binding)) {
      return "This shortcut is reserved";
    }
    if (action.scope == ShortcutScope.global) {
      if (!binding.hasCommandModifier && !binding.isFunctionKey) {
        return "A global shortcut needs Ctrl, Alt or Win, or a function key";
      }
      if (windowsVirtualKey(key) == null) {
        return "This key can't be used as a global shortcut";
      }
    }
    return null;
  }

  // Undo, redo, cut, copy, paste and select all. The app-scope handler can't
  // keep these from a text field, so a binding would fire alongside them.
  static final _editingKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyA,
    LogicalKeyboardKey.keyC,
    LogicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyX,
    LogicalKeyboardKey.keyZ,
    LogicalKeyboardKey.keyY,
  };

  // macOS quit, close window, hide and minimize.
  static final _macAppKeys = <LogicalKeyboardKey>{
    LogicalKeyboardKey.keyQ,
    LogicalKeyboardKey.keyW,
    LogicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyM,
  };

  static bool _isReservedCombination(KeyBinding b) {
    // Ctrl on Windows / Linux, Cmd on macOS, with or without Shift (redo,
    // plain-text paste).
    final primary = App.isMacOS ? b.meta : b.control;
    final other = App.isMacOS ? b.control : b.meta;
    if (primary && !other && !b.alt && _editingKeys.contains(b.key)) {
      return true;
    }
    return App.isMacOS &&
        b.meta &&
        !b.control &&
        !b.alt &&
        !b.shift &&
        _macAppKeys.contains(b.key);
  }

  /// The action bound to [event] among [scopes]. While a text field has
  /// focus only bindings that can't be typed fire, so Space or a letter
  /// still reaches the field.
  static ShortcutAction? match(KeyEvent event, Set<ShortcutScope> scopes) {
    if (suspended || KeyBinding.modifierKeys.contains(event.logicalKey)) {
      return null;
    }
    final pressed = KeyBinding.fromEvent(event);
    for (final action in ShortcutAction.values) {
      if (!scopes.contains(action.scope) || !action.isAvailable) continue;
      if (bindingOf(action) != pressed) continue;
      if (!pressed.hasCommandModifier &&
          !pressed.isFunctionKey &&
          _isEditingText()) {
        return null;
      }
      return action;
    }
    return null;
  }

  static bool _isEditingText() {
    final focus = FocusManager.instance.primaryFocus?.context;
    return focus?.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// [text] followed by the action's key, for tooltips and menu entries.
  static String hint(String text, ShortcutAction action) {
    if (!App.isDesktop) return text;
    final binding = bindingOf(action);
    return binding == null ? text : '$text (${binding.label})';
  }

  static bool _installed = false;

  /// App-scope shortcuts. Goes through [HardwareKeyboard] rather than the
  /// focus tree, so it works whatever has focus, and runs once per process.
  static void install() {
    if (!App.isDesktop || _installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_handleAppKey);
  }

  static bool _handleAppKey(KeyEvent event) {
    if (event is KeyUpEvent) return false;
    final action = match(event, const {ShortcutScope.app});
    if (action == null) return false;
    if (event is KeyDownEvent && action == ShortcutAction.toggleFullscreen) {
      WindowFullscreen.toggle();
    }
    return true;
  }
}

/// System-wide hotkeys via RegisterHotKey in the Windows runner
/// (`venera/hotkey`). They reach the app while the window is hidden in the
/// tray, which no in-window key handler can.
class GlobalHotkeys {
  GlobalHotkeys._();

  static const _channel = MethodChannel('venera/hotkey');

  static bool _handlerSet = false;

  static bool _paused = false;

  static Future<void> _queue = Future.value();

  static final _registered = <int>{};

  /// Actions whose hotkey the system refused, usually because another
  /// program already owns the combination.
  static final failed = <ShortcutAction>{};

  /// Brings the system registrations in line with the current bindings.
  static Future<void> sync() {
    if (!App.isWindows) return Future.value();
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler(_onCall);
    }
    return _queue = _queue.then((_) => _sync()).catchError((Object e) {
      Log.error("Hotkey", "Failed to sync global hotkeys: $e");
    });
  }

  static Future<void> _sync() async {
    for (final id in _registered.toList()) {
      await _channel.invokeMethod('unregister', {'id': id});
      _registered.remove(id);
    }
    failed.clear();
    if (_paused) return;
    for (final action in ShortcutAction.values) {
      if (action.scope != ShortcutScope.global || !action.isAvailable) continue;
      final binding = AppShortcuts.bindingOf(action);
      if (binding == null) continue;
      final vk = windowsVirtualKey(binding.key);
      if (vk == null) {
        failed.add(action);
        continue;
      }
      final ok = await _channel.invokeMethod<bool>('register', {
        'id': _idOf(action),
        'modifiers': _modifiers(binding),
        'vk': vk,
      });
      if (ok == true) {
        _registered.add(_idOf(action));
      } else {
        failed.add(action);
        Log.warning("Hotkey", "${binding.label} is taken by another program");
      }
    }
  }

  // RegisterHotKey ids must be positive.
  static int _idOf(ShortcutAction action) => action.index + 1;

  static int _modifiers(KeyBinding binding) =>
      (binding.alt ? 0x1 : 0) |
      (binding.control ? 0x2 : 0) |
      (binding.shift ? 0x4 : 0) |
      (binding.meta ? 0x8 : 0);

  /// Releases every hotkey while the editor records one, so pressing the
  /// current combination there doesn't hide the window.
  static Future<void> pause() {
    _paused = true;
    return sync();
  }

  static Future<void> resume() {
    _paused = false;
    return sync();
  }

  static Future<void> _onCall(MethodCall call) async {
    if (call.method != 'onHotkey') return;
    final id = call.arguments as int;
    if (id < 1 || id > ShortcutAction.values.length) return;
    if (ShortcutAction.values[id - 1] == ShortcutAction.toggleWindow) {
      await TrayController.instance.toggleWindow();
    }
  }
}

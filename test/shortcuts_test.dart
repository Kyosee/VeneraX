import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/shortcuts.dart';

const _desktop = {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
};

void _setOverrides(Map<String, dynamic> overrides) {
  appdata.settings['keyboardShortcuts'] = overrides;
}

void main() {
  tearDown(() {
    _setOverrides({});
    AppShortcuts.suspended = false;
  });

  test('a binding survives encode and decode', () {
    const binding = KeyBinding(
      LogicalKeyboardKey.keyH,
      control: true,
      alt: true,
      meta: true,
    );
    expect(KeyBinding.decode(binding.encode()), binding);
    const plain = KeyBinding(LogicalKeyboardKey.f11);
    expect(KeyBinding.decode(plain.encode()), plain);
  });

  test('decode rejects empty and malformed values', () {
    expect(KeyBinding.decode(null), isNull);
    expect(KeyBinding.decode(''), isNull);
    expect(KeyBinding.decode('ctrl+'), isNull);
    expect(KeyBinding.decode('hyper+97'), isNull);
  });

  test('windows virtual keys cover letters, digits and named keys', () {
    expect(windowsVirtualKey(LogicalKeyboardKey.keyA), 0x41);
    expect(windowsVirtualKey(LogicalKeyboardKey.keyZ), 0x5A);
    expect(windowsVirtualKey(LogicalKeyboardKey.digit0), 0x30);
    expect(windowsVirtualKey(LogicalKeyboardKey.f1), 0x70);
    expect(windowsVirtualKey(LogicalKeyboardKey.f12), 0x7B);
    expect(windowsVirtualKey(LogicalKeyboardKey.space), 0x20);
    expect(windowsVirtualKey(LogicalKeyboardKey.bracketLeft), 0xDB);
    expect(windowsVirtualKey(LogicalKeyboardKey.mediaPlay), isNull);
  });

  test('default bindings never collide on any desktop platform', () {
    for (final platform in _desktop) {
      _onPlatform(platform, () {
        final seen = <KeyBinding, ShortcutAction>{};
        for (final action in ShortcutAction.values) {
          if (!action.isAvailable) continue;
          final binding = AppShortcuts.bindingOf(action);
          if (binding == null) continue;
          expect(
            seen[binding],
            isNull,
            reason: '$platform: ${action.name} vs ${seen[binding]?.name}',
          );
          seen[binding] = action;
          expect(AppShortcuts.validate(action, binding), isNull);
        }
      });
    }
  });

  test('overrides replace, unbind, or fall back to the default', () {
    _onPlatform(TargetPlatform.windows, () {
      const custom = KeyBinding(LogicalKeyboardKey.keyF, control: true);
      _setOverrides({
        'toggleFullscreen': custom.encode(),
        'nextPage': '',
        'prevPage': 'garbage',
      });
      expect(AppShortcuts.bindingOf(ShortcutAction.toggleFullscreen), custom);
      expect(AppShortcuts.bindingOf(ShortcutAction.nextPage), isNull);
      expect(
        AppShortcuts.bindingOf(ShortcutAction.prevPage),
        AppShortcuts.defaultBinding(ShortcutAction.prevPage),
      );
      expect(AppShortcuts.isCustomized(ShortcutAction.nextPage), isTrue);
      expect(AppShortcuts.isCustomized(ShortcutAction.nextChapter), isFalse);
    });
  });

  test('conflicts are found across scopes and skip the edited action', () {
    _onPlatform(TargetPlatform.windows, () {
      const f11 = KeyBinding(LogicalKeyboardKey.f11);
      expect(AppShortcuts.conflictOf(f11), ShortcutAction.toggleFullscreen);
      expect(
        AppShortcuts.conflictOf(f11, except: ShortcutAction.toggleFullscreen),
        isNull,
      );
      // An unbound action frees its key for others.
      _setOverrides({'toggleFullscreen': ''});
      expect(AppShortcuts.conflictOf(f11), isNull);
    });
  });

  test('validation guards reserved keys and global hotkeys', () {
    _onPlatform(TargetPlatform.windows, () {
      const fullscreen = ShortcutAction.toggleFullscreen;
      const window = ShortcutAction.toggleWindow;
      expect(
        AppShortcuts.validate(
          fullscreen,
          const KeyBinding(LogicalKeyboardKey.escape),
        ),
        isNotNull,
      );
      expect(
        AppShortcuts.validate(
          fullscreen,
          const KeyBinding(LogicalKeyboardKey.f4, alt: true),
        ),
        isNotNull,
      );
      // Text editing keeps its combinations.
      expect(
        AppShortcuts.validate(
          fullscreen,
          const KeyBinding(LogicalKeyboardKey.keyC, control: true),
        ),
        isNotNull,
      );
      expect(
        AppShortcuts.validate(
          fullscreen,
          const KeyBinding(LogicalKeyboardKey.keyZ, control: true, shift: true),
        ),
        isNotNull,
      );
      expect(
        AppShortcuts.validate(
          fullscreen,
          const KeyBinding(LogicalKeyboardKey.keyC, control: true, alt: true),
        ),
        isNull,
      );
      // Cmd+Q only quits on macOS.
      expect(
        AppShortcuts.validate(
          fullscreen,
          const KeyBinding(LogicalKeyboardKey.keyQ, control: true),
        ),
        isNull,
      );
      // Taking a bare letter system-wide would break typing everywhere.
      expect(
        AppShortcuts.validate(
          window,
          const KeyBinding(LogicalKeyboardKey.keyH),
        ),
        isNotNull,
      );
      expect(
        AppShortcuts.validate(
          window,
          const KeyBinding(LogicalKeyboardKey.keyH, shift: true),
        ),
        isNotNull,
      );
      expect(
        AppShortcuts.validate(
          window,
          const KeyBinding(LogicalKeyboardKey.keyH, control: true, alt: true),
        ),
        isNull,
      );
      expect(
        AppShortcuts.validate(window, const KeyBinding(LogicalKeyboardKey.f9)),
        isNull,
      );
      expect(
        AppShortcuts.validate(
          window,
          const KeyBinding(LogicalKeyboardKey.mediaPlay, control: true),
        ),
        isNotNull,
      );
    });
  });

  test('macOS reserves Cmd editing and app combinations', () {
    _onPlatform(TargetPlatform.macOS, () {
      const action = ShortcutAction.toggleFullscreen;
      for (final key in [
        LogicalKeyboardKey.keyV,
        LogicalKeyboardKey.keyQ,
        LogicalKeyboardKey.keyW,
        LogicalKeyboardKey.keyH,
        LogicalKeyboardKey.keyM,
      ]) {
        expect(
          AppShortcuts.validate(action, KeyBinding(key, meta: true)),
          isNotNull,
          reason: key.keyLabel,
        );
      }
      // Ctrl is not the editing modifier there.
      expect(
        AppShortcuts.validate(
          action,
          const KeyBinding(LogicalKeyboardKey.keyC, control: true),
        ),
        isNull,
      );
      // Ctrl+Cmd+F, the default, stays usable.
      expect(
        AppShortcuts.validate(action, AppShortcuts.defaultBinding(action)!),
        isNull,
      );
    });
  });

  test('labels follow the platform', () {
    const binding = KeyBinding(
      LogicalKeyboardKey.keyF,
      control: true,
      shift: true,
    );
    _onPlatform(TargetPlatform.windows, () {
      expect(binding.label, 'Ctrl + Shift + F');
      expect(const KeyBinding(LogicalKeyboardKey.space).label, 'Space');
    });
    _onPlatform(TargetPlatform.macOS, () {
      expect(binding.label, '⌃⇧F');
    });
  });

  test('the global hotkey is Windows only and unbound by default', () {
    _onPlatform(TargetPlatform.linux, () {
      expect(ShortcutAction.toggleWindow.isAvailable, isFalse);
    });
    _onPlatform(TargetPlatform.windows, () {
      expect(ShortcutAction.toggleWindow.isAvailable, isTrue);
      expect(AppShortcuts.bindingOf(ShortcutAction.toggleWindow), isNull);
    });
  });

  group('matching key events', () {
    final matched = <ShortcutAction?>[];
    bool record(KeyEvent event) {
      if (event is KeyDownEvent) {
        matched.add(
          AppShortcuts.match(event, const {
            ShortcutScope.app,
            ShortcutScope.reader,
          }),
        );
      }
      return false;
    }

    setUp(() {
      matched.clear();
      HardwareKeyboard.instance.addHandler(record);
    });
    tearDown(() => HardwareKeyboard.instance.removeHandler(record));

    testWidgets(
      'modifiers pick the action',
      (tester) async {
        await tester.pumpWidget(
          const Focus(autofocus: true, child: SizedBox()),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
        expect(matched, [
          ShortcutAction.nextPage,
          null, // the Shift key itself
          ShortcutAction.prevPage,
          null,
        ]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'a focused text field keeps typed keys',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(home: Material(child: TextField(autofocus: true))),
        );
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        expect(matched, [null, ShortcutAction.toggleFullscreen]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'nothing fires while the editor records',
      (tester) async {
        await tester.pumpWidget(
          const Focus(autofocus: true, child: SizedBox()),
        );
        AppShortcuts.suspended = true;
        await tester.sendKeyEvent(LogicalKeyboardKey.f11);
        expect(matched, [null]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });
}

void _onPlatform(TargetPlatform platform, void Function() body) {
  debugDefaultTargetPlatformOverride = platform;
  try {
    body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

// The app's patch binding surface, pinned to its dispatch table.
//
// Two halves that must agree: `AppPatchSurface` names members for the compiler,
// `AppPatchBindings` answers them at run time. They live in separate files —
// the tool reads the tables under plain `dart run`, which cannot import `Log`
// without crashing kernel compilation in the FFI transformer — so nothing but
// this test keeps them in step.
//
// The dangerous direction is a bound id that the surface does not name: the
// compiler then reports a working API as unreachable, and the patch author goes
// off to add a binding that already exists. The other direction fails loudly on
// the first call, so it needs less guarding.

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/patch_bindings.dart';
import 'package:venera_patch/venera_patch.dart';

void main() {
  const bridge = AppPatchBindings();

  group('every surface entry resolves to a real binding', () {
    test('members', () {
      final unbound = <String>[];
      AppPatchSurface.members.forEach((key, id) {
        if (!bridge.isBound(id)) unbound.add('$key = 0x${id.toRadixString(16)}');
      });
      expect(
        unbound,
        isEmpty,
        reason: 'the surface advertises these but the bridge does not answer '
            'them, so a patch calling one fails on the device rather than in '
            'the compiler:\n${unbound.join('\n')}',
      );
    });

    test('every advertised member actually dispatches', () {
      // `isBound` is a range check, so it says yes to ids the switch has no case
      // for. Calling each one is what proves the case exists — an id inside the
      // range but absent from the switch would pass `isBound` and then throw
      // mid-patch.
      final missing = <String>[];
      AppPatchSurface.members.forEach((key, id) {
        try {
          bridge.invoke(id, null, const ['probe', 'from patch_bindings_test'],
              null);
        } on UnboundMemberFault {
          missing.add('$key = 0x${id.toRadixString(16)}');
        } catch (_) {
          // Any other error means the case exists and ran; that is all this
          // assertion is about.
        }
      });
      expect(
        missing,
        isEmpty,
        reason: 'inside the bound range but absent from the switch:\n'
            '${missing.join('\n')}',
      );
    });
  });

  group('every binding is nameable from patch source', () {
    test('no declared id is missing from the surface', () {
      // The reverse check, and the one that matters more. An id bound but not
      // named is invisible to the compiler: `Log.info(...)` would be rejected as
      // unreachable even though the binary answers it.
      const declared = {
        'logInfo': AppPatchIds.logInfo,
        'logWarning': AppPatchIds.logWarning,
        'logError': AppPatchIds.logError,
      };
      final exposed = AppPatchSurface.members.values.toSet();
      final missing = <String>[];
      declared.forEach((name, id) {
        if (!exposed.contains(id)) {
          missing.add('$name = 0x${id.toRadixString(16)}');
        }
      });
      expect(
        missing,
        isEmpty,
        reason: 'bound but unnameable — the compiler will call these '
            'unreachable even though they work:\n${missing.join('\n')}',
      );
    });
  });

  group('ids stay in their range', () {
    test('app ids never collide with core ids', () {
      // Core owns 0x0100..0x10FF, the app starts at 0x2000. An overlap would be
      // resolved by whichever bridge `LayeredHostBridge` asked first, which is
      // not a property to leave to ordering.
      const core = CoreBindings();
      for (final entry in AppPatchSurface.members.entries) {
        expect(
          core.isBound(entry.value),
          isFalse,
          reason: '${entry.key} = 0x${entry.value.toRadixString(16)} is also a '
              'core id',
        );
      }
    });

    test('no two surface keys share an id', () {
      final byId = <int, String>{};
      final clashes = <String>[];
      AppPatchSurface.members.forEach((key, id) {
        final prior = byId[id];
        if (prior != null) {
          clashes.add('0x${id.toRadixString(16)}: $prior and $key');
        }
        byId[id] = key;
      });
      expect(clashes, isEmpty, reason: clashes.join('\n'));
    });

    test('keys are Receiver.member or a bare top-level name', () {
      // The compiler builds its lookup key from the receiver's static type, so a
      // malformed key here is simply a member no patch can ever name.
      final malformed = <String>[];
      for (final key in AppPatchSurface.members.keys) {
        final parts = key.split('.');
        if (parts.length > 2 || parts.any((p) => p.isEmpty)) {
          malformed.add(key);
        }
      }
      expect(malformed, isEmpty, reason: malformed.join('\n'));
    });
  });

  group('the layered bridge reaches both halves', () {
    test('a core id and an app id both resolve through one bridge', () {
      // This is the composition `hot_update.dart` installs. If it were wrong, a
      // patch would reach exactly one of the two surfaces — and which one would
      // depend on the id it happened to call first.
      const layered = LayeredHostBridge(AppPatchBindings());

      expect(layered.isBound(CoreIds.stringLength), isTrue);
      expect(layered.isBound(AppPatchIds.logInfo), isTrue);
      expect(layered.isBound(0xFFFF), isFalse);

      expect(layered.invoke(CoreIds.stringLength, 'abcd', const [], null), 4);
    });

    test('an app member runs through the layered bridge', () {
      const layered = LayeredHostBridge(AppPatchBindings());
      // Reaching the real Log is the point: a patch's log line has to land in
      // the same place a bug reporter looks.
      expect(
        () => layered.invoke(
          AppPatchIds.logInfo,
          null,
          const ['Patch', 'layered dispatch reached the app surface'],
          null,
        ),
        returnsNormally,
      );
    });
  });

  group('the surface is deliberately narrow', () {
    test('nothing but logging is bound yet', () {
      // A reminder, not a restriction. Every id added here widens what a signed
      // payload can do, and the dispatch table is the whole sandbox boundary —
      // there is no second check behind it. Growth should be a decision, not a
      // drift, so this pins the current set.
      expect(
        AppPatchSurface.members.keys.toList(),
        ['Log.info', 'Log.warning', 'Log.error'],
        reason: 'App surface changed. Confirm each new member is worth what a '
            'patch can do with it, then update this list.',
      );
      expect(
        AppPatchSurface.types,
        isEmpty,
        reason: 'app types need stage 4 user-class support to be useful: a '
            'patch cannot construct one, so `is`/`as` against it can only ever '
            'be false.',
      );
    });
  });
}

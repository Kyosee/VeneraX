import 'package:flutter_test/flutter_test.dart';
import 'package:venera_patch/venera_patch.dart';

PatchSlotEntry _entry(int v, {String track = 'stable'}) => PatchSlotEntry(
  patchVersion: v,
  track: track,
  dirName: 'p$v',
  sha256: 'deadbeef',
);

void main() {
  group('dual-slot promotion', () {
    test('a staged patch is pending before it is proven', () {
      final s = PatchSlots();
      expect(s.stage(_entry(10)), isNull);
      expect(s.pending?.patchVersion, 10);
      expect(s.current, isNull);
    });

    test('a successful launch promotes next and retires the old current', () {
      final s = PatchSlots(current: _entry(9));
      s.stage(_entry(10));
      final retired = s.markLaunchSucceeded();
      expect(retired?.patchVersion, 9, reason: 'old current must be returned '
          'for deletion — leaving it on disk grows unboundedly');
      expect(s.current?.patchVersion, 10);
      expect(s.next, isNull);
      expect(s.bootMarker, 0);
    });

    test('staging twice displaces the unproven entry, never the proven one', () {
      final s = PatchSlots(current: _entry(9));
      s.stage(_entry(10));
      final displaced = s.stage(_entry(11));
      expect(displaced?.patchVersion, 10);
      expect(s.current?.patchVersion, 9, reason: 'the proven patch must '
          'survive: it is the rollback target');
    });
  });

  group('self-healing', () {
    test('one failed launch is tolerated', () {
      final s = PatchSlots();
      s.stage(_entry(10));
      s.markLaunchStarted();
      expect(s.shouldRollBack, isFalse,
          reason: 'a single boot failure can be an unrelated OOM kill');
    });

    test('two failed launches trigger rollback and ban the version', () {
      final s = PatchSlots(current: _entry(9));
      s.stage(_entry(10));
      s.markLaunchStarted();
      s.markLaunchStarted();
      expect(s.shouldRollBack, isTrue);

      final bad = s.rollBack();
      expect(bad?.patchVersion, 10);
      expect(s.next, isNull);
      expect(s.current?.patchVersion, 9,
          reason: 'rollback must fall back to the last proven patch');
      expect(s.isDisabled(10), isTrue,
          reason: 'without a ban the next check re-downloads and re-crashes — '
              'the download/crash loop');
      expect(s.bootMarker, 0);
    });

    test('rollback with no proven patch falls back to built-in', () {
      final s = PatchSlots();
      s.stage(_entry(10));
      s.markLaunchStarted();
      s.markLaunchStarted();
      s.rollBack();
      expect(s.pending, isNull, reason: 'nothing left to load: the built-in '
          'implementation takes over');
      expect(s.isDisabled(10), isTrue);
    });

    test('a proven patch that later starts failing is also rolled back', () {
      final s = PatchSlots(current: _entry(9));
      s.markLaunchStarted();
      s.markLaunchStarted();
      expect(s.shouldRollBack, isTrue);
      final bad = s.rollBack();
      expect(bad?.patchVersion, 9);
      expect(s.current, isNull);
    });
  });

  group('version floor', () {
    test('highestVersion spans both slots', () {
      expect(PatchSlots().highestVersion, 0);
      expect(PatchSlots(current: _entry(9)).highestVersion, 9);
      final s = PatchSlots(current: _entry(9));
      s.stage(_entry(11));
      expect(s.highestVersion, 11);
    });
  });

  group('persistence', () {
    test('round-trips through JSON', () {
      final s = PatchSlots(current: _entry(9), bootMarker: 1);
      s.stage(_entry(10, track: 'beta'));
      s.disabledVersions = {7, 8};

      final back = PatchSlots.fromJson(s.toJson());
      expect(back.current?.patchVersion, 9);
      expect(back.next?.patchVersion, 10);
      expect(back.next?.track, 'beta');
      expect(back.bootMarker, 1);
      expect(back.disabledVersions, {7, 8});
    });

    test('corrupt state degrades to "nothing installed", never throws', () {
      // A corrupt state file must not brick patching on every launch.
      expect(PatchSlots.fromJson('{not json').pending, isNull);
      expect(PatchSlots.fromJson(null).pending, isNull);
      expect(PatchSlots.fromJson(42).pending, isNull);
      expect(PatchSlots.fromJson({'current': 'garbage'}).current, isNull);
    });

    test('an entry without dirName is dropped', () {
      // dirName is what locates the files; an entry without one would make the
      // loader point at the patch root itself.
      expect(PatchSlotEntry.fromJson({'patchVersion': 5}), isNull);
      expect(PatchSlotEntry.fromJson({'dirName': ''}), isNull);
    });
  });
}

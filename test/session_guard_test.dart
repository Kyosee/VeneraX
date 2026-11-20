import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/boot_time.dart';
import 'package:venera/foundation/session_guard.dart';

/// A crash has to be told apart from everything that ends a process without
/// one: the system reclaiming a backgrounded app, the user swiping it away or
/// ending its task, the device losing power, an update replacing it.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('session-guard-');
  });

  tearDown(() {
    SessionGuard.reset();
    dir.deleteSync(recursive: true);
  });

  Future<void> launch({String version = '1.0.0', int? boot = 1000}) =>
      SessionGuard.start(
        directory: dir,
        version: version,
        bootTime: () => boot,
        observeLifecycle: false,
      );

  /// Ends the run the way a killed process does: nothing more gets written.
  void kill() => SessionGuard.reset();

  void settle() {
    SessionGuard.current!.settled = true;
    SessionGuard.step('settled');
  }

  SessionRecord record({
    String presence = SessionRecord.front,
    bool settled = true,
    bool clean = false,
    bool recovery = false,
    int? bootAt = 1000,
  }) => SessionRecord(
    id: 1,
    version: '1.0.0',
    bootAt: bootAt,
    presence: presence,
    settled: settled,
    clean: clean,
    recovery: recovery,
  );

  PreviousExit classify(
    SessionRecord? prev, {
    String version = '1.0.0',
    int? bootAt = 1000,
  }) => SessionGuard.classify(prev, version: version, bootAt: bootAt);

  group('how the previous run ended', () {
    test('nothing on record says nothing', () {
      expect(classify(null), PreviousExit.unknown);
    });

    test('ending while in use is a suspected crash', () {
      expect(classify(record()), PreviousExit.suspectedCrash);
    });

    test('ending off screen is not: the system or the user closed it', () {
      expect(
        classify(record(presence: SessionRecord.away)),
        PreviousExit.background,
      );
    });

    test('the app closing itself is not', () {
      expect(classify(record(clean: true)), PreviousExit.clean);
    });

    test('a device that booted since explains it: power loss, shutdown', () {
      expect(
        classify(record(), bootAt: 1000 + 10 * 60 * 1000),
        PreviousExit.deviceRestarted,
      );
    });

    test('a clock correction does not read as a reboot', () {
      expect(
        classify(record(), bootAt: 1000 + 30 * 1000),
        PreviousExit.suspectedCrash,
      );
    });

    test('an unknown boot time leaves the verdict to what else is known', () {
      expect(classify(record(), bootAt: null), PreviousExit.suspectedCrash);
      expect(
        classify(record(bootAt: null), bootAt: 99999999),
        PreviousExit.suspectedCrash,
      );
    });

    test('a record from another version is out of date', () {
      expect(classify(record(), version: '1.0.1'), PreviousExit.appUpdated);
      // Even across a reboot: the new build still gets a clean slate.
      expect(
        classify(record(), version: '1.0.1', bootAt: 99999999),
        PreviousExit.appUpdated,
      );
    });

    test('dying before ever reaching the screen is a failed launch', () {
      expect(
        classify(record(presence: SessionRecord.unknown, settled: false)),
        PreviousExit.suspectedCrash,
      );
    });

    test('a long run that never came to the front is not', () {
      expect(
        classify(record(presence: SessionRecord.unknown)),
        PreviousExit.background,
      );
    });

    test('nothing can crash on the recovery page', () {
      expect(classify(record(recovery: true)), PreviousExit.background);
    });
  });

  group('where the system says how the process ended', () {
    PreviousExit withReason(SessionRecord prev, int reason) =>
        SessionGuard.classify(
          prev,
          version: '1.0.0',
          bootAt: 1000,
          osReason: reason,
        );

    test('a crash or a freeze is one even off screen', () {
      for (final reason in [1, 3, 4, 5]) {
        expect(
          withReason(record(presence: SessionRecord.away), reason),
          PreviousExit.suspectedCrash,
          reason: '$reason',
        );
      }
    });

    test('an app the user ended, or a normal exit, is none even in use', () {
      for (final reason in [2, 8, 9]) {
        expect(
          withReason(record(), reason),
          PreviousExit.background,
          reason: '$reason',
        );
      }
    });

    test('a reclaimed app is judged by whether it was in use', () {
      for (final reason in [0, 6, 7, 10, 99]) {
        expect(
          withReason(record(), reason),
          PreviousExit.suspectedCrash,
          reason: '$reason',
        );
        expect(
          withReason(record(presence: SessionRecord.away), reason),
          PreviousExit.background,
          reason: '$reason',
        );
      }
    });

    test('closing itself and an update still come first', () {
      expect(withReason(record(clean: true), 3), PreviousExit.clean);
      expect(
        SessionGuard.classify(
          record(),
          version: '1.0.1',
          bootAt: 1000,
          osReason: 3,
        ),
        PreviousExit.appUpdated,
      );
    });

    test('a crash off screen is reported and counts as an early failure', () async {
      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      SessionGuard.onLifecycle(AppLifecycleState.paused);
      kill();

      await SessionGuard.start(
        directory: dir,
        version: '1.0.0',
        bootTime: () => 1000,
        osExit: () async => (reason: 3, message: 'Signal:SIGSEGV'),
        observeLifecycle: false,
      );
      expect(SessionGuard.previousExit, PreviousExit.suspectedCrash);
      expect(SessionGuard.previousOsExit?.reason, 3);
      expect(SessionGuard.current!.earlyFailures, 1);
      expect(SessionGuard.takePendingReport(), isNotNull);
    });

    test('ending the task while reading is not reported', () async {
      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      kill();

      await SessionGuard.start(
        directory: dir,
        version: '1.0.0',
        bootTime: () => 1000,
        osExit: () async => (reason: 9, message: ''),
        observeLifecycle: false,
      );
      expect(SessionGuard.previousExit, PreviousExit.background);
      expect(SessionGuard.takePendingReport(), isNull);
    });
  });

  group('whether the user is looking at the app', () {
    String presence(
      AppLifecycleState? state, {
      bool everFront = true,
      bool desktop = false,
    }) => SessionGuard.presenceOf(state, everFront: everFront, desktop: desktop);

    test('only a resumed app is in front', () {
      expect(presence(AppLifecycleState.resumed), SessionRecord.front);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        expect(presence(state), SessionRecord.away, reason: '$state');
        expect(presence(state, desktop: true), SessionRecord.away);
      }
    });

    test('a launching app has not been left yet', () {
      for (final state in [
        null,
        AppLifecycleState.inactive,
        AppLifecycleState.detached,
      ]) {
        expect(
          presence(state, everFront: false),
          SessionRecord.unknown,
          reason: '$state',
        );
      }
      // A desktop window is hidden until it is ready to show.
      expect(
        presence(AppLifecycleState.hidden, everFront: false, desktop: true),
        SessionRecord.unknown,
      );
    });

    test('a phone app sent away while launching was left', () {
      expect(
        presence(AppLifecycleState.hidden, everFront: false),
        SessionRecord.away,
      );
      expect(
        presence(AppLifecycleState.paused, everFront: false),
        SessionRecord.away,
      );
    });
  });

  group('across launches', () {
    test('a first launch knows nothing and starts a record', () async {
      await launch();
      expect(SessionGuard.previousExit, PreviousExit.unknown);
      expect(SessionGuard.offerRecovery, isFalse);
      final saved = SessionRecord.tryRead(File('${dir.path}/session.json'))!;
      expect(saved.version, '1.0.0');
      expect(saved.steps.single.name, 'launch');
    });

    test('a crash in use is reported once on the next launch', () async {
      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      final crashed = SessionGuard.current!.id;
      kill();

      await launch();
      expect(SessionGuard.previousExit, PreviousExit.suspectedCrash);
      expect(SessionGuard.previous!.id, crashed);
      expect(SessionGuard.takePendingReport(), '$crashed');
      expect(SessionGuard.takePendingReport(), isNull);
    });

    test('a report nobody saw yet survives another launch', () async {
      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      final crashed = SessionGuard.current!.id;
      kill();

      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      SessionGuard.onLifecycle(AppLifecycleState.paused);
      kill();

      await launch();
      expect(SessionGuard.previousExit, PreviousExit.background);
      expect(SessionGuard.takePendingReport(), '$crashed');
    });

    test('swiping the app away is not reported', () async {
      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      SessionGuard.onLifecycle(AppLifecycleState.inactive);
      SessionGuard.onLifecycle(AppLifecycleState.paused);
      kill();

      await launch();
      expect(SessionGuard.previousExit, PreviousExit.background);
      expect(SessionGuard.takePendingReport(), isNull);
    });

    test('losing power while reading is not reported', () async {
      await launch(boot: 1000);
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      kill();

      await launch(boot: 1000 + 3600 * 1000);
      expect(SessionGuard.previousExit, PreviousExit.deviceRestarted);
      expect(SessionGuard.takePendingReport(), isNull);
    });

    test('closing the app itself is not reported', () async {
      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      SessionGuard.markCleanExit();
      kill();

      await launch();
      expect(SessionGuard.previousExit, PreviousExit.clean);
    });

    test('an exit that did not happen is forgotten', () async {
      await launch();
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      SessionGuard.markCleanExit();
      SessionGuard.step('still here');
      kill();

      await launch();
      expect(SessionGuard.previousExit, PreviousExit.suspectedCrash);
    });

    test('a file cut short reads as nothing known', () async {
      File('${dir.path}/session.json').writeAsStringSync('{"id": 1, "vers');
      await launch();
      expect(SessionGuard.previousExit, PreviousExit.unknown);
      expect(SessionGuard.current, isNotNull);
    });

    test('recovery is offered after two early failures in a row', () async {
      await launch();
      kill();

      await launch();
      expect(SessionGuard.previousExit, PreviousExit.suspectedCrash);
      expect(SessionGuard.offerRecovery, isFalse);
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      kill();

      await launch();
      expect(SessionGuard.offerRecovery, isTrue);
    });

    test('a crash after the first minute is not an early failure', () async {
      for (var i = 0; i < 3; i++) {
        await launch();
        SessionGuard.onLifecycle(AppLifecycleState.resumed);
        settle();
        kill();
      }
      await launch();
      expect(SessionGuard.previousExit, PreviousExit.suspectedCrash);
      expect(SessionGuard.offerRecovery, isFalse);
    });

    test('leaving during launch does not count towards recovery', () async {
      for (var i = 0; i < 3; i++) {
        await launch();
        SessionGuard.onLifecycle(AppLifecycleState.paused);
        kill();
      }
      await launch();
      expect(SessionGuard.offerRecovery, isFalse);
    });

    test('closing the recovery page brings it back next time', () async {
      await launch();
      kill();
      await launch();
      kill();
      await launch();
      expect(SessionGuard.offerRecovery, isTrue);
      SessionGuard.enterRecovery();
      kill();

      await launch();
      expect(SessionGuard.previousExit, PreviousExit.background);
      expect(SessionGuard.offerRecovery, isTrue);
    });

    test('after safe mode one more early failure is enough', () async {
      await launch();
      kill();
      await launch();
      kill();
      await launch();
      SessionGuard.enterRecovery();
      SessionGuard.leaveRecovery(safe: true);
      expect(SessionGuard.safeMode, isTrue);
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      settle();
      SessionGuard.onLifecycle(AppLifecycleState.paused);
      kill();

      // Back to an ordinary start, which fails again.
      await launch();
      expect(SessionGuard.offerRecovery, isFalse);
      expect(SessionGuard.safeMode, isFalse);
      kill();

      await launch();
      expect(SessionGuard.offerRecovery, isTrue);
    });

    test('an ordinary run that settles clears the suspicion', () async {
      await launch();
      kill();
      await launch();
      kill();
      await launch();
      SessionGuard.enterRecovery();
      SessionGuard.leaveRecovery(safe: false);
      SessionGuard.onLifecycle(AppLifecycleState.resumed);
      settle();
      SessionGuard.onLifecycle(AppLifecycleState.paused);
      kill();

      await launch();
      kill();
      await launch();
      expect(SessionGuard.offerRecovery, isFalse);
    });

    test('an update starts over', () async {
      await launch();
      kill();
      await launch();
      kill();

      await launch(version: '1.0.1');
      expect(SessionGuard.previousExit, PreviousExit.appUpdated);
      expect(SessionGuard.offerRecovery, isFalse);
      expect(SessionGuard.takePendingReport(), isNull);
    });

    test('a reboot in the middle keeps the count', () async {
      await launch(boot: 1000);
      kill();
      await launch(boot: 1000);
      kill();

      await launch(boot: 9000000);
      expect(SessionGuard.previousExit, PreviousExit.deviceRestarted);
      expect(SessionGuard.offerRecovery, isFalse);
      kill();

      await launch(boot: 9000000);
      expect(SessionGuard.offerRecovery, isTrue);
    });
  });

  group('what the run was doing', () {
    test('activities in progress and recent steps are on disk at once', () async {
      await launch();
      SessionGuard.begin('sync');
      SessionGuard.begin('reader');
      SessionGuard.end('sync');

      final saved = SessionRecord.tryRead(File('${dir.path}/session.json'))!;
      expect(saved.active, ['reader']);
      expect(saved.steps.map((step) => step.name), [
        'launch',
        'sync.start',
        'reader.start',
        'sync.end',
      ]);
    });

    test('overlapping instances of one activity count as one', () async {
      await launch();
      SessionGuard.begin('reader');
      SessionGuard.begin('reader');
      SessionGuard.end('reader');
      expect(SessionGuard.current!.active, ['reader']);
      SessionGuard.end('reader');
      // An end with nothing open, such as a repeated cleanup, is ignored.
      SessionGuard.end('reader');
      expect(SessionGuard.current!.active, isEmpty);
      expect(SessionGuard.current!.steps.map((step) => step.name), [
        'launch',
        'reader.start',
        'reader.end',
      ]);
    });

    test('only the latest steps are kept', () async {
      await launch();
      for (var i = 0; i < 100; i++) {
        SessionGuard.step('step $i');
      }
      final steps = SessionGuard.current!.steps;
      expect(steps, hasLength(40));
      expect(steps.last.name, 'step 99');
    });

    test('during() closes the activity when the work throws', () async {
      await launch();
      await expectLater(
        SessionGuard.during('import', () async => throw StateError('boom')),
        throwsStateError,
      );
      expect(SessionGuard.current!.active, isEmpty);
    });

    testWidgets('a run settles a minute after the app is up', (tester) async {
      await launch();
      SessionGuard.appStarted();
      await tester.pump(const Duration(seconds: 59));
      expect(SessionGuard.current!.settled, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(SessionGuard.current!.settled, isTrue);
      expect(
        SessionRecord.tryRead(File('${dir.path}/session.json'))!.settled,
        isTrue,
      );
    });

    test('nothing happens before start', () {
      SessionGuard.step('ignored');
      SessionGuard.begin('ignored');
      SessionGuard.markCleanExit();
      SessionGuard.appStarted();
      expect(SessionGuard.current, isNull);
      expect(SessionGuard.takePendingReport(), isNull);
    });
  });

  test('the boot time is a stable moment in the past', () {
    final first = bootTimeMillis();
    final second = bootTimeMillis();
    expect(first, isNotNull);
    expect(first! < DateTime.now().millisecondsSinceEpoch, isTrue);
    expect((second! - first).abs() < 2000, isTrue);
  });
}

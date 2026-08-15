import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/continuous_page_turn_coordinator.dart';

void main() {
  test('rapid requests never overlap scroll navigation', () async {
    final firstNavigation = Completer<void>();
    final navigated = <int>[];
    var activeNavigations = 0;
    var maxActiveNavigations = 0;
    final coordinator = ContinuousPageTurnCoordinator<int>(
      prepare: (_, _) async {},
      navigate: (target, _) async {
        activeNavigations++;
        maxActiveNavigations = activeNavigations > maxActiveNavigations
            ? activeNavigations
            : maxActiveNavigations;
        navigated.add(target);
        if (target == 2) await firstNavigation.future;
        activeNavigations--;
      },
    );

    final first = coordinator.request(2);
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.intendedTarget, 2);
    final second = coordinator.request(3);
    final third = coordinator.request(4);
    expect(coordinator.intendedTarget, 4);
    await Future<void>.delayed(Duration.zero);

    expect(maxActiveNavigations, 1);
    expect(navigated, [2]);

    firstNavigation.complete();
    await Future.wait([first, second, third]);

    expect(navigated, [2, 4]);
    expect(coordinator.intendedTarget, isNull);
  });

  test('target is prepared before navigation starts', () async {
    final prepared = Completer<void>();
    final events = <String>[];
    final coordinator = ContinuousPageTurnCoordinator<int>(
      prepare: (target, _) async {
        events.add('prepare:$target');
        await prepared.future;
      },
      navigate: (target, _) async => events.add('navigate:$target'),
    );

    final operation = coordinator.request(2);
    await Future<void>.delayed(Duration.zero);
    expect(events, ['prepare:2']);

    prepared.complete();
    await operation;
    expect(events, ['prepare:2', 'navigate:2']);
  });

  test('cancel during preparation prevents stale navigation', () async {
    final prepared = Completer<void>();
    final navigated = <int>[];
    final coordinator = ContinuousPageTurnCoordinator<int>(
      prepare: (_, _) => prepared.future,
      navigate: (target, _) async => navigated.add(target),
    );

    final operation = coordinator.request(2);
    await Future<void>.delayed(Duration.zero);
    coordinator.cancel();
    expect(coordinator.intendedTarget, isNull);
    prepared.complete();
    await operation;

    expect(navigated, isEmpty);
    expect(coordinator.intendedTarget, isNull);
  });

  test('navigation can stop when its request becomes stale', () async {
    final navigationStarted = Completer<void>();
    final releaseNavigation = Completer<void>();
    final navigated = <int>[];
    final coordinator = ContinuousPageTurnCoordinator<int>(
      prepare: (_, _) async {},
      navigate: (target, isCurrent) async {
        navigationStarted.complete();
        await releaseNavigation.future;
        if (isCurrent()) navigated.add(target);
      },
    );

    final operation = coordinator.request(2);
    await navigationStarted.future;
    coordinator.cancel();
    releaseNavigation.complete();
    await operation;

    expect(navigated, isEmpty);
  });
}

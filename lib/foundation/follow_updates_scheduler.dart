import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/onboarding.dart';

/// Registers local checks; native code owns the cross-process data lease.
abstract class FollowUpdatesScheduler {
  static const channel = MethodChannel('venera/follow_scheduler');
  static Future<void> _scheduleTail = Future.value();
  static Timer? _pollTimer;
  static DateTime? _pollAt;
  static Future<void> Function()? _poll;

  static DateTime nextPoll(DateTime now, String fixedTime) {
    final regular = now.add(const Duration(minutes: 10));
    final time = FollowUpdateScope.parseFixedTime(fixedTime);
    if (time == null) return regular;
    var fixed = DateTime(now.year, now.month, now.day, time.hour, time.minute);
    if (!fixed.isAfter(now)) {
      fixed = DateTime(
        now.year,
        now.month,
        now.day + 1,
        time.hour,
        time.minute,
      );
    }
    return fixed.isBefore(regular) ? fixed : regular;
  }

  static void startPolling(Future<void> Function() check) {
    _poll = check;
    _schedulePoll();
  }

  static void _schedulePoll() {
    final check = _poll;
    if (check == null) return;
    final now = DateTime.now();
    final next = nextPoll(now, FollowUpdateScope.fixedTime);
    // Settings syncs and lifecycle callbacks must not postpone an existing poll.
    if (_pollAt != null && !_pollAt!.isAfter(next)) return;
    _pollTimer?.cancel();
    _pollAt = next;
    _pollTimer = Timer(next.difference(now), () {
      _pollAt = null;
      _schedulePoll();
      unawaited(check());
    });
  }

  static Future<void> acquireUiData() async {
    if (!App.isOhos && !App.isAndroid) return;
    await channel.invokeMethod<void>('acquireUiData');
  }

  static Future<void> sync() {
    _schedulePoll();
    if (!App.isOhos && !App.isAndroid) return Future.value();
    return _scheduleTail = _scheduleTail.then((_) async {
      try {
        final time = FollowUpdateScope.parseFixedTime(
          FollowUpdateScope.fixedTime,
        );
        await channel.invokeMethod<void>('configure', {
          'enabled':
              FollowUpdateScope.isConfigured &&
              !OnboardingStore.instance.blocksAutomaticTasks,
          if (time != null) 'fixedMinute': time.hour * 60 + time.minute,
        });
      } catch (_) {
        Log.warning('Follow Updates', 'Unable to schedule background checks.');
      }
    });
  }

  static void listen({
    required Future<void> Function() check,
    required void Function() stop,
  }) {
    if (!App.isAndroid) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'check') await check();
      if (call.method == 'stop') stop();
    });
  }
}

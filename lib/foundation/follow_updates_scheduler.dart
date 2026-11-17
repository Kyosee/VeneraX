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

  static Future<void> acquireUiData() async {
    if (!App.isOhos && !App.isAndroid) return;
    await channel.invokeMethod<void>('acquireUiData');
  }

  static Future<void> sync() {
    if (!App.isOhos && !App.isAndroid) return Future.value();
    return _scheduleTail = _scheduleTail.then((_) async {
      try {
        await channel.invokeMethod<void>('configure', {
          'enabled':
              FollowUpdateScope.isConfigured &&
              !OnboardingStore.instance.blocksAutomaticTasks,
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

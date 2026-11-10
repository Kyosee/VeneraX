import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/log.dart';

/// Registers local checks; native code owns the cross-process data lease.
abstract class OhosFollowScheduler {
  static const channel = MethodChannel('venera/follow_scheduler');
  static Future<void> _scheduleTail = Future.value();

  static Future<void> acquireUiData() async {
    if (!App.isOhos) return;
    await channel.invokeMethod<void>('acquireUiData');
  }

  static Future<void> sync() {
    if (!App.isOhos) return Future.value();
    return _scheduleTail = _scheduleTail.then((_) async {
      try {
        await channel.invokeMethod<void>('configure', {
          'enabled': FollowUpdateScope.isConfigured,
        });
      } catch (_) {
        Log.warning('Follow Updates', 'Unable to schedule background checks.');
      }
    });
  }
}

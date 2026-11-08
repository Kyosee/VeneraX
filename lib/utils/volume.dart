import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/log.dart';

class VolumeListener {
  static const channel = EventChannel('venera/volume');

  void Function()? onUp;

  void Function()? onDown;

  VolumeListener({this.onUp, this.onDown});

  StreamSubscription? stream;

  void listen() {
    stream ??= channel.receiveBroadcastStream().listen(
      onEvent,
      onError: (Object error) {
        Log.warning('Reader', 'Volume key events are unavailable: $error');
      },
    );
  }

  void onEvent(event) {
    if (event == 1) {
      onUp?.call();
    } else if (event == 2) {
      onDown?.call();
    }
  }

  void cancel() {
    stream?.cancel();
    stream = null;
  }
}

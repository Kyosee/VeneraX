import 'package:flutter/services.dart';
import 'package:venera/foundation/log.dart';

final _reportedNativeDiagnostics = <String>{};

/// OS reports arrive after a native crash, when the next process starts.
Future<void> readOhosNativeDiagnostics() async {
  try {
    final records = await const MethodChannel(
      'venera/method_channel',
    ).invokeListMethod<String>('readNativeDiagnostics');
    for (final record in records ?? <String>[]) {
      if (!_reportedNativeDiagnostics.add(record)) continue;
      for (var start = 0; start < record.length; start += Log.maxLogLength) {
        final end = (start + Log.maxLogLength).clamp(0, record.length);
        Log.error('HarmonyOS native diagnostics', record.substring(start, end));
      }
    }
    Log.flush();
  } on MissingPluginException {
    // Older hosts have no native report bridge.
  } on PlatformException catch (error) {
    Log.warning('Native diagnostics', error.message ?? error.code);
  }
}

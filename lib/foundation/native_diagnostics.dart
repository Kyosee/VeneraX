import 'package:flutter/services.dart';
import 'package:venera/foundation/log.dart';

final _reportedNativeDiagnostics = <String>{};

const _channel = MethodChannel('venera/method_channel');

/// How HarmonyOS says the previous process ended.
typedef OsExit = ({int reason, String message});

/// `AbilityConstant.LastExitReason`.
const _exitReasons = [
  'UNKNOWN',
  'ABILITY_NOT_RESPONDING',
  'NORMAL',
  'CPP_CRASH',
  'JS_ERROR',
  'APP_FREEZE',
  'PERFORMANCE_CONTROL',
  'RESOURCE_CONTROL',
  'UPGRADE',
  'USER_REQUEST',
  'SIGNAL',
];

/// Whether [reason] settles by itself that the process crashed (true) or was
/// ended on purpose (false). Null where it does not: an unknown reason, or the
/// system reclaiming the app, which only matters if it was in use.
bool? osExitIsCrash(int reason) => switch (reason) {
  1 || 3 || 4 || 5 => true,
  2 || 8 || 9 => false,
  _ => null,
};

String describeOsExit(OsExit exit) {
  final name = exit.reason >= 0 && exit.reason < _exitReasons.length
      ? _exitReasons[exit.reason]
      : 'UNKNOWN';
  return exit.message.isEmpty
      ? '$name (${exit.reason})'
      : '$name (${exit.reason}): ${exit.message}';
}

/// Reads the `<reason>\n<message>` the host passes on.
OsExit? parseOsExit(String? text) {
  if (text == null || text.isEmpty) return null;
  final split = text.indexOf('\n');
  final reason = int.tryParse(split == -1 ? text : text.substring(0, split));
  if (reason == null) return null;
  return (
    reason: reason,
    message: split == -1 ? '' : text.substring(split + 1).trim(),
  );
}

Future<OsExit?> readOhosLastExit() async {
  try {
    return parseOsExit(await _channel.invokeMethod<String>('readLastExit'));
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// The crash and freeze reports the system has delivered so far, oldest first.
Future<List<String>> readOhosNativeRecords() async {
  try {
    return await _channel.invokeListMethod<String>('readNativeDiagnostics') ??
        const [];
  } on MissingPluginException {
    return const [];
  } on PlatformException {
    return const [];
  }
}

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

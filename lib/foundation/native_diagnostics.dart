import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/tombstone.dart';

final _reportedNativeDiagnostics = <String>{};

const _channel = MethodChannel('venera/method_channel');

/// What the system itself says about how the previous process ended.
///
/// [crashed] is true or false where that settles the question and null where
/// it does not, as when the system reclaimed the app. [at] is when the process
/// ended, in milliseconds since the epoch, where the platform says.
typedef OsExit = ({bool? crashed, String description, int? at});

/// The previous process's exit as the platform records it, or null where it
/// keeps no such record.
Future<OsExit?> readOsExit() async {
  try {
    if (App.isOhos) {
      final exit = parseOhosExit(
        await _channel.invokeMethod<String>('readLastExit'),
      );
      if (exit == null) return null;
      return (
        crashed: ohosExitIsCrash(exit.reason),
        description: describeOhosExit(exit),
        at: null,
      );
    }
    if (App.isAndroid) {
      return parseAndroidExit(
        await _channel.invokeMapMethod<String, Object?>('readLastExit', {
          'trace': false,
        }),
      );
    }
    // HarmonyOS is neither and keeps its own branch above.
    if (App.isWindows || App.isLinux) return _takeHostExit();
  } on MissingPluginException {
    // An older host.
  } on PlatformException catch (error) {
    Log.warning('Native diagnostics', error.message ?? error.code);
  }
  return null;
}

/// The system's own record of the previous process's crash or freeze, as
/// text: a native crash's stacks or the thread dump of a hang. Android 11 on,
/// and what the Windows and Linux hosts recorded.
Future<String?> readOsExitTrace() async {
  if (App.isWindows || App.isLinux) return _hostTrace;
  if (!App.isAndroid) return null;
  try {
    final exit = await _channel.invokeMapMethod<String, Object?>(
      'readLastExit',
      {'trace': true},
    );
    final trace = exit?['trace'];
    if (trace is! Uint8List || trace.isEmpty) return null;
    return exit?['format'] == 'tombstone'
        ? describeTombstone(trace)
        : utf8.decode(trace, allowMalformed: true);
  } on MissingPluginException {
    return null;
  } on PlatformException {
    return null;
  }
}

/// What [readOsExit] took from the host on Windows and Linux: reading the
/// record removes it.
String? _hostTrace;

OsExit? _takeHostExit() {
  final directory = hostRecordDirectory();
  if (directory == null) return null;
  final records = takeHostRecords(Directory(directory));
  _hostTrace = records.trace;
  return records.exit;
}

/// Where the Windows and Linux hosts record how the process ended. They work
/// it out by themselves, so that a crash while the engine starts is recorded
/// too, and both sides have to agree on it.
String? hostRecordDirectory([Map<String, String>? environment]) {
  try {
    final env = environment ?? Platform.environment;
    if (App.isWindows) {
      final base = env['LOCALAPPDATA'];
      return base == null || base.isEmpty ? null : '$base\\VeneraX';
    }
    if (App.isLinux) {
      // XDG ignores a relative path.
      final cache = env['XDG_CACHE_HOME'];
      if (cache != null && cache.startsWith('/')) return '$cache/venerax';
      final home = env['HOME'];
      return home == null || home.isEmpty ? null : '$home/.cache/venerax';
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Reads the `time=` and `reason=` lines a host crash record starts with.
OsExit? parseHostRecord(String text) {
  int? at;
  String? reason;
  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('time=')) {
      at = int.tryParse(line.substring(5).trim());
    } else if (line.startsWith('reason=')) {
      reason = line.substring(7).trim();
    } else {
      // The stack follows.
      break;
    }
  }
  if (reason == null || reason.isEmpty) return null;
  return (crashed: true, description: reason, at: at);
}

/// Reads what the host left in [directory] and removes it, so that a record
/// never speaks for a later process.
///
/// A crash wins over the end of the system session: the process may have
/// crashed while the session was ending.
({OsExit? exit, String? trace}) takeHostRecords(Directory directory) {
  try {
    final crash = File('${directory.path}/native_crash.txt');
    final ended = File('${directory.path}/session_ended');
    String? text;
    if (crash.existsSync()) {
      text = utf8.decode(crash.readAsBytesSync(), allowMalformed: true);
      crash.deleteSync();
    }
    int? endedAt;
    if (ended.existsSync()) {
      endedAt = ended.lastModifiedSync().millisecondsSinceEpoch;
      ended.deleteSync();
    }
    final exit = text == null ? null : parseHostRecord(text);
    if (exit != null) return (exit: exit, trace: text);
    if (endedAt != null) {
      return (
        exit: (
          crashed: false,
          description: 'the system session ended',
          at: endedAt,
        ),
        trace: null,
      );
    }
  } catch (_) {
    // Unreadable is the same as absent.
  }
  return (exit: null, trace: null);
}

/// Reads what the Android host makes of `ApplicationExitInfo`.
OsExit? parseAndroidExit(Map<String, Object?>? exit) {
  if (exit == null) return null;
  final kind = exit['kind'];
  final name = exit['name'] as String? ?? 'UNKNOWN';
  final detail = exit['description'] as String? ?? '';
  final reason = exit['reason'];
  return (
    crashed: kind == 'crash'
        ? true
        : kind == 'ended'
        ? false
        : null,
    description: detail.isEmpty
        ? '$name ($reason)'
        : '$name ($reason): $detail',
    at: exit['at'] as int?,
  );
}

/// How HarmonyOS says the previous process ended.
typedef OhosExit = ({int reason, String message});

/// `AbilityConstant.LastExitReason`.
const _ohosExitReasons = [
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
bool? ohosExitIsCrash(int reason) => switch (reason) {
  1 || 3 || 4 || 5 => true,
  2 || 8 || 9 => false,
  _ => null,
};

String describeOhosExit(OhosExit exit) {
  final name = exit.reason >= 0 && exit.reason < _ohosExitReasons.length
      ? _ohosExitReasons[exit.reason]
      : 'UNKNOWN';
  return exit.message.isEmpty
      ? '$name (${exit.reason})'
      : '$name (${exit.reason}): ${exit.message}';
}

/// Reads the `<reason>\n<message>` the HarmonyOS host passes on.
OhosExit? parseOhosExit(String? text) {
  if (text == null || text.isEmpty) return null;
  final split = text.indexOf('\n');
  final reason = int.tryParse(split == -1 ? text : text.substring(0, split));
  if (reason == null) return null;
  return (
    reason: reason,
    message: split == -1 ? '' : text.substring(split + 1).trim(),
  );
}

/// The crash and freeze reports HarmonyOS has delivered so far, oldest first.
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

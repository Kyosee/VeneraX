/// iOS and macOS hand the app its crash and hang reports through MetricKit on
/// a later launch. The host keeps each delivery as
/// `diagnostics/system-<milliseconds>-<n>.json`, named for when it arrived.
library;

import 'dart:convert';
import 'dart:io';

const _maxFrames = 64;

final _fileName = RegExp(r'^system-(\d+)-(\d+)\.json$');

const _exceptionTypes = {
  1: 'EXC_BAD_ACCESS',
  2: 'EXC_BAD_INSTRUCTION',
  3: 'EXC_ARITHMETIC',
  5: 'EXC_SOFTWARE',
  6: 'EXC_BREAKPOINT',
  10: 'EXC_CRASH',
  11: 'EXC_RESOURCE',
  12: 'EXC_GUARD',
};

const _signals = {
  4: 'SIGILL',
  5: 'SIGTRAP',
  6: 'SIGABRT',
  8: 'SIGFPE',
  9: 'SIGKILL',
  10: 'SIGBUS',
  11: 'SIGSEGV',
  12: 'SIGSYS',
  13: 'SIGPIPE',
  15: 'SIGTERM',
};

/// The kept files that arrived in [from, to), oldest first; [to] null for no
/// end.
List<String> pickSystemDiagnostics(
  Iterable<String> names, {
  required int from,
  int? to,
}) {
  final picked = <(int, int, String)>[];
  for (final name in names) {
    final match = _fileName.firstMatch(name);
    if (match == null) continue;
    final time = int.tryParse(match[1]!);
    final index = int.tryParse(match[2]!);
    if (time == null || index == null) continue;
    if (time < from || (to != null && time >= to)) continue;
    picked.add((time, index, name));
  }
  picked.sort((a, b) {
    final byTime = a.$1.compareTo(b.$1);
    return byTime != 0 ? byTime : a.$2.compareTo(b.$2);
  });
  return [for (final (_, _, name) in picked) name];
}

/// The kept crash and hang reports in [directory] that arrived in [from, to),
/// as text. Null when there are none or none can be read.
String? readSystemDiagnostics(
  Directory directory, {
  required int from,
  int? to,
}) {
  try {
    if (!directory.existsSync()) return null;
    final names = [
      for (final entry in directory.listSync())
        if (entry is File) entry.uri.pathSegments.last,
    ];
    final texts = <String>[];
    for (final name in pickSystemDiagnostics(names, from: from, to: to)) {
      try {
        final text = describeSystemDiagnostics(
          File('${directory.path}/$name').readAsStringSync(),
        );
        if (text != null) texts.add(text);
      } catch (_) {
        // One unreadable file does not hide the others.
      }
    }
    return texts.isEmpty ? null : texts.join('\n\n');
  } catch (_) {
    return null;
  }
}

String _named(Object value, Map<int, String> names) {
  final name = value is int ? names[value] : null;
  return name == null ? '$value' : '$value ($name)';
}

String _frame(Map frame, int index) {
  final name = frame['binaryName'];
  final uuid = frame['binaryUUID'];
  final buffer = StringBuffer(
    '#${index.toString().padLeft(2, '0')} '
    '${name is String && name.isNotEmpty ? name : '<unknown>'} '
    '+${frame['offsetIntoBinaryTextSegment'] ?? '?'}',
  );
  if (uuid is String && uuid.isNotEmpty) buffer.write(' ($uuid)');
  return buffer.toString();
}

/// Depth first, which for a crash is the stack from the crashing frame down.
/// False once [lines] is full.
bool _walk(Object? frames, List<String> lines) {
  if (frames is! List) return true;
  for (final frame in frames) {
    if (frame is! Map) continue;
    if (lines.length >= _maxFrames) return false;
    lines.add(_frame(frame, lines.length));
    if (!_walk(frame['subFrames'], lines)) return false;
  }
  return true;
}

void _diagnostic(StringBuffer buffer, String kind, Map diagnostic) {
  buffer.writeln('$kind:');
  final meta = diagnostic['diagnosticMetaData'];
  if (meta is Map) {
    void field(String label, String key, [Map<int, String>? names]) {
      final value = meta[key];
      if (value == null || value is Map || value is List) return;
      buffer.writeln('$label: ${names == null ? value : _named(value, names)}');
    }

    field('Exception type', 'exceptionType', _exceptionTypes);
    field('Exception code', 'exceptionCode');
    field('Signal', 'signal', _signals);
    field('Termination reason', 'terminationReason');
    field('Hang duration', 'hangDuration');
    final version = meta['appVersion'];
    final build = meta['appBuildVersion'];
    if (version != null) {
      buffer.writeln(
        'App version: $version${build == null ? '' : ' ($build)'}',
      );
    }
    field('OS version', 'osVersion');
    field('Device', 'deviceType');
    field('Architecture', 'platformArchitecture');
  }
  final tree = diagnostic['callStackTree'];
  final stacks = tree is Map ? tree['callStacks'] : null;
  if (stacks is! List) return;
  for (final stack in stacks) {
    if (stack is! Map || stack['threadAttributed'] != true) continue;
    final lines = <String>[];
    final complete = _walk(stack['callStackRootFrames'], lines);
    buffer.writeln('Attributed thread:');
    for (final line in lines) {
      buffer.writeln('  $line');
    }
    if (!complete) buffer.writeln('  (more frames not shown)');
  }
}

/// The crash and hang reports in one MetricKit delivery: for each, what the
/// system says about it, then the stack of the thread it is attributed to.
///
/// Other kinds of report in the delivery are left out. Null when [json] is no
/// delivery or holds no crash or hang.
String? describeSystemDiagnostics(String json) {
  try {
    final payload = jsonDecode(json);
    if (payload is! Map) return null;
    final buffer = StringBuffer();
    for (final (key, kind) in const [
      ('crashDiagnostics', 'Crash'),
      ('hangDiagnostics', 'Hang'),
    ]) {
      final diagnostics = payload[key];
      if (diagnostics is! List) continue;
      for (final diagnostic in diagnostics) {
        if (diagnostic is! Map) continue;
        if (buffer.isNotEmpty) buffer.writeln();
        _diagnostic(buffer, kind, diagnostic);
      }
    }
    if (buffer.isEmpty) return null;
    final begin = payload['timeStampBegin'];
    final end = payload['timeStampEnd'];
    final period = begin is String && end is String
        ? 'Reported for: ${begin == end ? begin : '$begin to $end'}\n'
        : '';
    return '$period$buffer'.trimRight();
  } catch (_) {
    return null;
  }
}

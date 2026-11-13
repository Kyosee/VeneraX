import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';

class LogItem {
  final LogLevel level;
  final String title;
  final String content;
  final DateTime time;

  /// Also the on-disk format; [Log.parse] reads it back.
  @override
  toString() => "${level.name} $title $time \n$content\n\n";

  LogItem(this.level, this.title, this.content, [DateTime? time])
    : time = time ?? DateTime.now();
}

enum LogLevel { error, warning, info }

class Log {
  static final List<LogItem> _logs = <LogItem>[];

  static List<LogItem> get logs => _logs;

  static const maxLogLength = 3000;

  static const maxLogNumber = 500;

  static bool ignoreLimitation = false;

  static bool isMuted = false;

  /// Whether to record a log line for every successful network request.
  ///
  /// Off by default: reading a comic issues a request per page, and recording
  /// two lines for each (with header formatting and a disk write) kept the CPU
  /// and flash busy continuously — a steady battery drain with no visible
  /// frame-rate cost. Failures are always logged regardless of this flag, so
  /// diagnosing a broken source does not need it. Users can turn it on from the
  /// logs page when they need a full trace for a bug report.
  ///
  /// Mirrored here from settings rather than read through `appdata`, which
  /// imports this file — reaching back the other way would make the two
  /// mutually dependent. [syncVerboseNetwork] keeps it in step.
  static bool verboseNetwork = false;

  /// Points [verboseNetwork] at the stored setting. Called on startup and
  /// whenever the switch is toggled.
  static void syncVerboseNetwork(bool value) => verboseNetwork = value;

  static void printWarning(String text) {
    debugPrint('\x1B[33m$text\x1B[0m');
  }

  static void printError(String text) {
    debugPrint('\x1B[31m$text\x1B[0m');
  }

  /// Bumped on every change to [logs], so an open logs page can follow along.
  static final changes = ValueNotifier<int>(0);

  static IOSink? _file;

  static const _fileName = "logs.txt";

  static const _previousFileName = "logs.previous.txt";

  static Directory _directory() => App.isAndroid
      ? Directory(App.externalStoragePath!)
      : Directory(App.dataPath);

  static void _openFile() {
    var dir = _directory();
    var file = dir.joinFile(_fileName);
    // Opening for write truncates, and after a crash the last run's file is
    // the only record of what went wrong. Keep one generation of it.
    try {
      if (file.existsSync()) {
        file.renameSync(dir.joinFile(_previousFileName).path);
      }
    } catch (e) {
      debugPrint('Failed to keep previous logs: $e');
    }
    _file = file.openWrite();
  }

  static void addLog(LogLevel level, String title, String content) {
    if (isMuted) return;
    if (_file == null && App.isInitialized) {
      _openFile();
    }

    if (!ignoreLimitation && content.length > maxLogLength) {
      content = "${content.substring(0, maxLogLength)}...";
    }

    switch (level) {
      case LogLevel.error:
        printError(content);
      case LogLevel.warning:
        printWarning(content);
      case LogLevel.info:
        if(kDebugMode) {
          debugPrint(content);
        }
    }

    var newLog = LogItem(level, title, content);

    if (newLog == _logs.lastOrNull) {
      return;
    }

    _logs.add(newLog);
    _queueForDisk(newLog);
    if (_logs.length > maxLogNumber) {
      var res = _logs.remove(
          _logs.firstWhereOrNull((element) => element.level == LogLevel.info));
      if (!res) {
        _logs.removeAt(0);
      }
    }
    changes.value++;
  }

  static info(String title, String content) {
    addLog(LogLevel.info, title, content);
  }

  static warning(String title, String content) {
    addLog(LogLevel.warning, title, content);
  }

  static error(String title, Object content, [Object? stackTrace]) {
    var info = content.toString();
    if(stackTrace != null) {
      info += "\n${stackTrace.toString()}";
    }
    addLog(LogLevel.error, title, info);
  }

  /// Pending lines not yet handed to the [IOSink].
  ///
  /// Writing each line as it is produced meant one small disk write per network
  /// request, which keeps the storage controller from idling. Batching them and
  /// flushing on a timer turns a stream of tiny writes into an occasional
  /// larger one, at the cost of losing at most [_flushInterval] worth of lines
  /// if the process is killed outright.
  static final List<String> _pending = [];

  static Timer? _flushTimer;

  static const _flushInterval = Duration(seconds: 5);

  /// Flush early once the buffer grows past this, so a burst of activity does
  /// not sit in memory for the whole interval.
  static const _maxPending = 64;

  static void _queueForDisk(LogItem log) {
    if (_file == null) return;
    _pending.add(log.toString());
    // Errors go out immediately: whatever follows may be a crash, and a report
    // is worthless if the line explaining it never left memory. Batching only
    // pays off for the high-volume info level anyway.
    if (log.level == LogLevel.error || _pending.length >= _maxPending) {
      flush();
      return;
    }
    _flushTimer ??= Timer(_flushInterval, flush);
  }

  /// Writes buffered lines to disk. Safe to call at any time; a no-op when
  /// there is nothing pending.
  static void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_pending.isEmpty || _file == null) return;
    var batch = _pending.join();
    _pending.clear();
    try {
      _file!.write(batch);
    } catch (e) {
      // A failed log write must never take the app down.
      debugPrint('Failed to write logs: $e');
    }
  }

  /// Clears the in-memory list shown on the logs page.
  ///
  /// Buffered lines are flushed rather than dropped: they were already recorded
  /// before the user asked to clear the view, and the file is a separate record
  /// this has never truncated.
  static void clear() {
    flush();
    _logs.clear();
    changes.value++;
  }

  /// How much of the previous run's file is read. The end is what explains a
  /// crash, and a run with every request logged can leave megabytes behind.
  static const _previousTailBytes = 1 << 20;

  /// Entries the previous run left on disk, oldest first. Empty when there is
  /// no such file.
  static Future<List<LogItem>> loadPreviousSession() async {
    if (!App.isInitialized) return const [];
    var file = _directory().joinFile(_previousFileName);
    if (!await file.exists()) return const [];
    var raf = await file.open();
    Uint8List bytes;
    try {
      var length = await raf.length();
      var start = length > _previousTailBytes ? length - _previousTailBytes : 0;
      await raf.setPosition(start);
      bytes = await raf.read(length - start);
    } finally {
      await raf.close();
    }
    return compute(_parseBytes, bytes);
  }

  static List<LogItem> _parseBytes(Uint8List bytes) =>
      parse(utf8.decode(bytes, allowMalformed: true));

  static final _header = RegExp(
    r'^(error|warning|info) (.*) (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+) $',
    multiLine: true,
  );

  /// Reads text written by [LogItem.toString] back into entries. Text before
  /// the first header, such as an entry cut in half by a tail read, is dropped.
  static List<LogItem> parse(String text) {
    var matches = _header.allMatches(text).toList();
    var items = <LogItem>[];
    for (var i = 0; i < matches.length; i++) {
      var match = matches[i];
      var end = i + 1 < matches.length ? matches[i + 1].start : text.length;
      var start = match.end < end ? match.end + 1 : end;
      var content = text.substring(start, end);
      var trimmed = content.length;
      while (trimmed > 0 && content.codeUnitAt(trimmed - 1) == 0x0A) {
        trimmed--;
      }
      items.add(
        LogItem(
          LogLevel.values.byName(match[1]!),
          match[2]!,
          content.substring(0, trimmed),
          DateTime.tryParse(match[3]!),
        ),
      );
    }
    return items;
  }

  /// Plain text for saving or sharing, led by what a bug report needs.
  static String exportText(Iterable<LogItem> items, {String title = "Logs"}) {
    var buffer = StringBuffer()
      ..writeln(title)
      ..writeln("App version: ${App.version}")
      ..writeln(
        "Platform: ${Platform.operatingSystem} "
        "${Platform.operatingSystemVersion} (${Abi.current()})",
      )
      ..writeln("Exported at: ${DateTime.now()}")
      ..writeln();
    for (var item in items) {
      buffer.write(item);
    }
    return buffer.toString();
  }

  static String exportFileName([DateTime? time]) {
    var t = time ?? DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return "logs-${t.year}${two(t.month)}${two(t.day)}"
        "-${two(t.hour)}${two(t.minute)}${two(t.second)}.txt";
  }

  @override
  String toString() => exportText(_logs);
}

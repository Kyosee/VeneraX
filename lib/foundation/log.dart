import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';

class LogItem {
  final LogLevel level;
  final String title;
  final String content;
  final DateTime time = DateTime.now();

  @override
  toString() => "${level.name} $title $time \n$content\n\n";

  LogItem(this.level, this.title, this.content);
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
  static bool get verboseNetwork =>
      appdata.settings['verboseNetworkLog'] == true;

  static void printWarning(String text) {
    debugPrint('\x1B[33m$text\x1B[0m');
  }

  static void printError(String text) {
    debugPrint('\x1B[31m$text\x1B[0m');
  }

  static IOSink? _file;

  static void addLog(LogLevel level, String title, String content) {
    if (isMuted) return;
    if (_file == null && App.isInitialized) {
      Directory dir;
      if (App.isAndroid) {
        dir = Directory(App.externalStoragePath!);
      } else {
        dir = Directory(App.dataPath);
      }
      var file = dir.joinFile("logs.txt");
      _file = file.openWrite();
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
  }

  @override
  String toString() {
    var res = "Logs\n\n";
    for (var log in _logs) {
      res += log.toString();
    }
    return res;
  }
}

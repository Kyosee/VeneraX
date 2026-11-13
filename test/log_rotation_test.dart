import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';

/// The log file used to be truncated on every launch, so the run that crashed
/// lost its only record the moment the app was reopened. It is now kept as the
/// previous run's file and readable from the logs page.
///
/// Kept in its own file: it opens a real log sink, which the other log tests
/// rely on never happening.
void main() {
  test('the previous run file survives the next launch and reads back', () async {
    final dir = Directory.systemTemp.createTempSync('log-rotation-');
    File('${dir.path}/logs.txt').writeAsStringSync(
      LogItem(
        LogLevel.error,
        'Crash',
        'last words',
        DateTime(2026, 11, 13, 8),
      ).toString(),
    );
    App.dataPath = dir.path;
    App.externalStoragePath = dir.path;
    App.isInitialized = true;

    Log.info('Startup', 'new run');

    expect(
      File('${dir.path}/logs.previous.txt').readAsStringSync(),
      contains('last words'),
    );
    final previous = await Log.loadPreviousSession();
    expect(previous, hasLength(1));
    expect(previous.single.level, LogLevel.error);
    expect(previous.single.title, 'Crash');
    expect(previous.single.content, 'last words');
    expect(previous.single.time, DateTime(2026, 11, 13, 8));

    Log.flush();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // The sink stays open for the process; Windows refuses the delete.
    }
  });
}

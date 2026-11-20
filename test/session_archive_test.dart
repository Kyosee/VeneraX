import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/session_guard.dart';

/// Only one generation of the log file is kept, so a crashed run's log was
/// gone after two more launches. An abnormal exit now sets its record and the
/// end of its log aside, and only the newest few are kept.
///
/// Kept in its own file: it opens a real log sink, which the other log tests
/// rely on never happening.
void main() {
  test('an abnormal exit is set aside with the end of its log', () async {
    final dir = Directory.systemTemp.createTempSync('session-archive-');
    App.dataPath = dir.path;
    App.externalStoragePath = dir.path;
    App.isInitialized = true;

    // Older reports already on disk: only the newest five survive.
    final reports = Directory('${dir.path}/diagnostics')..createSync();
    for (var id = 1; id <= 6; id++) {
      File('${reports.path}/$id.json').writeAsStringSync(
        '{"id": $id, "version": "1.0.0", "archivedAt": ${id + 1}}',
      );
      File('${reports.path}/$id.log').writeAsStringSync('old');
    }

    File('${dir.path}/logs.txt').writeAsStringSync(
      LogItem(LogLevel.error, 'Sync', 'last words').toString(),
    );
    await SessionGuard.start(
      directory: dir,
      version: '1.0.0',
      bootTime: () => 1000,
      observeLifecycle: false,
    );
    SessionGuard.begin('sync');
    final crashed = SessionGuard.current!.id;
    SessionGuard.reset();

    await SessionGuard.start(
      directory: dir,
      version: '1.0.0',
      bootTime: () => 1000,
      osExit: () async => (reason: 3, message: 'Signal:SIGSEGV'),
      observeLifecycle: false,
    );
    expect(SessionGuard.previousExit, PreviousExit.suspectedCrash);
    await SessionGuard.archivePreviousRun();

    final kept = SessionGuard.reports();
    expect(kept.map((report) => report.record.id), [crashed, 6, 5, 4, 3]);
    expect(File('${reports.path}/2.json').existsSync(), isFalse);
    expect(File('${reports.path}/2.log').existsSync(), isFalse);
    expect(File('${reports.path}/1.log').existsSync(), isFalse);

    final latest = kept.first;
    expect(latest.record.active, ['sync']);
    expect(latest.archivedAt, greaterThanOrEqualTo(crashed));
    // What the system said about the exit is kept with it.
    expect(latest.osExit, 'CPP_CRASH (3): Signal:SIGSEGV');
    expect(kept.last.osExit, isNull);
    final entries = Log.parse(latest.log.readAsStringSync());
    expect(entries.single.title, 'Sync');
    expect(entries.single.content, 'last words');

    Log.flush();
    SessionGuard.reset();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // The sink stays open for the process; Windows refuses the delete.
    }
  });
}

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/native_diagnostics.dart';

/// On Windows and Linux a native crash ends the process before the app can
/// log a line, so the host's own record is the only evidence of it. Each
/// record has to count for exactly one launch, and the end of the system
/// session must not be mistaken for a crash.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('host-record-');
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  File crashFile() => File('${dir.path}/native_crash.txt');
  File endedFile() => File('${dir.path}/session_ended');

  const windowsRecord =
      'time=1795157828934\n'
      'reason=exception 0xc0000005 at sqlite3.dll+0x1a2b3\n'
      '#00 sqlite3.dll+0x1a2b3\n'
      '#01 venera.exe+0x1509\n';

  test('a crash record gives its reason and time', () {
    expect(parseHostRecord(windowsRecord), (
      crashed: true,
      description: 'exception 0xc0000005 at sqlite3.dll+0x1a2b3',
      at: 1795157828934,
    ));
    // The Linux host writes its stack as the C library prints it.
    expect(
      parseHostRecord(
        'time=1795157828934\r\n'
        'reason=signal 11 (SIGSEGV) at 0x10\r\n'
        '/opt/venera/lib/libapp.so(+0x1234)[0x7f0000001234]\r\n',
      ),
      (
        crashed: true,
        description: 'signal 11 (SIGSEGV) at 0x10',
        at: 1795157828934,
      ),
    );
    // A freeze the watchdog ended has no stack.
    expect(
      parseHostRecord(
        'time=1\nreason=the window stopped responding for 10 seconds and was '
        'closed\n',
      ),
      (
        crashed: true,
        description:
            'the window stopped responding for 10 seconds and was closed',
        at: 1,
      ),
    );
  });

  test('a record without a reason is no record', () {
    expect(parseHostRecord(''), isNull);
    expect(parseHostRecord('time=1795157828934\n'), isNull);
    expect(parseHostRecord('time=1\nreason=\n'), isNull);
    expect(parseHostRecord('garbage\nreason=late\n'), isNull);
    // Cut off before the stack, or with a time that does not read.
    expect(parseHostRecord('time=17951\nreason=signal 6 (SIGABRT)'), (
      crashed: true,
      description: 'signal 6 (SIGABRT)',
      at: 17951,
    ));
    expect(parseHostRecord('time=soon\nreason=signal 6 (SIGABRT)\n'), (
      crashed: true,
      description: 'signal 6 (SIGABRT)',
      at: null,
    ));
  });

  test('a crash record is read once, with its full text, then removed', () {
    crashFile().writeAsStringSync(windowsRecord);

    final first = takeHostRecords(dir);
    expect(first.exit?.crashed, isTrue);
    expect(first.exit?.at, 1795157828934);
    expect(first.trace, windowsRecord);
    expect(crashFile().existsSync(), isFalse);

    final second = takeHostRecords(dir);
    expect(second.exit, isNull);
    expect(second.trace, isNull);
  });

  test('the end of the system session is no crash, dated by its marker', () {
    final endedAt = DateTime.fromMillisecondsSinceEpoch(1795157000000);
    endedFile()
      ..createSync()
      ..setLastModifiedSync(endedAt);

    final records = takeHostRecords(dir);
    expect(records.exit, (
      crashed: false,
      description: 'the system session ended',
      at: endedAt.millisecondsSinceEpoch,
    ));
    expect(records.trace, isNull);
    expect(endedFile().existsSync(), isFalse);
  });

  test('a crash wins over the end of the session, and both are removed', () {
    crashFile().writeAsStringSync(windowsRecord);
    endedFile().createSync();

    final records = takeHostRecords(dir);
    expect(records.exit?.crashed, isTrue);
    expect(records.trace, windowsRecord);
    expect(crashFile().existsSync(), isFalse);
    expect(endedFile().existsSync(), isFalse);
  });

  test('nothing recorded, or no directory, means no record', () {
    expect(takeHostRecords(dir), (exit: null, trace: null));
    expect(
      takeHostRecords(Directory('${dir.path}/missing')),
      (exit: null, trace: null),
    );
  });

  test('a damaged crash record is dropped and the session marker counts', () {
    crashFile().writeAsBytesSync([0xff, 0xfe, 0x00, 0x80, 0x0a]);
    expect(takeHostRecords(dir), (exit: null, trace: null));
    expect(crashFile().existsSync(), isFalse);

    crashFile().writeAsBytesSync([0xc3, 0x28, 0x0a, 0x23, 0x30]);
    endedFile().createSync();
    final records = takeHostRecords(dir);
    expect(records.exit?.crashed, isFalse);
    expect(records.trace, isNull);
    expect(crashFile().existsSync(), isFalse);
  });

  test('the directory follows the convention the native hosts use', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(
      hostRecordDirectory({'LOCALAPPDATA': r'C:\Users\a\AppData\Local'}),
      r'C:\Users\a\AppData\Local\VeneraX',
    );
    expect(hostRecordDirectory({'LOCALAPPDATA': ''}), isNull);
    expect(hostRecordDirectory({}), isNull);

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(
      hostRecordDirectory({'XDG_CACHE_HOME': '/x/cache', 'HOME': '/home/a'}),
      '/x/cache/venerax',
    );
    // XDG ignores a relative path.
    expect(
      hostRecordDirectory({'XDG_CACHE_HOME': 'cache', 'HOME': '/home/a'}),
      '/home/a/.cache/venerax',
    );
    expect(hostRecordDirectory({'HOME': '/home/a'}), '/home/a/.cache/venerax');
    expect(hostRecordDirectory({'HOME': ''}), isNull);
    expect(hostRecordDirectory({}), isNull);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(hostRecordDirectory({'HOME': '/home/a'}), isNull);
  });
}

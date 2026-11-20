import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/diagnostics.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/session_guard.dart';

/// Reports are posted on a public tracker, so what identifies a site, an
/// account or the device has to be gone before the user even sees the text,
/// while the parts a crash is diagnosed from stay readable.
void main() {
  group('what is hidden', () {
    late Redactor redactor;

    setUp(() => redactor = Redactor());

    test('a URL keeps its scheme and file type only', () {
      expect(
        redactor.redact('GET https://example.com/api/list?page=2&token=abc 403'),
        'GET https://site-1/… 403',
      );
      expect(
        redactor.redact('Failed https://img.example.net/a/b/001.webp'),
        'Failed https://site-2/….webp',
      );
      expect(redactor.redact('at https://example.com.'), 'at https://site-1.');
    });

    test('the same host keeps the same alias', () {
      final text = redactor.redact(
        'https://a.example.com/x then https://b.example.com/y '
        'then https://A.example.com/z',
      );
      expect(text, 'https://site-1/… then https://site-2/… then https://site-1/…');
    });

    test('an address with an account and a port leaves neither', () {
      expect(
        redactor.redact('PUT https://alice:hunter2@dav.example.org:5006/dav/alice/'),
        'PUT https://site-1/…',
      );
    });

    test('a bare host or address is hidden too', () {
      expect(
        redactor.redact("Failed host lookup: 'example.com'"),
        "Failed host lookup: 'site-1'",
      );
      expect(
        redactor.redact('Connection refused, address = 192.168.1.20, port = 5005'),
        'Connection refused, address = site-2, port = 5005',
      );
      expect(redactor.redact('10.0.0.5:8080 refused'), 'site-3 refused');
    });

    test('a build number is not taken for an address', () {
      const line = 'Build info: ALN-AL00 5.0.0.102(C00E102R4P17)';
      expect(redactor.redact(line), line);
    });

    test('credentials are hidden wherever they appear', () {
      expect(
        redactor.redact('cookie: a=b; session=xyz\nuser-agent: test'),
        'cookie: <hidden>\nuser-agent: test',
      );
      expect(
        redactor.redact('{set-cookie: sid=1; Path=/, content-type: text/html}'),
        '{set-cookie: <hidden>',
      );
      expect(
        redactor.redact('Authorization: Bearer abc.def.ghi'),
        'Authorization: <hidden>',
      );
      expect(
        redactor.redact('sent Bearer abcdefgh12345678 to it'),
        'sent Bearer <hidden> to it',
      );
      expect(
        redactor.redact('{"password": "hunter2", "name": "x"}'),
        '{"password": "<hidden>", "name": "x"}',
      );
      expect(redactor.redact('api_key=abc123&x=1'), 'api_key=<hidden>&x=1');
    });

    test('an account name is hidden', () {
      expect(
        redactor.redact('login as someone@example.com failed'),
        'login as <email> failed',
      );
    });

    test('a failing file keeps its type but not its folders', () {
      expect(
        redactor.redact(
          "PathNotFoundException: Cannot open file, "
          "path = '/storage/emulated/0/Comics/Some Title/001.jpg' "
          "(OS Error: No such file or directory, errno = 2)",
        ),
        "PathNotFoundException: Cannot open file, path = '<path>.jpg' "
        "(OS Error: No such file or directory, errno = 2)",
      );
    });

    test('the user name in a home folder is hidden', () {
      expect(
        redactor.redact(r'C:\Users\alice\AppData\Roaming\venera\session.json'),
        r'C:\Users\<user>\AppData\Roaming\venera\session.json',
      );
      expect(
        redactor.redact('/home/bob/.local/share/venera'),
        '/home/<user>/.local/share/venera',
      );
      expect(
        redactor.redact('/Users/carol/Library/Application Support'),
        '/Users/<user>/Library/Application Support',
      );
    });

    test('installed script names read as numbered aliases', () {
      final named = Redactor(names: ['Some Site', 'some_site', 'ab']);
      expect(
        named.redact('Some Site: load failed (some_site), SOME SITE again'),
        'script-1: load failed (script-2), script-1 again',
      );
      // Not inside a longer word, and not when too short to be distinctive.
      expect(named.redact('awesome_sites ab'), 'awesome_sites ab');
    });

    test('the sync account is removed', () {
      final secret = Redactor(secrets: ['alice', 'hunter2']);
      expect(
        secret.redact('401 for alice with hunter2'),
        '401 for <hidden> with <hidden>',
      );
    });

    test('stack traces stay as they are', () {
      for (final line in [
        '#0      _ReaderState.initState (package:venera/pages/reader/reader.dart:333)',
        '#1      StatefulElement._firstBuild (package:flutter/src/widgets/framework.dart:5842)',
        'java.net.SocketException: Connection reset',
        'at io.flutter.plugin.common.MethodChannel.invokeMethod(MethodChannel.java:258)',
        'at com.github.kyosee.venera.MainActivity.onCreate(MainActivity.kt:42)',
        'context.padding.top was null',
        'file:///C:/src/venera/lib/main.dart:40',
        'libflutter.so (offset 0x1a2b3c)',
        'Null check operator used on a null value',
      ]) {
        expect(redactor.redact(line), line);
      }
    });
  });

  group('the report', () {
    LogItem entry(
      LogLevel level,
      String title,
      String content, [
      int at = 5000,
    ]) => LogItem(
      level,
      title,
      content,
      DateTime.fromMillisecondsSinceEpoch(1000000 + at),
    );

    SessionRecord run() => SessionRecord(
      id: 1000000,
      version: '1.2.3',
      presence: SessionRecord.front,
      lastAt: 1000000 + 61500,
      active: ['sync.download', 'reader'],
      steps: [
        (at: 1000000, name: 'launch'),
        (at: 1000000 + 812, name: 'init'),
        (at: 1000000 + 61500, name: 'reader.start'),
      ],
    );

    String build({
      Iterable<LogItem> entries = const [],
      bool abnormal = true,
      int? endedBefore = 1000000 + 100000,
    }) => DiagnosticsReport.build(
      appVersion: '1.2.4',
      platform: 'android 14 (android_arm64)',
      device: 'Acme Phone',
      run: run(),
      abnormal: abnormal,
      endedBefore: endedBefore,
      entries: entries,
      now: DateTime(2026, 11, 20, 10),
    );

    test('says where the app ran and what the run was doing', () {
      final report = build();
      expect(report, contains('App version: 1.2.3'));
      expect(report, contains('Platform: android 14 (android_arm64)'));
      expect(report, contains('Device: Acme Phone'));
      expect(report, contains('== Run that ended abnormally =='));
      expect(report, contains('State: in use'));
      expect(report, contains('In progress: sync.download, reader'));
      expect(report, contains('Last recorded: +61.500s'));
      expect(report, contains('  +0.812s init'));
      expect(report, contains('  +61.500s reader.start'));
    });

    test('the current run is labelled as such', () {
      final report = build(abnormal: false, endedBefore: null);
      expect(report, contains('== Current run =='));
    });

    test('without a run on record the header still names the version', () {
      final report = DiagnosticsReport.build(
        appVersion: '1.2.4',
        platform: 'linux',
        entries: [entry(LogLevel.error, 'Reader', 'kept')],
      );
      expect(report, contains('App version: 1.2.4'));
      expect(report, isNot(contains('Device:')));
      expect(report, isNot(contains('run ==')));
      expect(report, contains('kept'));
    });

    test('errors come redacted and in order', () {
      final report = build(
        entries: [
          entry(LogLevel.error, 'Reader', 'first https://example.com/a', 1000),
          entry(LogLevel.warning, 'Sync', 'second', 2000),
        ],
      );
      expect(report, contains('== Errors and warnings (2) =='));
      expect(report, contains('first https://site-1/…'));
      expect(report.indexOf('first'), lessThan(report.indexOf('second')));
      expect(report, isNot(contains('example.com')));
    });

    test('a failed request keeps its first lines, not headers or body', () {
      final report = build(
        entries: [
          entry(
            LogLevel.error,
            'Network',
            'Response https://example.com/login 403\n'
                'headers:\n{set-cookie: sid=secret}\n'
                '<html>account page of someone</html>',
          ),
        ],
      );
      expect(report, contains('Response https://site-1/… 403'));
      expect(report, isNot(contains('secret')));
      expect(report, isNot(contains('account page')));
    });

    test('what scripts printed is left out and counted', () {
      final report = build(
        entries: [
          entry(LogLevel.error, 'JS Console', 'token is abc'),
          entry(LogLevel.info, 'JS Console', 'debug'),
          entry(LogLevel.error, 'Reader', 'kept'),
        ],
      );
      expect(report, isNot(contains('token is abc')));
      expect(report, contains('(2 entries printed by scripts left out)'));
      expect(report, contains('kept'));
    });

    test('only entries from that run are included', () {
      final report = build(
        entries: [
          entry(LogLevel.error, 'Old', 'from an earlier run', -60000),
          entry(LogLevel.error, 'Mine', 'from this run'),
          entry(LogLevel.error, 'Later', 'from a later run', 200000),
        ],
      );
      expect(report, contains('from this run'));
      expect(report, isNot(contains('from an earlier run')));
      expect(report, isNot(contains('from a later run')));
    });

    test('recent ordinary entries give context, cut short', () {
      final report = build(
        entries: [
          for (var i = 0; i < 30; i++)
            entry(LogLevel.info, 'Step', 'info $i ${'x' * 400}', i),
        ],
      );
      expect(report, contains('== Last other entries =='));
      expect(report, isNot(contains('info 9 ')));
      expect(report, contains('info 10 '));
      expect(report, contains('info 29 '));
      expect(report, isNot(contains('x' * 300)));
    });

    test('the system\'s own account of the exit is included', () {
      final report = DiagnosticsReport.build(
        appVersion: '1.2.4',
        platform: 'ohos',
        run: run(),
        abnormal: true,
        osExit: 'CPP_CRASH (3): Signal:SIGSEGV(SEGV_MAPERR)@0x0000000000000010',
        systemReport:
            'APP_CRASH: {"time":1005000,"crashType":"NativeCrash"}\n'
            'Module name:com.github.kyosee.venera\n'
            'Build info:ALN-AL00 5.0.0.102(C00E102R4P17)\n'
            '#00 pc 00000000000abcde /data/storage/el1/bundle/libs/arm64/libapp.so(_kDartIsolateSnapshotInstructions+1234)\n'
            'HiLog: fetch https://example.com/a.webp failed',
      );
      expect(
        report,
        contains(
          'System exit reason: CPP_CRASH (3): '
          'Signal:SIGSEGV(SEGV_MAPERR)@0x0000000000000010',
        ),
      );
      expect(report, contains('== System crash report =='));
      // The frames a crash is diagnosed from survive as they are.
      expect(report, contains('Module name:com.github.kyosee.venera'));
      expect(report, contains('5.0.0.102(C00E102R4P17)'));
      expect(
        report,
        contains(
          '#00 pc 00000000000abcde /data/storage/el1/bundle/libs/arm64/'
          'libapp.so(_kDartIsolateSnapshotInstructions+1234)',
        ),
      );
      expect(report, contains('fetch https://site-1/….webp failed'));
    });

    test('a long system report is cut and still leaves room for errors', () {
      final report = build(
        entries: [entry(LogLevel.error, 'Reader', 'kept')],
      );
      final long = DiagnosticsReport.build(
        appVersion: '1.2.4',
        platform: 'ohos',
        run: run(),
        abnormal: true,
        endedBefore: 1000000 + 100000,
        systemReport: 'APP_CRASH: ${'frame\n' * 20000}',
        entries: [entry(LogLevel.error, 'Reader', 'kept')],
      );
      expect(long.length, lessThan(65536));
      expect(long.length, greaterThan(report.length + 20000));
      expect(long, contains('kept'));
    });

    test('system reports are matched to a run by their own time stamp', () {
      String? pick(List<String> records) => DiagnosticsReport.systemReportFor(
        records,
        from: 1000000,
        to: 1100000,
      );
      const mine = 'APP_CRASH: {"time":1050000,"crashType":"NativeCrash"}\nstack';
      const older = 'APP_CRASH: {"time":900000}\nold stack';
      const freeze = 'APP_FREEZE: {"time":1099999}\nfrozen';
      expect(pick([older, mine, freeze]), '$mine\n\n$freeze');
      expect(pick([older]), isNull);
      // A stored exit line carries no time and belongs to no run in particular.
      expect(pick(['Previous process exit (3): Signal']), isNull);
    });

    test('fits an issue body however much was logged', () {
      final watch = Stopwatch()..start();
      final report = build(
        entries: [
          for (var i = 0; i < 200; i++)
            entry(LogLevel.error, 'Reader', 'error $i ${'y' * 3000}', i),
        ],
      );
      // Long unbroken tokens once made the scan quadratic.
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      expect(report.length, lessThan(65536));
      // The newest survive.
      expect(report, contains('error 199 '));
      expect(report, isNot(contains('error 0 ')));
      expect(report, contains('older entries left out)'));
    });
  });
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/native_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the exit reason HarmonyOS passes on is read back', () {
    expect(parseOhosExit('3\nSignal:SIGSEGV'), (
      reason: 3,
      message: 'Signal:SIGSEGV',
    ));
    expect(parseOhosExit('9\n'), (reason: 9, message: ''));
    expect(parseOhosExit('2'), (reason: 2, message: ''));
    // An older host, or one that could not tell.
    expect(parseOhosExit(null), isNull);
    expect(parseOhosExit(''), isNull);
    expect(parseOhosExit('unknown'), isNull);

    expect(
      describeOhosExit((reason: 3, message: 'Signal:SIGSEGV')),
      'CPP_CRASH (3): Signal:SIGSEGV',
    );
    expect(describeOhosExit((reason: 9, message: '')), 'USER_REQUEST (9)');
    expect(describeOhosExit((reason: 42, message: '')), 'UNKNOWN (42)');
  });

  test('HarmonyOS reasons settle a crash, an intended exit, or neither', () {
    // Not responding, native crash, script error, freeze.
    for (final reason in [1, 3, 4, 5]) {
      expect(ohosExitIsCrash(reason), isTrue, reason: '$reason');
    }
    // Normal exit, upgrade, ended by the user.
    for (final reason in [2, 8, 9]) {
      expect(ohosExitIsCrash(reason), isFalse, reason: '$reason');
    }
    // Unknown, or reclaimed by the system.
    for (final reason in [0, 6, 7, 10, 99]) {
      expect(ohosExitIsCrash(reason), isNull, reason: '$reason');
    }
  });

  test('what the Android host makes of the exit record is read back', () {
    expect(
      parseAndroidExit({
        'kind': 'crash',
        'name': 'CRASH_NATIVE',
        'reason': 5,
        'description': 'crash',
        'at': 1700000000000,
        'format': 'tombstone',
        'trace': null,
      }),
      (
        crashed: true,
        description: 'CRASH_NATIVE (5): crash',
        at: 1700000000000,
      ),
    );
    expect(
      parseAndroidExit({
        'kind': 'ended',
        'name': 'USER_REQUESTED',
        'reason': 10,
        'description': '',
        'at': 5,
      }),
      (crashed: false, description: 'USER_REQUESTED (10)', at: 5),
    );
    expect(
      parseAndroidExit({'kind': 'other', 'name': 'LOW_MEMORY', 'reason': 3}),
      (crashed: null, description: 'LOW_MEMORY (3)', at: null),
    );
    // Before Android 11, or nothing on record.
    expect(parseAndroidExit(null), isNull);
  });

  group('an uncaught Java exception the app recorded', () {
    const uncaught =
        'time=1700000000400\n'
        'reason=java.lang.IllegalStateException: no view\n'
        'thread=main\n'
        'java.lang.IllegalStateException: no view\n'
        '\tat io.github.kyosee.venera.MainActivity.onCreate(MainActivity.kt:1)\n';
    Map<String, Object?> systemRecord(String name, int reason, int at) => {
      'kind': 'crash',
      'name': name,
      'reason': reason,
      'description': 'crash',
      'at': at,
      'format': 'text',
      'trace': null,
    };

    test('gives the Java crash the system recorded its reason and stack', () {
      expect(
        parseAndroidRecords({
          ...systemRecord('CRASH', 4, 1700000000900),
          'uncaught': uncaught,
        }),
        (
          exit: (
            crashed: true,
            description: 'CRASH (4): java.lang.IllegalStateException: no view',
            at: 1700000000900,
          ),
          trace: uncaught,
        ),
      );
      // Either may be noted first.
      expect(
        parseAndroidRecords({
          ...systemRecord('CRASH', 4, 1699999991000),
          'uncaught': uncaught,
        }).trace,
        uncaught,
      );
    });

    test('is the whole account where the system keeps no exit record', () {
      expect(parseAndroidRecords({'uncaught': uncaught}), (
        exit: (
          crashed: true,
          description: 'java.lang.IllegalStateException: no view',
          at: 1700000000400,
        ),
        trace: uncaught,
      ));
    });

    test('is ignored when it is not about the exit the system recorded', () {
      final plain = (
        exit: (
          crashed: true,
          description: 'CRASH (4): crash',
          at: 1700000020000,
        ),
        trace: null,
      );
      // Left over from an earlier process.
      expect(
        parseAndroidRecords({
          ...systemRecord('CRASH', 4, 1700000020000),
          'uncaught': uncaught,
        }),
        plain,
      );
      // The process died some other way at about the same time.
      expect(
        parseAndroidRecords({
          ...systemRecord('CRASH_NATIVE', 5, 1700000000900),
          'uncaught': uncaught,
        }),
        (
          exit: (
            crashed: true,
            description: 'CRASH_NATIVE (5): crash',
            at: 1700000000900,
          ),
          trace: null,
        ),
      );
      // A system record without a time cannot be matched.
      expect(
        parseAndroidRecords({
          ...systemRecord('CRASH', 4, 0)..remove('at'),
          'uncaught': uncaught,
        }).trace,
        isNull,
      );
    });

    test('is ignored when it cannot be read', () {
      const unreadable = [
        '',
        'garbage',
        // Torn off before the reason.
        'time=1700000000400\n',
        // No time to tie it to a process.
        'reason=java.lang.IllegalStateException\nthread=main\n',
        'time=soon\nreason=java.lang.IllegalStateException\n',
      ];
      for (final text in unreadable) {
        expect(parseAndroidRecords({'uncaught': text}), (
          exit: null,
          trace: null,
        ), reason: text);
        expect(
          parseAndroidRecords({
            ...systemRecord('CRASH', 4, 1700000000900),
            'uncaught': text,
          }),
          (
            exit: (
              crashed: true,
              description: 'CRASH (4): crash',
              at: 1700000000900,
            ),
            trace: null,
          ),
          reason: text,
        );
      }
      expect(parseAndroidRecords({'uncaught': 42}), (exit: null, trace: null));
      // Nothing on record at all, or an older host.
      expect(parseAndroidRecords(null), (exit: null, trace: null));
      expect(
        parseAndroidRecords(systemRecord('CRASH', 4, 1700000000900)).exit,
        parseAndroidExit(systemRecord('CRASH', 4, 1700000000900)),
      );
    });

    test('is the crash trace unless the system has one of its own', () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('venera/method_channel');
      Uint8List? systemTrace;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readLastExit');
        if (call.arguments['trace'] == true) {
          return {
            ...systemRecord('CRASH', 4, 1700000000900),
            'trace': systemTrace,
          };
        }
        return {
          ...systemRecord('CRASH', 4, 1700000000900),
          'uncaught': uncaught,
        };
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final exit = await readOsExit();
      expect(exit?.description, startsWith('CRASH (4): java.lang.'));
      expect(await readOsExitTrace(), uncaught);
      systemTrace = Uint8List.fromList('system trace'.codeUnits);
      expect(await readOsExitTrace(), 'system trace');
    });
  });

  test(
    'native crash stacks reach logs without truncation or repeated resume entries',
    () async {
      final message = 'NativeCrash: ${'frame\n' * 1500}';
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('venera/method_channel'),
        (call) async {
          expect(call.method, 'readNativeDiagnostics');
          return [message];
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('venera/method_channel'),
          null,
        ),
      );
      await readOhosNativeDiagnostics();
      final reports = Log.logs
          .where((entry) => entry.title == 'HarmonyOS native diagnostics')
          .toList();
      expect(reports.map((entry) => entry.content).join(), message);
      await readOhosNativeDiagnostics();
      expect(
        Log.logs
            .where((entry) => entry.title == 'HarmonyOS native diagnostics')
            .length,
        reports.length,
      );
    },
  );
}

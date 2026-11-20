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

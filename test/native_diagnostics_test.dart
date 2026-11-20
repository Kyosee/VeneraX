import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/native_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the exit reason the host passes on is read back', () {
    expect(parseOsExit('3\nSignal:SIGSEGV'), (
      reason: 3,
      message: 'Signal:SIGSEGV',
    ));
    expect(parseOsExit('9\n'), (reason: 9, message: ''));
    expect(parseOsExit('2'), (reason: 2, message: ''));
    // An older host, or one that could not tell.
    expect(parseOsExit(null), isNull);
    expect(parseOsExit(''), isNull);
    expect(parseOsExit('unknown'), isNull);

    expect(
      describeOsExit((reason: 3, message: 'Signal:SIGSEGV')),
      'CPP_CRASH (3): Signal:SIGSEGV',
    );
    expect(describeOsExit((reason: 9, message: '')), 'USER_REQUEST (9)');
    expect(describeOsExit((reason: 42, message: '')), 'UNKNOWN (42)');
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

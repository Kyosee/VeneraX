import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/native_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

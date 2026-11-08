import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  const channel = MethodChannel('plugins.flutter.io/local_auth');
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  for (final scenario in ['unsupported', 'exception', 'cancelled', 'success']) {
    testWidgets('biometric lock fails closed: $scenario', (tester) async {
      appdata.settings['appLockType'] = 'biometric';
      var unlocked = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'stopAuthentication') return true;
        if (scenario == 'exception') {
          throw PlatformException(code: 'unavailable');
        }
        if (call.method == 'getAvailableBiometrics') return <String>[];
        if (call.method == 'isDeviceSupported') {
          return scenario != 'unsupported';
        }
        if (call.method == 'authenticate') return scenario == 'success';
        throw StateError('Unexpected authentication method: ${call.method}');
      });
      await tester.pumpWidget(
        MaterialApp(home: AuthPage(onSuccessfulAuth: () => unlocked++)),
      );
      await tester.pumpAndSettle();
      expect(unlocked, scenario == 'success' ? 1 : 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'duplicate prompts and late success cannot unlock a disposed page',
    (tester) async {
      appdata.settings['appLockType'] = 'biometric';
      final response = Completer<bool>();
      var attempts = 0;
      var unlocked = 0;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'getAvailableBiometrics') return ['fingerprint'];
        if (call.method == 'isDeviceSupported') return true;
        if (call.method == 'stopAuthentication') return true;
        if (call.method == 'authenticate') {
          attempts++;
          return response.future;
        }
        throw StateError('Unexpected authentication method: ${call.method}');
      });
      await tester.pumpWidget(
        MaterialApp(home: AuthPage(onSuccessfulAuth: () => unlocked++)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      expect(attempts, 1);
      await tester.pumpWidget(const SizedBox());
      response.complete(true);
      await tester.pumpAndSettle();
      expect(unlocked, 0);
      expect(tester.takeException(), isNull);
    },
  );
}

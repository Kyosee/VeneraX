import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart' show App;
import 'package:venera/pages/settings/sync_config_qr.dart';
import 'package:venera/utils/sync_config_transfer.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ohos = TargetPlatform.values.where(
    (platform) => platform.name == 'ohos',
  );
  const channel = MethodChannel('venera/scan');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const payload = SyncConfigPayload(
    url: 'https://example.test/dav/',
    user: 'fixture',
    pass: 'fixture-password',
    autoSync: false,
    disableSyncFields: '',
  );
  const pin = '123456';
  late String uri;

  group(
    'HarmonyOS sync QR import',
    () {
      setUpAll(() async {
        await AppTranslation.init();
        uri = encodeSyncConfigToUri(payload, pin);
      });
      tearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      });

      void testScanWidgets(String description, WidgetTesterCallback callback) {
        testWidgets(description, (tester) async {
          debugDefaultTargetPlatformOverride = ohos.single;
          try {
            expect(App.isOhos, isTrue);
            await callback(tester);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }

      Future<Completer<SyncConfigPayload?>> open(
        WidgetTester tester,
        Future<Object?> Function(MethodCall)? handler,
      ) async {
        messenger.setMockMethodCallHandler(channel, handler);
        final done = Completer<SyncConfigPayload?>();
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => OverlayWidget(child!),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async =>
                      done.complete(await scanAndDecodeSyncConfig(context)),
                  child: const Text('scan'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('scan'));
        await tester.pumpAndSettle();
        expect(find.byType(MobileScanner), findsNothing);
        return done;
      }

      Future<void> clearToast(WidgetTester tester) async {
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      testScanWidgets('cancellation does not prompt for a PIN', (tester) async {
        final calls = <String>[];
        final done = await open(tester, (call) async {
          calls.add(call.method);
          expect(call.arguments, isNull);
          return null;
        });
        expect(calls, ['scan']);
        expect(await done.future, isNull);
        expect(find.text('Enter PIN'.tl), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testScanWidgets(
        'valid QR still requires the PIN and returns the decrypted payload',
        (tester) async {
          final done = await open(tester, (_) async => uri);
          expect(done.isCompleted, isFalse);
          expect(find.text('Enter PIN'.tl), findsOneWidget);
          await tester.enterText(find.byType(TextField), pin);
          await tester.tap(find.text('Confirm'.tl));
          await tester.pumpAndSettle();
          expect((await done.future)?.toJson(), payload.toJson());
          expect(tester.takeException(), isNull);
        },
      );

      testScanWidgets(
        'wrong PIN retains the existing authenticated-decryption error',
        (tester) async {
          final done = await open(tester, (_) async => uri);
          await tester.enterText(find.byType(TextField), '654321');
          await tester.tap(find.text('Confirm'.tl));
          await tester.pumpAndSettle();
          expect(await done.future, isNull);
          expect(
            find.text('Wrong PIN, or the QR code was altered'.tl),
            findsOneWidget,
          );
          await clearToast(tester);
        },
      );

      testScanWidgets('foreign QR is rejected before requesting a PIN', (
        tester,
      ) async {
        final done = await open(tester, (_) async => 'https://example.test/');
        expect(await done.future, isNull);
        expect(find.text('Enter PIN'.tl), findsNothing);
        expect(find.text('Not a sync config QR code'.tl), findsOneWidget);
        await clearToast(tester);
      });

      for (final value in <Object>[
        123,
        '',
        '  ',
        'venera://sync?d=${'x' * 16384}',
      ]) {
        testScanWidgets(
          'malformed native result is rejected (${value.runtimeType}, ${value.toString().length})',
          (tester) async {
            final done = await open(tester, (_) async => value);
            expect(await done.future, isNull);
            expect(find.text('Enter PIN'.tl), findsNothing);
            expect(
              find.text('The QR code is damaged or invalid'.tl),
              findsOneWidget,
            );
            await clearToast(tester);
          },
        );
      }

      testScanWidgets(
        'native validation failure uses the existing invalid-QR message',
        (tester) async {
          final done = await open(tester, (_) async {
            throw PlatformException(code: 'SCAN_INVALID_RESULT');
          });
          expect(await done.future, isNull);
          expect(
            find.text('The QR code is damaged or invalid'.tl),
            findsOneWidget,
          );
          await clearToast(tester);
        },
      );

      testScanWidgets(
        'native failure does not reveal the error message or QR contents',
        (tester) async {
          final done = await open(tester, (_) async {
            throw PlatformException(
              code: 'SCAN_UNAVAILABLE',
              message: 'private QR contents',
            );
          });
          expect(await done.future, isNull);
          expect(find.text('Camera unavailable'.tl), findsOneWidget);
          expect(find.textContaining('private QR contents'), findsNothing);
          await clearToast(tester);
        },
      );

      testScanWidgets('missing native bridge fails gracefully', (tester) async {
        final done = await open(tester, (_) async {
          throw MissingPluginException('Scan bridge unavailable');
        });
        expect(await done.future, isNull);
        expect(find.text('Camera unavailable'.tl), findsOneWidget);
        await clearToast(tester);
      });

      testScanWidgets(
        'a late native result does not open a PIN dialog after unmount',
        (tester) async {
          final pending = Completer<Object?>();
          final done = await open(tester, (_) => pending.future);
          await tester.pumpWidget(const SizedBox.shrink());
          pending.complete(uri);
          await tester.pumpAndSettle();
          expect(await done.future, isNull);
          expect(find.text('Enter PIN'.tl), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    },
    skip: ohos.isEmpty ? 'Requires the HarmonyOS Flutter SDK.' : false,
  );
}

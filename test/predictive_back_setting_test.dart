import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_page_route.dart';
import 'package:venera/foundation/appdata.dart';

/// Regression test for #194.
///
/// Android pages normally animate along with the system back gesture. Some
/// systems force that gesture on while shipping no animation of their own, so
/// the setting turns the effect off. With it off no route may claim the
/// gesture — that is what makes the framework fall back to a plain pop on
/// release instead of leaving the page frozen mid-drag.
void main() {
  tearDown(() {
    appdata.settings['enablePredictiveBack'] = true;
  });

  Future<bool> startBackGesture(WidgetTester tester) async {
    ByteData? reply;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('startBackGesture', <String, dynamic>{
          'touchOffset': <double>[5.0, 300.0],
          'progress': 0.0,
          'swipeEdge': 0, // left
        }),
      ),
      (ByteData? data) => reply = data,
    );
    return const StandardMethodCodec().decodeEnvelope(reply!) as bool;
  }

  Future<void> pumpPushedRoute(WidgetTester tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        home: const Scaffold(body: Text('home')),
      ),
    );
    navigatorKey.currentState!.push(
      AppPageRoute<void>(builder: (_) => const Scaffold(body: Text('pushed'))),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the pushed page takes over the back gesture by default',
    (tester) async {
      appdata.settings['enablePredictiveBack'] = true;
      await pumpPushedRoute(tester);

      expect(await startBackGesture(tester), isTrue);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'the back gesture is left to a plain pop when turned off (#194)',
    (tester) async {
      appdata.settings['enablePredictiveBack'] = false;
      await pumpPushedRoute(tester);

      expect(await startBackGesture(tester), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';

/// Regression test for #101.
///
/// On Android the system back gesture used to pop twice when a route on the
/// root navigator (the reader) was stacked above a route living in the nested
/// "main" navigator (the comic-details page): a single back skipped the detail
/// page entirely. The buried nested-navigator route must opt out of the
/// predictive back gesture (via [PageRoute.popGestureEnabled], the value the
/// predictive-back observer reads) so only the top (root) route pops.
///
/// [popGestureEnabled] is platform-independent, so this test asserts on it
/// directly without overriding the target platform.
void main() {
  testWidgets(
    'nested-navigator route disables Android back gesture when buried under a '
    'root route (#101)',
    (tester) async {
      final innerKey = GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: Navigator(
            key: innerKey,
            onGenerateRoute: (_) => AppPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('inner-home')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Push a detail route onto the nested navigator.
      final detailRoute = AppPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('detail')),
      );
      innerKey.currentState!.push(detailRoute);
      await tester.pumpAndSettle();

      // Nothing is stacked above the host on the root navigator yet, so the
      // detail route may still own the back gesture.
      expect(detailRoute.popGestureEnabled, isTrue);

      // Push a "reader"-like route onto the ROOT navigator, burying the detail
      // route beneath it.
      final readerRoute = AppPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('reader')),
      );
      App.rootNavigatorKey.currentState!.push(readerRoute);
      await tester.pumpAndSettle();

      // The buried detail route must NOT respond to the system back gesture,
      // otherwise a single back would pop both the reader and the detail page.
      expect(detailRoute.popGestureEnabled, isFalse);
      // The reader route (top of the root navigator) still responds normally.
      expect(readerRoute.popGestureEnabled, isTrue);
    },
  );
}

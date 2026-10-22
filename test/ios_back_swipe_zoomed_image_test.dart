import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_page_route.dart';

/// Regression test for #310.
///
/// On iOS a right swipe anywhere on the reader pops it. Once the image is
/// zoomed, a right drag pans the image instead, so the back swipe must fall
/// back to the screen's left edge — also when the zoom began after the finger
/// went down (long-press zoom).
void main() {
  var starts = 0;
  var zoomed = false;

  Widget buildDetector({bool Function()? active}) {
    return MaterialApp(
      home: IOSBackGestureDetector(
        gestureWidth: 20,
        // Only called once the recognizer has claimed the drag; returning false
        // leaves the route alone.
        enabledCallback: () {
          starts++;
          return false;
        },
        onStartPopGesture: () => throw StateError('unreachable'),
        child: SwipeRegionMarker(
          active: active,
          child: const ColoredBox(
            color: Colors.white,
            child: SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  setUp(() {
    starts = 0;
    zoomed = false;
  });

  testWidgets('mid-page right swipe starts the back gesture when not zoomed', (
    tester,
  ) async {
    await tester.pumpWidget(buildDetector(active: () => zoomed));
    await tester.dragFrom(const Offset(300, 300), const Offset(150, 0));
    await tester.pump();
    expect(starts, 1);
  });

  testWidgets('mid-page right swipe on a zoomed image does not go back', (
    tester,
  ) async {
    zoomed = true;
    await tester.pumpWidget(buildDetector(active: () => zoomed));
    await tester.dragFrom(const Offset(300, 300), const Offset(150, 0));
    await tester.pump();
    expect(starts, 0);
  });

  testWidgets('left-edge swipe still goes back while zoomed', (tester) async {
    zoomed = true;
    await tester.pumpWidget(buildDetector(active: () => zoomed));
    await tester.dragFrom(const Offset(5, 300), const Offset(150, 0));
    await tester.pump();
    expect(starts, 1);
  });

  testWidgets('zoom that starts after pointer down is honored', (
    tester,
  ) async {
    await tester.pumpWidget(buildDetector(active: () => zoomed));
    final gesture = await tester.startGesture(const Offset(300, 300));
    // Long-press zoom kicks in while the finger is still resting.
    zoomed = true;
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pump();
    expect(starts, 0);
  });

  testWidgets('marker without a predicate always claims horizontal drags', (
    tester,
  ) async {
    await tester.pumpWidget(buildDetector());
    await tester.dragFrom(const Offset(300, 300), const Offset(150, 0));
    await tester.pump();
    expect(starts, 0);
  });
}

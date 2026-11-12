import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_page_route.dart';

// Route navigation is exercised by reader_back_swipe_test.dart.
class _TestBackGestureController implements IOSBackGestureController {
  @override
  AnimationController get controller => throw UnimplementedError();

  @override
  NavigatorState get navigator => throw UnimplementedError();

  @override
  void dragUpdate(double delta) {}

  @override
  void dragEnd(double velocity) {}
}

/// Regression test for #310.
///
/// On iOS a right swipe anywhere on the reader pops it. Once the image is
/// zoomed, a right drag pans the image instead, so the back swipe must fall
/// back to the screen's left edge — also when the zoom began after the finger
/// went down (long-press zoom).
void main() {
  var starts = 0;
  var zoomed = false;
  var enabled = true;

  Widget buildDetector({bool Function()? active, Widget? child}) {
    return MaterialApp(
      home: IOSBackGestureDetector(
        gestureWidth: 20,
        enabledCallback: () => enabled,
        onStartPopGesture: () {
          starts++;
          return _TestBackGestureController();
        },
        child: SwipeRegionMarker(
          active: active,
          child:
              child ??
              const ColoredBox(color: Colors.white, child: SizedBox.expand()),
        ),
      ),
    );
  }

  setUp(() {
    starts = 0;
    zoomed = false;
    enabled = true;
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

  testWidgets('a diagonal back fling reports a horizontal end velocity', (
    tester,
  ) async {
    await tester.pumpWidget(buildDetector(active: () => false));
    await tester.flingFrom(const Offset(300, 300), const Offset(180, 30), 2500);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(starts, 1);
  });

  testWidgets('a pointer already claimed by a child cannot start going back', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildDetector(
        active: () => false,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            EagerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                  EagerGestureRecognizer.new,
                  (_) {},
                ),
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(300, 300));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(40, 0));
    await gesture.up();
    await tester.pump();
    expect(starts, 0);
  });

  testWidgets('another finger does not replace an active back swipe', (
    tester,
  ) async {
    await tester.pumpWidget(buildDetector(active: () => false));
    final first = await tester.startGesture(const Offset(300, 300));
    await first.moveBy(const Offset(40, 0));
    expect(starts, 1);

    final second = await tester.startGesture(const Offset(250, 300));
    await second.moveBy(const Offset(40, 0));
    await second.up();
    await first.moveBy(const Offset(40, 0));
    await first.up();
    await tester.pump();
    expect(starts, 1);
    expect(tester.takeException(), isNull);
  });

  for (final canGoBack in [true, false]) {
    testWidgets('fast edge swipes honor back availability: $canGoBack', (
      tester,
    ) async {
      enabled = canGoBack;
      var childUpdates = 0;
      await tester.pumpWidget(
        buildDetector(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (_) => childUpdates++,
            child: const SizedBox.expand(),
          ),
        ),
      );
      final gesture = await tester.startGesture(const Offset(5, 300));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.up();
      await tester.pump();
      expect(starts, canGoBack ? 1 : 0);
      expect(childUpdates, canGoBack ? 0 : greaterThan(0));
    });
  }

  testWidgets('edge taps and vertical drags still reach the child', (
    tester,
  ) async {
    var taps = 0;
    var verticalUpdates = 0;
    await tester.pumpWidget(
      buildDetector(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => taps++,
          onVerticalDragUpdate: (_) => verticalUpdates++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.tapAt(const Offset(5, 300));
    await tester.dragFrom(const Offset(5, 300), const Offset(0, 100));
    await tester.pump();
    expect(taps, 1);
    expect(verticalUpdates, greaterThan(0));
    expect(starts, 0);
  });
}

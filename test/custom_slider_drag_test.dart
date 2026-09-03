import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/custom_slider.dart';

void main() {
  const pages = 244;

  Future<List<double>> pumpSlider(
    WidgetTester tester, {
    bool reversed = false,
  }) async {
    final changes = <double>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: CustomSlider(
                min: 1,
                max: pages.toDouble(),
                value: 78,
                divisions: pages - 1,
                reversed: reversed,
                focusNode: null,
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      ),
    );
    return changes;
  }

  // Drags from the slider's center: the first move only gets the gesture
  // recognized, the second lands inside the track, the last ones run past
  // the given edge onto the neighbouring buttons before the finger lifts.
  Future<void> dragPastEdge(
    WidgetTester tester, {
    required bool toRight,
  }) async {
    final center = tester.getCenter(find.byType(CustomSlider));
    final direction = toRight ? 1.0 : -1.0;
    final gesture = await tester.startGesture(center);
    await gesture.moveTo(center + Offset(30 * direction, 0));
    await tester.pump();
    await gesture.moveTo(center + Offset(60 * direction, 0));
    await tester.pump();
    await gesture.moveTo(center + Offset(400 * direction, 0));
    await tester.pump();
    await gesture.moveTo(center + Offset(410 * direction, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  testWidgets('dragging past the right edge lands on the last page', (
    tester,
  ) async {
    final changes = await pumpSlider(tester);
    await dragPastEdge(tester, toRight: true);
    expect(changes.length, greaterThanOrEqualTo(2));
    expect(changes.last, pages.toDouble());
  });

  testWidgets('dragging past the left edge lands on the first page', (
    tester,
  ) async {
    final changes = await pumpSlider(tester);
    await dragPastEdge(tester, toRight: false);
    expect(changes.length, greaterThanOrEqualTo(2));
    expect(changes.last, 1.0);
  });

  testWidgets('reversed slider maps the left edge to the last page', (
    tester,
  ) async {
    final changes = await pumpSlider(tester, reversed: true);
    await dragPastEdge(tester, toRight: false);
    expect(changes.length, greaterThanOrEqualTo(2));
    expect(changes.last, pages.toDouble());
  });

  testWidgets('holding the finger past the edge reports the end page once', (
    tester,
  ) async {
    final changes = await pumpSlider(tester);
    await dragPastEdge(tester, toRight: true);
    expect(changes.where((v) => v == pages.toDouble()).length, 1);
  });

  testWidgets('a later drag can reach the same end page again', (
    tester,
  ) async {
    final changes = await pumpSlider(tester);
    await dragPastEdge(tester, toRight: true);
    await dragPastEdge(tester, toRight: false);
    await dragPastEdge(tester, toRight: true);
    expect(changes.where((v) => v == pages.toDouble()).length, 2);
    expect(changes.last, pages.toDouble());
  });
}

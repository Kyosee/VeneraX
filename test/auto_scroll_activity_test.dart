import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/auto_scroll_activity.dart';

void main() {
  late ScrollController controller;
  late List<Type> notifications;
  late int taps;

  Widget list() => MaterialApp(
    home: NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n is! ScrollUpdateNotification) notifications.add(n.runtimeType);
        return false;
      },
      child: ListView.builder(
        controller: controller,
        itemCount: 100,
        itemBuilder: (_, i) => GestureDetector(
          onTap: () => taps++,
          child: SizedBox(height: 100, child: Text('$i')),
        ),
      ),
    ),
  );

  AutoScrollActivity start(
    double? Function(double seconds) nextPixels, {
    VoidCallback? onDispose,
  }) {
    final position = controller.position as ScrollPositionWithSingleContext;
    final activity = AutoScrollActivity(
      position,
      vsync: position.context.vsync,
      nextPixels: nextPixels,
      onDispose: onDispose ?? () {},
    );
    position.beginActivity(activity);
    return activity;
  }

  setUp(() {
    controller = ScrollController();
    notifications = [];
    taps = 0;
  });

  tearDown(() => controller.dispose());

  testWidgets('moves every frame inside one start/end pair', (tester) async {
    await tester.pumpWidget(list());
    var total = 0.0;
    var stop = false;
    var disposed = false;
    start((seconds) {
      if (stop) return null;
      total += seconds;
      return 100 * total;
    }, onDispose: () => disposed = true);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(total, greaterThan(0.4));
    expect(controller.offset, closeTo(100 * total, 1e-6));

    stop = true;
    await tester.pump(const Duration(milliseconds: 16));
    expect(disposed, isTrue);
    expect(notifications, [ScrollStartNotification, ScrollEndNotification]);
  });

  testWidgets('a drag takes over from it', (tester) async {
    await tester.pumpWidget(list());
    var disposed = false;
    start(
      (seconds) => controller.offset + 50 * seconds,
      onDispose: () => disposed = true,
    );
    await tester.pump(const Duration(milliseconds: 100));
    final before = controller.offset;
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(disposed, isTrue);
    expect(controller.offset, greaterThan(before + 200));
  });

  testWidgets('taps reach the page while it runs', (tester) async {
    await tester.pumpWidget(list());
    var stop = false;
    start((seconds) => stop ? null : controller.offset + 50 * seconds);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('3'));
    expect(taps, 1);
    stop = true;
    await tester.pumpAndSettle();
  });
}

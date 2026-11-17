import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/rotation_transition.dart';

class _Scene extends StatefulWidget {
  const _Scene();

  @override
  State<_Scene> createState() => _SceneState();
}

class _SceneState extends State<_Scene> {
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: MediaQuery.orientationOf(context) == Orientation.landscape
        ? Colors.red
        : Colors.blue,
    child: const Center(
      child: SizedBox.square(
        dimension: 60,
        child: ColoredBox(color: Colors.green),
      ),
    ),
  );
}

void main() {
  const frameKey = ValueKey('frame');

  Widget host(
    WidgetTester tester, {
    bool enabled = true,
    bool reduceMotion = false,
    bool offstage = false,
  }) => MediaQuery.fromView(
    view: tester.view,
    child: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Offstage(
            offstage: offstage,
            child: RepaintBoundary(
              key: frameKey,
              child: ReaderRotationTransition(
                enabled: enabled,
                backgroundColor: Colors.black,
                child: const _Scene(),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  void setupView(WidgetTester tester) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(300, 200);
    addTearDown(tester.view.reset);
  }

  Future<List<int>> pixels(WidgetTester tester, List<Offset> points) async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(frameKey),
    );
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return points.map((point) {
          final i = (point.dy.toInt() * image.width + point.dx.toInt()) * 4;
          return Color.fromARGB(
            data.getUint8(i + 3),
            data.getUint8(i),
            data.getUint8(i + 1),
            data.getUint8(i + 2),
          ).toARGB32();
        }).toList();
      } finally {
        image.dispose();
      }
    }))!;
  }

  testWidgets('rotation contains the old frame and crossfades to the new one', (
    tester,
  ) async {
    setupView(tester);
    await tester.pumpWidget(host(tester));
    final state = tester.state(find.byType(_Scene));
    tester.view.physicalSize = const Size(200, 300);
    await tester.pump();
    final snapshot = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(snapshot.width, 300);
    expect(snapshot.height, 200);
    expect(
      await pixels(tester, const [
        Offset(10, 10),
        Offset(10, 150),
        Offset(100, 150),
        Offset(118, 150),
        Offset(130, 150),
        Offset(100, 168),
        Offset(100, 180),
      ]),
      [
        Colors.black,
        Colors.red,
        Colors.green,
        Colors.green,
        Colors.red,
        Colors.green,
        Colors.red,
      ].map((color) => color.toARGB32()).toList(),
    );
    await tester.pump(const Duration(milliseconds: 80));
    final middle = Color(
      (await pixels(tester, const [Offset(10, 150)])).single,
    );
    expect(middle.r, closeTo((Colors.red.r + Colors.blue.r) / 2, 0.01));
    expect(middle.b, closeTo((Colors.red.b + Colors.blue.b) / 2, 0.01));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(RawImage), findsNothing);
    expect(snapshot.debugDisposed, isTrue);
    expect(await pixels(tester, const [Offset(10, 150)]), [
      Colors.blue.toARGB32(),
    ]);
    expect(tester.state(find.byType(_Scene)), same(state));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid rotation replaces snapshots and exit releases them', (
    tester,
  ) async {
    setupView(tester);
    await tester.pumpWidget(host(tester));
    tester.view.physicalSize = const Size(200, 300);
    await tester.pump();
    final first = tester.widget<RawImage>(find.byType(RawImage)).image!;
    await tester.pump(const Duration(milliseconds: 32));
    tester.view.physicalSize = const Size(300, 200);
    await tester.pump();
    final second = tester.widget<RawImage>(find.byType(RawImage)).image!;
    expect(first.debugDisposed, isTrue);
    expect(second.width, 200);
    expect(second.height, 300);
    await tester.pumpWidget(const SizedBox());
    expect(second.debugDisposed, isTrue);
    tester.view.physicalSize = const Size(200, 300);
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull);
  });

  testWidgets('resize and keyboard metrics do not start a transition', (
    tester,
  ) async {
    setupView(tester);
    await tester.pumpWidget(host(tester));
    tester.view.physicalSize = const Size(320, 200);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 100);
    await tester.pump();
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled, reduced motion and unpainted content skip capture', (
    tester,
  ) async {
    setupView(tester);
    for (final mode in ['disabled', 'reduced', 'unpainted']) {
      await tester.pumpWidget(const SizedBox());
      tester.view.physicalSize = const Size(300, 200);
      await tester.pumpWidget(
        host(
          tester,
          enabled: mode != 'disabled',
          reduceMotion: mode == 'reduced',
          offstage: mode == 'unpainted',
        ),
      );
      tester.view.physicalSize = const Size(200, 300);
      await tester.pump();
      expect(find.byType(RawImage, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('disabling animation mid-transition releases its snapshot', (
    tester,
  ) async {
    setupView(tester);
    for (final reducedMotion in [false, true]) {
      await tester.pumpWidget(host(tester));
      tester.view.physicalSize = const Size(200, 300);
      await tester.pump();
      final snapshot = tester.widget<RawImage>(find.byType(RawImage)).image!;
      await tester.pumpWidget(
        host(tester, enabled: reducedMotion, reduceMotion: reducedMotion),
      );
      expect(snapshot.debugDisposed, isTrue);
      expect(find.byType(RawImage), findsNothing);
      tester.view.physicalSize = const Size(300, 200);
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('transition is available on every Flutter target platform', (
    tester,
  ) async {
    setupView(tester);
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      await tester.pumpWidget(host(tester));
      final size = tester.view.physicalSize;
      tester.view.physicalSize = Size(size.height, size.width);
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget, reason: platform.name);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
    }
    debugDefaultTargetPlatformOverride = null;
  });
}

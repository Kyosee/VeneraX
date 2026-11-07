import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/app_slider_theme.dart';
import 'package:venera/components/custom_slider.dart';

void main() {
  testWidgets('settings and reader tracks repaint with the active theme', (
    tester,
  ) async {
    final capture = GlobalKey();
    for (final brightness in Brightness.values) {
      for (final seed in [Colors.red, Colors.green]) {
        final colors = ColorScheme.fromSeed(
          seedColor: seed,
          brightness: brightness,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              colorScheme: colors,
              sliderTheme: appSliderTheme(colors),
            ),
            home: Scaffold(
              body: RepaintBoundary(
                key: capture,
                child: SizedBox(
                  width: 320,
                  child: Column(
                    children: [
                      Slider(value: 0.8, onChanged: (_) {}),
                      CustomSlider(
                        min: 0,
                        max: 100,
                        value: 80,
                        divisions: 100,
                        onChanged: (_) {},
                        focusNode: null,
                      ),
                      const Slider(value: 0.8, onChanged: null),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!;
          for (var i = 0; i < 2; i++) {
            final point = boundary.globalToLocal(
              tester.getCenter(find.byType(Slider).at(i)),
            );
            final offset =
                (point.dy.floor() * image.width + point.dx.floor()) * 4;
            final red = bytes.getUint8(offset);
            final green = bytes.getUint8(offset + 1);
            expect(seed == Colors.red ? red > green : green > red, isTrue);
          }
          image.dispose();
        });
      }
    }
  });
}

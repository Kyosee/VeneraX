import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_enhance_shader.dart';
import 'package:venera/pages/settings/image_enhance_preview.dart';
import 'package:venera/utils/translations.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 320, child: child),
    ),
  ),
);

/// Lets real engine work (toImage, shader passes) finish, then flushes the
/// continuations it queued in the test zone.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
}

List<ui.Image?> _rawImages(WidgetTester tester) => [
  for (final w in tester.widgetList<RawImage>(find.byType(RawImage))) w.image,
];

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    await ImageEnhanceShader.instance.preload();
    appdata.settings['language'] = 'en-US';
  });

  setUp(() {
    appdata.settings['enableReaderImageEnhance'] = true;
    appdata.settings['readerImageEnhanceStrength'] = 0.5;
  });

  tearDown(() {
    appdata.settings['enableReaderImageEnhance'] = false;
    appdata.settings['readerImageEnhanceStrength'] = 0.5;
  });

  test('preview band is the centred 4:3 region of the page', () {
    expect(previewBandRect(1000, 1500), const Rect.fromLTWH(0, 375, 1000, 750));
    // A long strip only costs the shader a box-sized band.
    expect(previewBandRect(800, 12000), const Rect.fromLTWH(0, 5700, 800, 600));
    expect(previewBandRect(2000, 1000), const Rect.fromLTWH(333, 0, 1333, 1000));
    expect(previewBandRect(1200, 900), const Rect.fromLTWH(0, 0, 1200, 900));
  });

  test('preview band stays inside the page and never collapses', () {
    for (final (w, h) in [(1, 1), (1, 5000), (5000, 1), (3, 1), (7, 13)]) {
      final band = previewBandRect(w, h);
      expect(band.left, greaterThanOrEqualTo(0), reason: '$w x $h');
      expect(band.top, greaterThanOrEqualTo(0), reason: '$w x $h');
      expect(band.right, lessThanOrEqualTo(w), reason: '$w x $h');
      expect(band.bottom, lessThanOrEqualTo(h), reason: '$w x $h');
      expect(band.width, greaterThanOrEqualTo(1), reason: '$w x $h');
      expect(band.height, greaterThanOrEqualTo(1), reason: '$w x $h');
    }
  });

  testWidgets('crop and sample produce images of the expected size', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final source = await createTestImage(width: 40, height: 400);
      final band = await cropPreviewBand(source);
      expect((band.width, band.height), (40, 30));
      band.dispose();
      source.dispose();

      final sample = await renderEnhanceSample(const TextStyle());
      expect((sample.width, sample.height), (480, 360));
      sample.dispose();
    });
  });

  for (final (name, pageImage) in <(String, ImageInfo? Function()?)>[
    ('outside the reader', null),
    ('when the reader has no decoded page', () => null),
  ]) {
    testWidgets('falls back to the built-in sample $name', (tester) async {
      await tester.pumpWidget(_host(ImageEnhancePreview(pageImage: pageImage)));
      await _settle(tester);

      final images = _rawImages(tester);
      expect(images, hasLength(2));
      expect((images.first!.width, images.first!.height), (480, 360));
      expect(find.textContaining('Sample image'), findsOneWidget);
    });
  }

  testWidgets('owns the handed page and re-renders as settings change', (
    tester,
  ) async {
    final pixels = await tester.runAsync(
      () => createTestImage(width: 120, height: 200),
    );
    final page = ImageInfo(image: pixels!);
    await tester.pumpWidget(
      _host(ImageEnhancePreview(pageImage: () => page)),
    );
    await _settle(tester);

    // The page is copied into a box-sized band, then released.
    expect(page.image.debugDisposed, isTrue);
    final [original, enhanced] = _rawImages(tester);
    expect((original!.width, original.height), (120, 90));
    expect(enhanced, isNot(same(original)));
    expect(find.text('Drag to compare'), findsOneWidget);

    appdata.settings['readerImageEnhanceStrength'] = 3.0;
    await tester.pump();
    await _settle(tester);
    final updated = _rawImages(tester).last;
    expect(updated, isNot(same(enhanced)));
    expect(enhanced!.debugDisposed, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(original.debugDisposed, isTrue);
    expect(updated!.debugDisposed, isTrue);
  });
}

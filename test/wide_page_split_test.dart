import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/wide_page_split.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  group('WidePageSplit', () {
    test('reads the stored setting, unknown values as off', () {
      expect(WidePageSplit.fromSetting('rightFirst'), WidePageSplit.rightFirst);
      expect(WidePageSplit.fromSetting('leftFirst'), WidePageSplit.leftFirst);
      expect(WidePageSplit.fromSetting('off'), WidePageSplit.off);
      expect(WidePageSplit.fromSetting(null), WidePageSplit.off);
      expect(WidePageSplit.fromSetting(true), WidePageSplit.off);
    });

    test('cuts landscape pages only', () {
      const split = WidePageSplit.rightFirst;
      expect(split.appliesTo(const Size(1400, 1000)), isTrue);
      expect(split.appliesTo(const Size(1000, 1000)), isFalse);
      expect(split.appliesTo(const Size(800, 1200)), isFalse);
      expect(WidePageSplit.off.appliesTo(const Size(1400, 1000)), isFalse);
    });

    test('lays a cut page out as two stacked halves', () {
      expect(
        WidePageSplit.leftFirst.layoutSize(const Size(1400, 1000)),
        const Size(700, 2000),
      );
      expect(
        WidePageSplit.leftFirst.layoutSize(const Size(800, 1200)),
        const Size(800, 1200),
      );
      expect(
        WidePageSplit.off.layoutSize(const Size(1400, 1000)),
        const Size(1400, 1000),
      );
    });
  });

  group('ComicImage', () {
    const left = Color(0xFFFF0000);
    const right = Color(0xFF0000FF);
    // 200x100, the left half red and the right half blue.
    late ui.Image wide;
    late ui.Image tall;
    final boundaryKey = GlobalKey();

    setUpAll(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawRect(const Rect.fromLTWH(0, 0, 100, 100), Paint()..color = left)
        ..drawRect(
          const Rect.fromLTWH(100, 0, 100, 100),
          Paint()..color = right,
        );
      final picture = recorder.endRecording();
      wide = await picture.toImage(200, 100);
      picture.dispose();
      tall = await createTestImage(width: 100, height: 200);
    });

    Future<List<RawImage>> pump(
      WidgetTester tester,
      ui.Image image,
      WidePageSplit split, {
      double? width = double.infinity,
      double? height,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 200,
              height: width == double.infinity ? null : 200,
              child: RepaintBoundary(
                key: boundaryKey,
                child: ComicImage(
                  image: _ImmediateImage(image),
                  width: width,
                  height: height,
                  fit: BoxFit.contain,
                  widePageSplit: split,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.widgetList<RawImage>(find.byType(RawImage)).toList();
    }

    /// Colours at the middle of the top and the bottom half, as painted.
    Future<(Color, Color)> halves(WidgetTester tester) async {
      final result = await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = (await image.toByteData())!;
        Color at(int x, int y) {
          final i = (y * image.width + x) * 4;
          return Color.fromARGB(
            data.getUint8(i + 3),
            data.getUint8(i),
            data.getUint8(i + 1),
            data.getUint8(i + 2),
          );
        }

        final top = at(image.width ~/ 2, image.height ~/ 4);
        final bottom = at(image.width ~/ 2, image.height * 3 ~/ 4);
        image.dispose();
        return (top, bottom);
      });
      return result!;
    }

    testWidgets('stacks the right half above the left one', (tester) async {
      final images = await pump(tester, wide, WidePageSplit.rightFirst);

      expect(images, hasLength(2));
      expect(tester.getSize(find.byType(ComicImage)), const Size(200, 400));
      expect(await halves(tester), (right, left));
    });

    testWidgets('puts the left half on top when asked', (tester) async {
      await pump(tester, wide, WidePageSplit.leftFirst);

      expect(await halves(tester), (left, right));
    });

    testWidgets('leaves a portrait page whole', (tester) async {
      final images = await pump(tester, tall, WidePageSplit.rightFirst);

      expect(images, hasLength(1));
      expect(tester.getSize(find.byType(ComicImage)), const Size(200, 400));
    });

    testWidgets('leaves a landscape page whole when off', (tester) async {
      final images = await pump(tester, wide, WidePageSplit.off);

      expect(images, hasLength(1));
      expect(tester.getSize(find.byType(ComicImage)), const Size(200, 100));
    });

    testWidgets('never cuts along a horizontal strip', (tester) async {
      final images = await pump(
        tester,
        wide,
        WidePageSplit.rightFirst,
        width: null,
        height: double.infinity,
      );

      expect(images, hasLength(1));
    });
  });
}

/// Resolves synchronously to an already-decoded image. Identity equality keeps
/// every instance a separate cache entry.
class _ImmediateImage extends ImageProvider<_ImmediateImage> {
  _ImmediateImage(this.image);

  final ui.Image image;

  @override
  Future<_ImmediateImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _ImmediateImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(
    SynchronousFuture(ImageInfo(image: image.clone())),
  );
}

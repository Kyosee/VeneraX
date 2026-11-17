import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';

class _SameImage extends ImageProvider<int> {
  const _SameImage(this.completer);

  final ImageStreamCompleter completer;

  @override
  Future<int> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(1);

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    int key,
    ImageErrorListener handleError,
  ) {
    stream.setCompleter(completer);
  }
}

void main() {
  testWidgets('zoom reset uses the current viewport after rotation', (
    tester,
  ) async {
    final controller = PhotoViewController();
    Widget view(Size size) => Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox.fromSize(
          size: size,
          child: PhotoView.customChild(
            controller: controller,
            childSize: const Size(600, 300),
            child: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.pumpWidget(view(const Size(600, 300)));
    await tester.pump();
    expect(controller.getInitialScale!(), 1);
    await tester.pumpWidget(view(const Size(300, 600)));
    expect(controller.getInitialScale!(), 0.5);
    expect(controller.scale, 0.5);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets(
    'resolved image survives provider replacement and viewport resize',
    (tester) async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xff00ff00), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await tester.runAsync(() => picture.toImage(600, 300));
      picture.dispose();
      final completer = OneFrameImageStreamCompleter(
        SynchronousFuture(ImageInfo(image: image!.clone())),
      );
      final sourceHandle = completer.keepAlive();
      Widget view(Size size) => MediaQuery(
        data: MediaQueryData(size: size),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: PhotoView(
            imageProvider: _SameImage(completer),
            loadingBuilder: (_, _) => const Text('Loading'),
          ),
        ),
      );
      try {
        await tester.pumpWidget(view(const Size(900, 600)));
        await tester.pump();
        expect(find.byType(RawImage), findsOneWidget);
        await tester.pumpWidget(view(const Size(600, 900)));
        expect(find.text('Loading'), findsNothing);
        expect(find.byType(RawImage), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        sourceHandle.dispose();
        await tester.pump();
        final handles = image.debugGetOpenHandleStackTraces()!.length;
        image.dispose();
        expect(
          handles,
          1,
          reason: 'Every stream listener must release its image handle',
        );
      }
    },
  );
}

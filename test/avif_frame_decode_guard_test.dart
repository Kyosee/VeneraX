import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_provider/avif_fallback.dart';
import 'package:venera/foundation/image_provider/base_image_provider.dart';

import 'fixtures/avif_page.dart';

/// Bytes whose header parses but whose pixels do not decode reach the framework
/// as a working codec; only `getNextFrame()` fails, and the framework reports
/// that straight to `FlutterError`. A provider that wraps `decode()` therefore
/// never learns the load failed, which is why the URL was never recorded and
/// every later attempt replayed the same broken request.
class _Provider extends BaseImageProvider<_Provider> {
  const _Provider(this.url, this.bytes);

  final String url;
  final Uint8List bytes;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async => bytes;

  @override
  Future<_Provider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  String get key => url;

  @override
  String? get fallbackUrl => url;

  @override
  Future<void> evictCorruptedCache() async => evicted = true;

  static bool evicted = false;
}

/// A codec that mimics the engine: it is constructed successfully and only
/// fails once a frame is pulled.
class _FailingCodec implements ui.Codec {
  @override
  int get frameCount => 1;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() async =>
      throw Exception('Could not decompress image.');

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _Provider.evicted = false;
    AvifFallbackRegistry.instance.clear();
  });
  tearDown(AvifFallbackRegistry.instance.clear);

  const url = 'https://img.example.invalid/p/001.avif';

  for (final failsAtHeader in [true, false]) {
    test(
      'renders AVIF when the native ${failsAtHeader ? 'header' : 'frame'} decoder fails',
      () async {
        final provider = _Provider(url, avifPageBytes());
        final stream = provider.loadImage(provider, (
          buffer, {
          getTargetSize,
        }) async {
          buffer.dispose();
          if (failsAtHeader) throw StateError('Unsupported format');
          return _FailingCodec();
        });
        final ready = Completer<ImageInfo>();
        final listener = ImageStreamListener(
          (info, _) => ready.complete(info),
          onError: ready.completeError,
        );
        stream.addListener(listener);
        try {
          final info = await ready.future;
          try {
            expect(info.image.width, 16);
            expect(info.image.height, 8);
            final pixels = (await info.image.toByteData(
              format: ui.ImageByteFormat.rawStraightRgba,
            ))!;
            expect(pixels.getUint8(4 * 2), greaterThan(230));
            expect(pixels.getUint8(4 * 13 + 2), greaterThan(230));
            expect(AvifFallbackRegistry.instance.hasFailed(url), isFalse);
            expect(_Provider.evicted, isFalse);
          } finally {
            info.dispose();
          }
        } finally {
          stream.removeListener(listener);
        }
      },
    );
  }

  test('a frame-decode failure records the url and drops the cache', () async {
    final provider = _Provider(url, Uint8List.fromList([1, 2, 3]));
    final completer = provider.loadImage(
      provider,
      (buffer, {getTargetSize}) async => _FailingCodec(),
    );

    final failed = Completer<void>();
    completer.addListener(
      ImageStreamListener(
        (_, __) {},
        onError: (_, __) {
          if (!failed.isCompleted) failed.complete();
        },
      ),
    );
    await failed.future;

    expect(AvifFallbackRegistry.instance.hasFailed(url), isTrue);
    expect(_Provider.evicted, isTrue);
    expect(
      AvifFallbackRegistry.instance.applyFallback(url),
      'https://img.example.invalid/p/001.webp',
    );
  });
}

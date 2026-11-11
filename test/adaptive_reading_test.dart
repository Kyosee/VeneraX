import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/adaptive_reading.dart';
import 'package:venera/foundation/image_provider/reader_image.dart';

void main() {
  group('detectReadingLayout', () {
    test('recognizes ordinary pages with a cover and a wide spread', () {
      // Covers and spreads are deliberately mixed into the body sample. The
      // probe skips the cover; this pure detector only sees the page shapes.
      expect(
        detectReadingLayout([
          const Size(1600, 2400),
          const Size(1600, 1100),
          const Size(1600, 1050),
          const Size(1600, 1200),
        ]),
        AdaptiveReadingLayout.paged,
      );
    });

    test('recognizes tall pages as a strip', () {
      expect(
        detectReadingLayout([
          const Size(1000, 3000),
          const Size(1000, 2800),
          const Size(1000, 3200),
          const Size(1000, 2900),
        ]),
        AdaptiveReadingLayout.strip,
      );
    });

    test('recognizes short slices when their column stays the same width', () {
      expect(
        detectReadingLayout([
          const Size(1200, 300),
          const Size(1200, 320),
          const Size(1200, 280),
          const Size(1200, 310),
        ]),
        AdaptiveReadingLayout.strip,
      );
    });

    test('does not call uneven short slices a strip', () {
      expect(
        detectReadingLayout([
          const Size(1000, 300),
          const Size(1500, 300),
          const Size(1000, 280),
          const Size(1500, 320),
        ]),
        isNull,
      );
    });

    test('mixed shapes need a clear majority', () {
      expect(
        detectReadingLayout([
          const Size(1000, 3000),
          const Size(1000, 2900),
          const Size(1000, 2800),
          const Size(1400, 1000),
          const Size(1400, 1000),
        ]),
        isNull,
      );
    });

    test('ignores damaged dimensions and requires three valid samples', () {
      expect(
        detectReadingLayout([
          Size.zero,
          const Size(-1, 100),
          const Size(double.infinity, 100),
          const Size(double.nan, 100),
          const Size(1000, 1000),
          const Size(1000, 1000),
        ]),
        isNull,
      );
      expect(
        detectReadingLayout([const Size(1000, 1000), const Size(1000, 1000)]),
        isNull,
      );
    });
  });

  group('probeReadingLayout', () {
    test(
      'skips the cover, samples at most five body images, and uses two workers',
      () async {
        final requested = <int>[];
        var active = 0;
        var peak = 0;

        final result = await probeReadingLayout(
          imageCount: 20,
          readSize: (index) async {
            requested.add(index);
            active++;
            peak = peak < active ? active : peak;
            await Future<void>.delayed(const Duration(milliseconds: 1));
            active--;
            return const Size(1400, 1000);
          },
          isCancelled: () => false,
          timeout: const Duration(seconds: 1),
        );

        expect(result, AdaptiveReadingLayout.paged);
        expect(requested.toSet(), {1, 2, 3, 4, 5});
        expect(requested, hasLength(5));
        expect(requested, isNot(contains(0)));
        expect(peak, lessThanOrEqualTo(2));
      },
    );

    test(
      'continues after one failed sample when the rest are decisive',
      () async {
        final requested = <int>[];
        final result = await probeReadingLayout(
          imageCount: 6,
          readSize: (index) async {
            requested.add(index);
            if (index == 3) throw StateError('bad header');
            return const Size(1000, 3000);
          },
          isCancelled: () => false,
          timeout: const Duration(seconds: 1),
        );

        expect(result, AdaptiveReadingLayout.strip);
        expect(requested.toSet(), {1, 2, 3, 4, 5});
      },
    );

    test('all failed samples fall back without selecting a mode', () async {
      final result = await probeReadingLayout(
        imageCount: 6,
        readSize: (index) async => throw StateError('bad header $index'),
        isCancelled: () => false,
        timeout: const Duration(seconds: 1),
      );

      expect(result, isNull);
    });

    test('timeout stops scheduling and ignores late results', () async {
      final requests = <int>[];
      final pending = <Completer<Size?>>[];
      final probe = probeReadingLayout(
        imageCount: 20,
        readSize: (index) {
          requests.add(index);
          final completer = Completer<Size?>();
          pending.add(completer);
          return completer.future;
        },
        isCancelled: () => false,
        timeout: const Duration(milliseconds: 10),
      );

      expect(await probe, isNull);
      expect(requests, hasLength(2));

      for (final completer in pending) {
        completer.complete(const Size(1000, 3000));
      }
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(2));
    });

    test(
      'cancellation stops scheduling and discards in-flight results',
      () async {
        var cancelled = false;
        final requests = <int>[];
        final pending = <Completer<Size?>>[];
        final probe = probeReadingLayout(
          imageCount: 20,
          readSize: (index) {
            requests.add(index);
            final completer = Completer<Size?>();
            pending.add(completer);
            return completer.future;
          },
          isCancelled: () => cancelled,
          timeout: const Duration(seconds: 1),
        );

        // Both workers issue their first request before either one can continue.
        expect(requests, hasLength(2));
        cancelled = true;
        for (final completer in pending) {
          completer.complete(const Size(1000, 3000));
        }

        expect(await probe, isNull);
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(2));
      },
    );
  });

  test('readDimensions reads an encoded header without file IO', () async {
    final provider = _MemoryReaderImageProvider(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );

    expect(await provider.readDimensions(() {}), const Size(1, 1));
  });
}

class _MemoryReaderImageProvider extends ReaderImageProvider {
  _MemoryReaderImageProvider(this.bytes)
    : super('memory://adaptive-reading', 'test', 'comic', 'chapter', 1);

  final Uint8List bytes;

  @override
  Future<Uint8List> load(dynamic chunkEvents, dynamic checkStop) async {
    checkStop();
    return bytes;
  }
}

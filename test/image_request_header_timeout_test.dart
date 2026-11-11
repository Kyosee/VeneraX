import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/images.dart';

void main() {
  test('a server that never sends headers times out instead of hanging',
      () async {
    final adapter = _SilentAdapter();
    final dio = AppDio.withInterceptors(BaseOptions(), const [])
      ..httpClientAdapter = adapter;

    await expectLater(
      requestImageWithHeaderTimeout(
        dio,
        'https://example.invalid/page.jpg',
        headerTimeout: const Duration(milliseconds: 50),
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('request hung'),
      ),
      throwsA(isA<TimeoutException>()),
    );
    // The underlying request is aborted, not just abandoned.
    await Future<void>.delayed(Duration.zero);
    expect(adapter.cancelled, isTrue);
  });
}

class _SilentAdapter implements HttpClientAdapter {
  bool cancelled = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    cancelFuture?.whenComplete(() => cancelled = true);
    return Completer<ResponseBody>().future;
  }

  @override
  void close({bool force = false}) {}
}

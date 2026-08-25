import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/cache.dart';

/// dio 5.11.0 added private `_invokeRequest` / `_invokeResponse` / `_invokeError`
/// methods to [Interceptor] and drives the request pipeline through them.
/// Library-private members are not part of an interface, so a class that only
/// `implements Interceptor` compiles fine yet blows up at runtime with
/// `NoSuchMethodError: no instance method '_invokeError'` the first time dio
/// reaches that stage. Every interceptor must `extends Interceptor`.
///
/// Driving a real [Dio] is the only thing that catches this — calling `onError`
/// directly bypasses the pipeline entirely.
void main() {
  Dio dioWith(Interceptor interceptor) {
    final dio = Dio();
    dio.httpClientAdapter = _ThrowingAdapter();
    dio.interceptors.add(interceptor);
    return dio;
  }

  Matcher throwsTransportError() => throwsA(
    isA<DioException>().having(
      (e) => e.error.toString(),
      'cause',
      contains('transport failed'),
    ),
  );

  test('MyLogInterceptor survives the error stage', () async {
    await expectLater(
      dioWith(MyLogInterceptor()).get<void>('https://example.com/fail'),
      throwsTransportError(),
    );
  });

  test('NetworkCacheManager survives the error stage', () async {
    addTearDown(NetworkCacheManager().clear);
    await expectLater(
      dioWith(NetworkCacheManager()).get<void>('https://example.com/fail'),
      throwsTransportError(),
    );
  });
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw StateError('transport failed');
  }

  @override
  void close({bool force = false}) {}
}

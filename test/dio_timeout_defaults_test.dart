import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_dio.dart';

/// [MyLogInterceptor] used to ASSIGN the 15s timeouts unconditionally, silently
/// overriding whatever the caller configured. An LLM translation request asking
/// for 120s therefore got 15s, so any model slower than that failed every time
/// and background pre-translation made no progress (#176). The interceptor must
/// only supply defaults.
void main() {
  /// Runs the interceptor over [options] and returns it, mutations included.
  RequestOptions runOnRequest(RequestOptions options) {
    MyLogInterceptor().onRequest(options, RequestInterceptorHandler());
    return options;
  }

  group('MyLogInterceptor timeouts', () {
    test('fills in defaults when the caller set none', () {
      var options = runOnRequest(RequestOptions(path: 'https://example.com'));
      expect(options.connectTimeout, const Duration(seconds: 15));
      expect(options.receiveTimeout, const Duration(seconds: 15));
      expect(options.sendTimeout, const Duration(seconds: 15));
    });

    test('preserves a caller-supplied longer receiveTimeout', () {
      var options = runOnRequest(
        RequestOptions(
          path: 'https://example.com',
          receiveTimeout: const Duration(minutes: 2),
        ),
      );
      expect(options.receiveTimeout, const Duration(minutes: 2));
      // The untouched ones still get the default.
      expect(options.connectTimeout, const Duration(seconds: 15));
    });

    test('preserves caller-supplied connect and send timeouts', () {
      var options = runOnRequest(
        RequestOptions(
          path: 'https://example.com',
          connectTimeout: const Duration(seconds: 20),
          sendTimeout: const Duration(seconds: 45),
        ),
      );
      expect(options.connectTimeout, const Duration(seconds: 20));
      expect(options.sendTimeout, const Duration(seconds: 45));
    });
  });
}

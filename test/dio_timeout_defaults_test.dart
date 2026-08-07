import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
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

  setUp(() {
    Log.clear();
    appdata.settings['verboseNetworkLog'] = false;
  });

  group('MyLogInterceptor request logging', () {
    // Every comic page is a request; recording two log lines per request (each
    // formatting headers and hitting the disk) drained the battery steadily
    // with no frame-rate symptom. Successes must stay silent unless asked for.
    test('does not log successful requests by default', () {
      runOnRequest(RequestOptions(path: 'https://example.com/page1.jpg'));
      expect(Log.logs, isEmpty);
    });

    test('logs requests when verbose network logging is on', () {
      appdata.settings['verboseNetworkLog'] = true;
      runOnRequest(RequestOptions(path: 'https://example.com/page1.jpg'));
      expect(Log.logs, hasLength(1));
      expect(Log.logs.first.content, contains('example.com/page1.jpg'));
    });

    test('timeout defaults still apply while logging is off', () {
      var options = runOnRequest(RequestOptions(path: 'https://example.com'));
      expect(Log.logs, isEmpty);
      expect(options.connectTimeout, const Duration(seconds: 15));
    });

    test('masks sensitive headers when logging is on', () {
      appdata.settings['verboseNetworkLog'] = true;
      runOnRequest(
        RequestOptions(
          path: 'https://example.com',
          headers: {'authorization': 'Bearer secret-token'},
        ),
      );
      expect(Log.logs.first.content, isNot(contains('secret-token')));
    });
  });

  group('MyLogInterceptor response logging', () {
    void runOnResponse(int statusCode) {
      var options = RequestOptions(path: 'https://example.com');
      MyLogInterceptor().onResponse(
        Response<dynamic>(
          requestOptions: options,
          statusCode: statusCode,
          data: 'body',
        ),
        ResponseInterceptorHandler(),
      );
    }

    test('stays silent on success by default', () {
      runOnResponse(200);
      expect(Log.logs, isEmpty);
    });

    test('always logs failures, even with logging off', () {
      runOnResponse(500);
      expect(Log.logs, hasLength(1));
      expect(Log.logs.first.level, LogLevel.error);
    });

    test('logs successes when verbose network logging is on', () {
      appdata.settings['verboseNetworkLog'] = true;
      runOnResponse(200);
      expect(Log.logs, hasLength(1));
      expect(Log.logs.first.level, LogLevel.info);
    });
  });

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

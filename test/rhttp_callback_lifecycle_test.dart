// Exercise the generated bridge against the supplied native library.
// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/src/rust/api/client.dart' as rust_client;
import 'package:rhttp/src/rust/api/error.dart' as rust_error;
import 'package:rhttp/src/rust/api/http.dart' as rust_http;
import 'package:rhttp/src/rust/frb_generated.dart';
import 'package:rhttp/src/rust/lib.dart' as rust;

void main() {
  final libraryPath = Platform.environment['RHTTP_TEST_LIBRARY']?.trim() ?? '';

  test(
    'late stream callback after cancellation keeps the native bridge alive',
    () async {
      const waitLimit = Duration(seconds: 10);
      const body = 'native bridge still works';
      expect(
        File(libraryPath).existsSync(),
        isTrue,
        reason: 'RHTTP_TEST_LIBRARY must name an existing native library',
      );
      await RustLib.init(
        externalLibrary: ExternalLibrary.open(libraryPath),
      ).timeout(waitLimit);
      addTearDown(RustLib.dispose);

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write(body);
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/';
      const settings = rust_client.ClientSettings(
        httpVersionPref: rust_http.HttpVersionPref.http11,
        throwOnStatusCode: true,
        proxySettings: rust_client.ProxySettings.noProxy(),
      );

      final responseEntered = Completer<rust_http.HttpResponse>();
      final releaseResponse = Completer<void>();
      final responseReturned = Completer<void>();
      final tokenReady = Completer<rust.CancellationToken>();
      final cancellationObserved = Completer<rust_error.RhttpError>();
      final streamDone = Completer<void>();
      final streamErrors = <Object>[];
      var receivedBytes = 0;

      final subscription = rust_http
          .makeHttpRequestReceiveStream(
            settings: settings,
            method: const rust_http.HttpMethod(method: 'GET'),
            url: url,
            onResponse: (response) async {
              responseEntered.complete(response);
              await releaseResponse.future;
              responseReturned.complete();
            },
            onError: cancellationObserved.complete,
            onCancelToken: tokenReady.complete,
            cancelable: true,
          )
          .listen(
            (bytes) => receivedBytes += bytes.length,
            onError: (Object error, StackTrace stackTrace) {
              streamErrors.add(error);
            },
            onDone: streamDone.complete,
          );
      addTearDown(() async {
        if (!releaseResponse.isCompleted) releaseResponse.complete();
        await subscription.cancel();
        await Future<void>.delayed(Duration.zero);
      });

      final response = await responseEntered.future.timeout(waitLimit);
      expect(response.statusCode, HttpStatus.ok);
      final token = await tokenReady.future.timeout(waitLimit);
      await rust_http.cancelRequest(token: token).timeout(waitLimit);

      // The cancellation branch runs after Rust drops the waiting callback.
      expect(
        await cancellationObserved.future.timeout(waitLimit),
        const rust_error.RhttpError.rhttpCancelError(),
      );
      await streamDone.future.timeout(waitLimit);
      expect(receivedBytes, 0);
      expect(streamErrors, hasLength(1));
      expect(streamErrors.single.toString(), contains('STREAM_CANCEL_ERROR'));

      releaseResponse.complete();
      await responseReturned.future.timeout(waitLimit);
      // Let the generated Dart callback deliver its result through FFI.
      await Future<void>.delayed(Duration.zero);

      var healthyCallbackCount = 0;
      final healthyResponse = await rust_http
          .makeHttpRequest(
            settings: settings,
            method: const rust_http.HttpMethod(method: 'GET'),
            url: url,
            expectBody: rust_http.HttpExpectBody.text,
            onCancelToken: (_) {
              healthyCallbackCount++;
            },
            cancelable: true,
          )
          .timeout(waitLimit);
      expect(healthyCallbackCount, 1);
      expect(healthyResponse.statusCode, HttpStatus.ok);
      expect(healthyResponse.body, const rust_http.HttpResponseBody.text(body));
    },
    skip: libraryPath.isEmpty
        ? 'Set RHTTP_TEST_LIBRARY to a matching rhttp library with panic=abort'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}

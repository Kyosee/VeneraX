import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/image_translation/model_file_download.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);
  final FutureOr<ResponseBody> Function(RequestOptions, int) respond;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async => respond(options, calls++);
  @override
  void close({bool force = false}) {}
}

ResponseBody _response(
  List<int> bytes, {
  int status = 200,
  String? etag = '"v1"',
  int? total,
  String? range,
  Object? error,
}) {
  Stream<Uint8List> stream() async* {
    yield Uint8List.fromList(bytes);
    if (error != null) throw error;
  }

  return ResponseBody(
    stream(),
    status,
    headers: {
      'content-length': ['${total ?? bytes.length}'],
      if (etag != null) 'etag': [etag],
      if (range != null) 'content-range': [range],
    },
  );
}

void main() {
  late Directory directory;
  late File target;
  late Dio dio;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('model-download-test-');
    target = File('${directory.path}/model.onnx');
    dio = Dio();
  });
  tearDown(() async {
    dio.close(force: true);
    await directory.delete(recursive: true);
  });

  Future<void> download({
    String url = 'https://models.invalid/model',
    CancelToken? token,
    ProgressCallback? progress,
  }) => downloadModelFile(
    dio: dio,
    url: url,
    target: target,
    cancelToken: token ?? CancelToken(),
    onProgress: progress ?? (_, _) {},
    retryDelay: Duration.zero,
  );

  final request = rhttp.HttpRequest(url: 'https://models.invalid/model');
  final transientErrors = <String, Object>{
    'connection': rhttp.RhttpConnectionException(request, 'offline'),
    'timeout': rhttp.RhttpTimeoutException(request),
    'response decoding': rhttp.RhttpUnknownException(
      request,
      'error decoding response body',
    ),
  };
  for (final entry in transientErrors.entries) {
    for (final wrapped in [false, true]) {
      test(
        'retries rhttp ${entry.key} from ${wrapped ? 'Dio' : 'the body stream'}',
        () async {
          final adapter = _Adapter((options, attempt) {
            if (attempt == 0) {
              if (wrapped) {
                throw DioException(requestOptions: options, error: entry.value);
              }
              return _response([1, 2], total: 4, error: entry.value);
            }
            if (wrapped) return _response([1, 2, 3, 4]);
            expect(options.headers['range'], 'bytes=2-');
            return _response([3, 4], status: 206, range: 'bytes 2-3/4');
          });
          dio.httpClientAdapter = adapter;
          await download();
          expect(adapter.calls, 2);
          expect(await target.readAsBytes(), [1, 2, 3, 4]);
        },
      );
    }
  }

  final permanentErrors = <String, Object>{
    'certificate': rhttp.RhttpInvalidCertificateException(
      request: request,
      message: 'untrusted',
    ),
    'cancellation': rhttp.RhttpCancelException(request),
    'redirect': rhttp.RhttpRedirectException(request),
    'disposed client': rhttp.RhttpClientDisposedException(request),
    'forbidden': rhttp.RhttpStatusCodeException(
      request: request,
      statusCode: 403,
      headers: [],
      body: null,
    ),
    'disk': const FileSystemException('disk full'),
    'invalid data': const FormatException('invalid data'),
  };
  for (final entry in permanentErrors.entries) {
    for (final wrapped in [false, true]) {
      test(
        'does not retry ${entry.key} from ${wrapped ? 'Dio' : 'the body stream'}',
        () async {
          final adapter = _Adapter((options, _) {
            if (wrapped) {
              throw DioException(requestOptions: options, error: entry.value);
            }
            return _response([1], total: 2, error: entry.value);
          });
          dio.httpClientAdapter = adapter;
          await expectLater(
            download(),
            throwsA(wrapped ? isA<DioException>() : same(entry.value)),
          );
          expect(adapter.calls, 1);
          expect(await target.exists(), isFalse);
        },
      );
    }
  }

  test('rhttp stream failures still stop after five attempts', () async {
    final failure = rhttp.RhttpUnknownException(
      request,
      'error decoding response body',
    );
    final adapter = _Adapter(
      (_, _) => _response([1], total: 2, error: failure),
    );
    dio.httpClientAdapter = adapter;
    await expectLater(download(), throwsA(same(failure)));
    expect(adapter.calls, 5);
    expect(await target.exists(), isFalse);
  });

  test(
    'a wrapped certificate failure overrides a connection error category',
    () async {
      final adapter = _Adapter(
        (options, _) => throw DioException.connectionError(
          requestOptions: options,
          reason: 'TLS',
          error: permanentErrors['certificate'],
        ),
      );
      dio.httpClientAdapter = adapter;
      await expectLater(download(), throwsA(isA<DioException>()));
      expect(adapter.calls, 1);
    },
  );

  for (final status in [403, 429]) {
    test(
      'releases an unfinished $status body before reporting failure',
      () async {
        var cancelled = false;
        final body = StreamController<Uint8List>(
          onCancel: () {
            cancelled = true;
          },
        );
        addTearDown(body.close);
        final token = CancelToken();
        CancelToken? attemptToken;
        final adapter = _Adapter((options, _) {
          attemptToken = options.cancelToken;
          return ResponseBody(
            body.stream,
            status,
            headers: {
              'retry-after': ['3600'],
            },
          );
        });
        dio.httpClientAdapter = adapter;
        await expectLater(download(token: token), throwsA(isA<DioException>()));
        expect(adapter.calls, 1);
        expect(cancelled, isTrue);
        expect(attemptToken, isNot(same(token)));
        expect(attemptToken!.isCancelled, isTrue);
        expect(token.isCancelled, isFalse);
      },
    );
  }

  test('releases a rejected response before a successful retry', () async {
    var cancelled = false;
    final body = StreamController<Uint8List>(
      onCancel: () {
        cancelled = true;
      },
    );
    addTearDown(body.close);
    final token = CancelToken();
    final adapter = _Adapter((_, attempt) {
      if (attempt == 0) return ResponseBody(body.stream, 429);
      expect(cancelled, isTrue);
      return _response([1, 2]);
    });
    dio.httpClientAdapter = adapter;
    await download(token: token);
    expect(adapter.calls, 2);
    expect(token.isCancelled, isFalse);
  });

  test(
    'caller cancellation releases a body waiting for its next chunk',
    () async {
      var cancelled = false;
      late StreamController<Uint8List> body;
      body = StreamController<Uint8List>(
        onListen: () => body.add(Uint8List.fromList([1])),
        onCancel: () {
          cancelled = true;
        },
      );
      addTearDown(body.close);
      final token = CancelToken();
      final adapter = _Adapter(
        (_, _) => ResponseBody(
          body.stream,
          200,
          headers: {
            'content-length': ['2'],
            'etag': ['"v1"'],
          },
        ),
      );
      dio.httpClientAdapter = adapter;
      await expectLater(
        download(
          token: token,
          progress: (received, _) {
            if (received == 1) token.cancel();
          },
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
      expect(adapter.calls, 1);
      expect(cancelled, isTrue);
      expect(await target.exists(), isFalse);
      expect(await File('${target.path}.part').readAsBytes(), [1]);
    },
  );

  test(
    'a broken stream resumes validated bytes instead of restarting',
    () async {
      final adapter = _Adapter((request, attempt) {
        if (attempt == 0) {
          return _response(
            [1, 2, 3],
            total: 6,
            error: const SocketException('offline'),
          );
        }
        expect(request.headers['range'], 'bytes=3-');
        expect(request.headers['if-range'], '"v1"');
        return _response([4, 5, 6], status: 206, range: 'bytes 3-5/6');
      });
      dio.httpClientAdapter = adapter;
      await download();
      expect(adapter.calls, 2);
      expect(await target.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(await File('${target.path}.part').exists(), isFalse);
      expect(await File('${target.path}.part.json').exists(), isFalse);
    },
  );

  test(
    'a changed representation or ignored range replaces partial bytes',
    () async {
      dio.httpClientAdapter = _Adapter(
        (request, attempt) => attempt == 0
            ? _response(
                [1, 2],
                total: 4,
                error: const SocketException('offline'),
              )
            : _response([5, 6, 7, 8], etag: '"v2"'),
      );
      await download();
      expect(await target.readAsBytes(), [5, 6, 7, 8]);
    },
  );

  test('a mismatched partial response is never committed', () async {
    dio.httpClientAdapter = _Adapter((request, attempt) {
      if (attempt == 0) {
        return _response(
          [1, 2],
          total: 4,
          error: const SocketException('offline'),
        );
      }
      if (attempt == 1) {
        return _response([8, 9], status: 206, range: 'bytes 1-2/4');
      }
      expect(request.headers['range'], isNull);
      return _response([4, 3, 2, 1]);
    });
    await download();
    expect(await target.readAsBytes(), [4, 3, 2, 1]);
  });

  test(
    'failed bounded retries preserve bytes for a later invocation',
    () async {
      final adapter = _Adapter((request, attempt) {
        if (attempt == 0) {
          return _response(
            [1, 2],
            total: 4,
            error: const SocketException('offline'),
          );
        }
        throw DioException.connectionError(
          requestOptions: request,
          reason: 'offline',
        );
      });
      dio.httpClientAdapter = adapter;
      await expectLater(download(), throwsA(isA<DioException>()));
      expect(adapter.calls, 5);
      expect(await target.exists(), isFalse);
      dio.httpClientAdapter = _Adapter((request, _) {
        expect(request.headers['range'], 'bytes=2-');
        return _response([3, 4], status: 206, range: 'bytes 2-3/4');
      });
      await download();
      expect(await target.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test('cancellation keeps resumable bytes and does not retry', () async {
    final token = CancelToken();
    final adapter = _Adapter(
      (_, _) =>
          _response([1, 2], total: 4, error: const SocketException('offline')),
    );
    dio.httpClientAdapter = adapter;
    await expectLater(
      download(
        token: token,
        progress: (count, _) {
          if (count == 2) token.cancel();
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(adapter.calls, 1);
    expect(await target.exists(), isFalse);
    expect(await File('${target.path}.part').readAsBytes(), [1, 2]);
  });

  test('a different source cannot reuse a previous source partial', () async {
    dio.httpClientAdapter = _Adapter(
      (_, _) =>
          _response([1, 2], total: 4, error: const SocketException('offline')),
    );
    await expectLater(download(), throwsA(isA<SocketException>()));
    dio.httpClientAdapter = _Adapter((request, _) {
      expect(request.headers['range'], isNull);
      return _response([9, 8, 7, 6]);
    });
    await download(url: 'https://other.invalid/model');
    expect(await target.readAsBytes(), [9, 8, 7, 6]);
  });

  test('a source without a strong validator restarts safely', () async {
    dio.httpClientAdapter = _Adapter((request, attempt) {
      expect(request.headers['range'], isNull);
      return attempt == 0
          ? _response(
              [1, 2],
              etag: 'W/"v1"',
              total: 4,
              error: const SocketException('offline'),
            )
          : _response([3, 4, 5, 6], etag: 'W/"v1"');
    });
    await download();
    expect(await target.readAsBytes(), [3, 4, 5, 6]);
  });

  test(
    '429 retries, but long rate limits and permanent errors do not',
    () async {
      final retry = _Adapter(
        (_, attempt) => attempt == 0
            ? ResponseBody.fromString(
                '',
                429,
                headers: {
                  'retry-after': ['0'],
                },
              )
            : _response([1]),
      );
      dio.httpClientAdapter = retry;
      await download();
      expect(retry.calls, 2);
      for (final status in [403, 429]) {
        final adapter = _Adapter(
          (_, _) => ResponseBody.fromString(
            '',
            status,
            headers: {
              'retry-after': ['3600'],
            },
          ),
        );
        dio.httpClientAdapter = adapter;
        await expectLater(download(), throwsA(isA<DioException>()));
        expect(adapter.calls, 1);
      }
    },
  );

  test(
    'TLS and disk errors are not treated as transient network failures',
    () async {
      for (final disk in [false, true]) {
        final adapter = _Adapter(
          (request, _) => throw disk
              ? DioException(
                  requestOptions: request,
                  error: const FileSystemException('disk full'),
                )
              : DioException.badCertificate(requestOptions: request),
        );
        dio.httpClientAdapter = adapter;
        await expectLater(download(), throwsA(isA<DioException>()));
        expect(adapter.calls, 1);
      }
    },
  );
}

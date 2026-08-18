import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/webdav_upload.dart';

DioException _responseError(int statusCode) {
  final request = RequestOptions(path: '/backup.venera');
  return DioException(
    requestOptions: request,
    response: Response<void>(requestOptions: request, statusCode: statusCode),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  test('normalizes backup names to server-absolute WebDAV paths', () {
    expect(serverAbsoluteWebdavPath('backup.venera'), '/backup.venera');
    expect(serverAbsoluteWebdavPath('/backup.venera'), '/backup.venera');
  });

  test('retries a streamed HTTP 404 with the buffered writer', () async {
    var streamed = 0;
    var buffered = 0;

    final usedFallback = await uploadWithWebdav404Fallback(
      streamUpload: () async {
        streamed++;
        throw _responseError(404);
      },
      bufferedUpload: () async {
        buffered++;
      },
    );

    expect(usedFallback, isTrue);
    expect(streamed, 1);
    expect(buffered, 1);
  });

  test('does not hide non-404 WebDAV failures', () async {
    var buffered = 0;
    final error = _responseError(403);

    await expectLater(
      uploadWithWebdav404Fallback(
        streamUpload: () async => throw error,
        bufferedUpload: () async {
          buffered++;
        },
      ),
      throwsA(same(error)),
    );
    expect(buffered, 0);
  });

  test('keeps the streaming path when it succeeds', () async {
    var buffered = 0;

    final usedFallback = await uploadWithWebdav404Fallback(
      streamUpload: () async {},
      bufferedUpload: () async {
        buffered++;
      },
    );

    expect(usedFallback, isFalse);
    expect(buffered, 0);
  });
}

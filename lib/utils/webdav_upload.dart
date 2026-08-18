import 'package:dio/dio.dart';

typedef WebdavUploadAttempt = Future<void> Function();

String serverAbsoluteWebdavPath(String path) {
  return path.startsWith('/') ? path : '/$path';
}

Future<bool> uploadWithWebdav404Fallback({
  required WebdavUploadAttempt streamUpload,
  required WebdavUploadAttempt bufferedUpload,
}) async {
  try {
    await streamUpload();
    return false;
  } on DioException catch (error) {
    if (error.response?.statusCode != 404) rethrow;
    await bufferedUpload();
    return true;
  }
}

import 'dart:io';

import 'package:dio/dio.dart';

/// Streams an update to disk, closing and removing incomplete files on failure.
Future<void> downloadAppUpdate({
  required Dio dio,
  required String url,
  required File destination,
  required CancelToken cancelToken,
  required void Function(double?) onProgress,
  Map<String, String> headers = const {},
  int expectedSize = 0,
}) async {
  try {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final response = await dio.get<ResponseBody>(
      url,
      cancelToken: cancelToken,
      options: Options(responseType: ResponseType.stream, headers: headers),
    );
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final body = response.data!;
    final total =
        int.tryParse(body.headers['content-length']?.first ?? '') ??
        expectedSize;
    var received = 0;
    final sink = destination.openWrite();
    // Observe early disk failures; close() below still propagates the error.
    sink.done.ignore();
    try {
      await for (final chunk in body.stream) {
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        sink.add(chunk);
        received += chunk.length;
        onProgress(total > 0 ? received / total : null);
      }
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (total > 0 && received != total) {
        throw const HttpException('Incomplete update package');
      }
    } finally {
      await sink.close();
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
  } catch (_) {
    if (await destination.exists()) await destination.delete();
    rethrow;
  }
}

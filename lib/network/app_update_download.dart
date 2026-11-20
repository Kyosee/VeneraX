import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

/// A package handed to an installer outlives the app, so a later update
/// reclaims attempts old enough that no installer can still be reading them.
Future<void> removeStaleUpdateAttempts(
  Directory updates, {
  Duration maxAge = const Duration(days: 1),
  DateTime? now,
}) async {
  if (!await updates.exists()) return;
  final cutoff = (now ?? DateTime.now()).subtract(maxAge);
  await for (final entry in updates.list(followLinks: false)) {
    if (entry is! Directory ||
        !p.basename(entry.path).startsWith('download-')) {
      continue;
    }
    try {
      if ((await entry.stat()).modified.isBefore(cutoff)) {
        await entry.delete(recursive: true);
      }
    } on FileSystemException {
      // A locked leftover is retried on the next update.
    }
  }
}

/// Streams an update to disk, closing and removing incomplete files on failure.
Future<void> downloadAppUpdate({
  required Dio dio,
  required String url,
  required File destination,
  required CancelToken cancelToken,
  required ProgressCallback onProgress,
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
        received += chunk.length;
        if (expectedSize > 0 && received > expectedSize) {
          throw const HttpException('Update package exceeds expected size');
        }
        sink.add(chunk);
        onProgress(received, expectedSize > 0 ? expectedSize : total);
      }
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if ((total > 0 && received != total) ||
          (expectedSize > 0 && received != expectedSize)) {
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

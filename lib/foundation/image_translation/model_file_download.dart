import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:rhttp/rhttp.dart' as rhttp;

/// Keeps partial bytes only with a strong HTTP validator for the same source.
/// A changed mirror or representation must never be appended to an old model.
Future<void> downloadModelFile({
  required Dio dio,
  required String url,
  required File target,
  required CancelToken cancelToken,
  required ProgressCallback onProgress,
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  final partial = File('${target.path}.part');
  final metadata = File('${partial.path}.json');
  for (var attempt = 0; ; attempt++) {
    _checkCancelled(cancelToken);
    try {
      await _downloadAttempt(
        dio,
        url,
        partial,
        metadata,
        cancelToken,
        onProgress,
      );
      _checkCancelled(cancelToken);
      await partial.rename(target.path);
      if (await metadata.exists()) await metadata.delete();
      return;
    } catch (error) {
      _checkCancelled(cancelToken);
      if (attempt >= 4 || !_retryable(error)) {
        rethrow;
      }
      var delay = retryDelay * (1 << attempt);
      if (error is DioException) {
        final value = error.response?.headers.value('retry-after');
        if (value != null) {
          Duration? requested;
          final seconds = int.tryParse(value);
          if (seconds != null) {
            requested = Duration(seconds: seconds);
          } else {
            try {
              requested = HttpDate.parse(value).difference(DateTime.now());
            } on FormatException {
              // An invalid server hint does not disable bounded retries.
            }
          }
          // Leave long rate limits for a later manual retry.
          if (requested != null && requested > const Duration(minutes: 2)) {
            rethrow;
          }
          if (requested != null && requested > delay) delay = requested;
        }
      }
      await Future.any([
        Future<void>.delayed(delay),
        cancelToken.whenCancel.then<void>((error) => throw error),
      ]);
    }
  }
}

bool _retryable(Object error) {
  if (error is DioException) {
    if (error.type == DioExceptionType.cancel ||
        error.type == DioExceptionType.badCertificate) {
      return false;
    }
    if (error.type == DioExceptionType.badResponse) {
      final status = error.response?.statusCode ?? 0;
      return status == 408 || status == 429 || (status >= 500 && status < 600);
    }
    // Native errors may arrive directly from a body stream or inside Dio.
    // Classify the cause so a broad wrapper cannot hide certificate failures.
    if (error.error != null) return _retryable(error.error!);
    return switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.connectionError => true,
      _ => false,
    };
  }
  return error is SocketException ||
      error is HttpException ||
      error is TimeoutException ||
      error is rhttp.RhttpConnectionException ||
      error is rhttp.RhttpTimeoutException ||
      error is rhttp.RhttpUnknownException;
}

Future<void> _downloadAttempt(
  Dio dio,
  String url,
  File partial,
  File metadata,
  CancelToken cancelToken,
  ProgressCallback onProgress,
) async {
  var offset = 0;
  String? validator;
  int? expectedTotal;
  if (await partial.exists() && await metadata.exists()) {
    try {
      final saved = jsonDecode(await metadata.readAsString());
      if (saved is Map &&
          saved['url'] == url &&
          saved['etag'] is String &&
          _strongEtag(saved['etag'] as String) &&
          saved['total'] is int &&
          saved['total'] > 0) {
        offset = await partial.length();
        expectedTotal = saved['total'] as int;
        if (offset > 0 && offset < expectedTotal) {
          validator = saved['etag'] as String;
        } else {
          offset = 0;
        }
      }
    } on FormatException {
      // An interrupted metadata write is restarted safely.
    }
  }
  _checkCancelled(cancelToken);
  final attemptToken = CancelToken();
  final cancellation = cancelToken.whenCancel.asStream().listen((error) {
    if (!attemptToken.isCancelled) attemptToken.cancel(error);
  });
  ResponseBody? body;
  RandomAccessFile? output;
  var consumed = false;
  try {
    final response = await dio.get<ResponseBody>(
      url,
      cancelToken: attemptToken,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          HttpHeaders.acceptEncodingHeader: 'identity',
          if (validator != null) ...{
            HttpHeaders.rangeHeader: 'bytes=$offset-',
            HttpHeaders.ifRangeHeader: validator,
          },
        },
        validateStatus: (status) =>
            status == 200 || status == 206 || status == 416,
      ),
    );
    body = response.data!;
    final etag = response.headers.value(HttpHeaders.etagHeader);
    var total = int.tryParse(
      response.headers.value(HttpHeaders.contentLengthHeader) ?? '',
    );
    if (response.statusCode == 206) {
      final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
        response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
      );
      final start = int.tryParse(range?.group(1) ?? '');
      final end = int.tryParse(range?.group(2) ?? '');
      final length = int.tryParse(range?.group(3) ?? '');
      if (validator == null ||
          etag != validator ||
          start != offset ||
          end == null ||
          length != expectedTotal ||
          end != length! - 1 ||
          (total != null && total != length - offset)) {
        if (await metadata.exists()) await metadata.delete();
        throw const HttpException('Invalid model download range');
      }
      total = length;
    } else if (response.statusCode == 416) {
      if (await metadata.exists()) await metadata.delete();
      throw const HttpException('Model download range is no longer available');
    } else {
      // A server may ignore Range or reject If-Range after the model changed.
      offset = 0;
    }
    final encoding = response.headers.value(HttpHeaders.contentEncodingHeader);
    if (encoding != null && encoding != 'identity') {
      if (await metadata.exists()) await metadata.delete();
      throw const FormatException('Unexpected model download encoding');
    }
    _checkCancelled(cancelToken);
    output = await partial.open(
      mode: offset == 0 ? FileMode.write : FileMode.append,
    );
    if (etag != null && _strongEtag(etag) && total != null && total > 0) {
      await metadata.writeAsString(
        jsonEncode({'url': url, 'etag': etag, 'total': total}),
      );
    } else if (await metadata.exists()) {
      await metadata.delete();
    }
    var received = offset;
    onProgress(received, total ?? -1);
    consumed = true;
    await for (final chunk in body.stream) {
      _checkCancelled(cancelToken);
      if (total != null && received + chunk.length > total) {
        if (await metadata.exists()) await metadata.delete();
        throw const HttpException(
          'Model download exceeded its declared length',
        );
      }
      await output.writeFrom(chunk);
      received += chunk.length;
      onProgress(received, total ?? -1);
    }
    if (received == 0 || (total != null && received != total)) {
      throw const HttpException('Incomplete model download');
    }
    await output.flush();
  } on DioException catch (error) {
    final rejectedBody = error.response?.data;
    if (body == null && rejectedBody is ResponseBody) body = rejectedBody;
    rethrow;
  } finally {
    // Dio's body subscription needs token cancellation even for rejected
    // responses; cancelling only the returned stream leaves native IO alive.
    if (!attemptToken.isCancelled) attemptToken.cancel();
    await cancellation.cancel();
    try {
      await output?.close();
    } finally {
      if (!consumed && body != null) {
        await body.stream.listen(null, onError: (Object _) {}).cancel();
      }
    }
  }
}

bool _strongEtag(String value) =>
    value.length >= 2 && value.startsWith('"') && value.endsWith('"');

void _checkCancelled(CancelToken token) {
  if (token.isCancelled) throw token.cancelError!;
}

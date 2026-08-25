import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/cache.dart';

import 'app_dio_io.dart';
import 'cloudflare.dart';
import 'cookie_jar.dart';

export 'package:dio/dio.dart';

class MyLogInterceptor extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    Log.error(
      "Network",
      "${err.requestOptions.method} ${err.requestOptions.path}\n$err\n${err.response?.data.toString()}",
    );
    switch (err.type) {
      case DioExceptionType.badResponse:
        var statusCode = err.response?.statusCode;
        if (statusCode != null) {
          err = err.copyWith(
            message:
                "Invalid Status Code: $statusCode. "
                "${_getStatusCodeInfo(statusCode)}",
          );
        }
      case DioExceptionType.connectionTimeout:
        err = err.copyWith(message: "Connection Timeout");
      case DioExceptionType.receiveTimeout:
        err = err.copyWith(
          message:
              "Receive Timeout: "
              "This indicates that the server is too busy to respond",
        );
      case DioExceptionType.unknown:
        if (err.toString().contains("Connection terminated during handshake")) {
          err = err.copyWith(
            message:
                "Connection terminated during handshake: "
                "This may be caused by the firewall blocking the connection "
                "or your requests are too frequent.",
          );
        } else if (err.toString().contains("Connection reset by peer")) {
          err = err.copyWith(
            message:
                "Connection reset by peer: "
                "The error is unrelated to app, please check your network.",
          );
        }
      default:
        {}
    }
    handler.next(err);
  }

  static const errorMessages = <int, String>{
    400: "The Request is invalid.",
    401: "The Request is unauthorized.",
    403: "No permission to access the resource. Check your account or network.",
    404: "Not found.",
    429: "Too many requests. Please try again later.",
  };

  String _getStatusCodeInfo(int? statusCode) {
    if (statusCode != null && statusCode >= 500) {
      return "This is server-side error, please try again later. "
          "Do not report this issue.";
    } else {
      return errorMessages[statusCode] ?? "";
    }
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    var isFailure = response.statusCode != null && response.statusCode! >= 400;
    // Successful responses are only logged when the user asked for a verbose
    // trace. Reading a comic issues a request per page, and formatting headers
    // plus decoding bodies for every one of them is continuous work with no
    // diagnostic value once things are known to work. Failures always log.
    if (!isFailure && !Log.verboseNetwork) {
      handler.next(response);
      return;
    }
    var headers = response.headers.map.map(
      (key, value) => MapEntry(
        key.toLowerCase(),
        value.length == 1 ? value.first : value.toString(),
      ),
    );
    headers.remove("cookie");
    String content;
    if (response.data is List<int>) {
      try {
        content = utf8.decode(response.data, allowMalformed: false);
      } catch (e) {
        content = "<Bytes>\nlength:${response.data.length}";
      }
    } else {
      content = response.data.toString();
    }
    Log.addLog(
      isFailure ? LogLevel.error : LogLevel.info,
      "Network",
      "Response ${response.realUri.toString()} ${response.statusCode}\n"
          "headers:\n$headers\n$content",
    );
    handler.next(response);
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Only build the log line when a verbose trace was requested — the header
    // masking below allocates a new map per request, which on a comic page
    // means once per image. The timeout defaults after it always apply.
    if (Log.verboseNetwork) {
      const String headerMask = "********";
      const String dataMask = "****** DATA_PROTECTED ******";
      const sensitiveHeaders = {
        "authorization",
        "cookie",
        "proxy-authorization",
      };
      var extraMaskedHeaders = options.extra["maskHeadersInLog"];
      var headersForLog = options.headers.map((key, value) {
        var shouldMask =
            sensitiveHeaders.contains(key.toLowerCase()) ||
            (extraMaskedHeaders is Iterable && extraMaskedHeaders.contains(key));
        return MapEntry(key, shouldMask ? headerMask : value);
      });
      Log.info(
        "Network",
        "${options.method} ${options.uri}\n"
            "headers:\n$headersForLog\n"
            "data:\n${options.extra["maskDataInLog"] == true ? dataMask : options.data}",
      );
    }
    // Defaults only: a caller that asked for its own bound keeps it. These used
    // to be assigned unconditionally, which silently cut every long request
    // down to 15s — an LLM translation request that needs 40s before its first
    // token could never succeed no matter what the caller configured.
    options.connectTimeout ??= const Duration(seconds: 15);
    options.receiveTimeout ??= const Duration(seconds: 15);
    options.sendTimeout ??= const Duration(seconds: 15);
    handler.next(options);
  }
}

class AppDio with DioMixin {
  AppDio([BaseOptions? options, Duration? timeout])
      : this.withInterceptors(options, null, timeout);

  AppDio.withInterceptors(
    BaseOptions? options,
    List<Interceptor>? interceptors, [
    Duration? timeout,
  ]) {
    this.options = options ?? BaseOptions();
    // [timeout] bounds the WHOLE request at the transport layer. dio's own
    // receiveTimeout does not apply to the streaming rhttp responses this
    // adapter returns, so a connected-but-stalled socket would otherwise hang
    // the caller forever. Null keeps the unbounded default used by image reads.
    httpClientAdapter = createAppHttpClientAdapter(timeout: timeout);
    this.interceptors.addAll(interceptors ?? _buildDefaultInterceptors());
  }

  static List<Interceptor> _buildDefaultInterceptors() {
    final list = <Interceptor>[];
    if (SingleInstanceCookieJar.instance != null) {
      list.add(CookieManagerSql(SingleInstanceCookieJar.instance!));
    }
    list.add(NetworkCacheManager());
    list.add(CloudflareInterceptor());
    list.add(MyLogInterceptor());
    return list;
  }

  static final Map<String, bool> _requests = {};

  @override
  Future<Response<T>> request<T>(
    String path, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    CancelToken? cancelToken,
    Options? options,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
  }) async {
    if (options?.headers?['prevent-parallel'] == 'true') {
      while (_requests.containsKey(path)) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      _requests[path] = true;
      options!.headers!.remove('prevent-parallel');
    }
    try {
      return super.request<T>(
        path,
        data: data,
        queryParameters: queryParameters,
        cancelToken: cancelToken,
        options: options,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
    } finally {
      if (_requests.containsKey(path)) {
        _requests.remove(path);
      }
    }
  }
}


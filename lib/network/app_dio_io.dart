import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:rhttp/rhttp.dart' as rhttp;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/proxy.dart';

Future<void>? _rhttpInitFuture;
bool _rhttpInitialized = false;

Future<void> nativeInitRhttp() {
  if (_rhttpInitialized) return Future.value();
  return _rhttpInitFuture ??= _initRhttp();
}

Future<void> _initRhttp() async {
  try {
    await rhttp.Rhttp.init();
    _rhttpInitialized = true;
  } catch (e, s) {
    Error.throwWithStackTrace(RhttpInitializationException(e), s);
  } finally {
    if (!_rhttpInitialized) _rhttpInitFuture = null;
  }
}

class RhttpInitializationException implements Exception {
  const RhttpInitializationException(this.cause);

  final Object cause;

  @override
  String toString() =>
      'Failed to initialize rhttp/RustLib. HTTP requests cannot use rhttp. '
      'Cause: $cause';
}

HttpClientAdapter createAppHttpClientAdapter({
  bool enableProxy = true,
  Duration? timeout,
}) => createRHttpAdapter(enableProxy: enableProxy, timeout: timeout);

HttpClientAdapter createRHttpAdapter({
  bool enableProxy = true,
  Duration? timeout,
}) => RHttpAdapter(enableProxy: enableProxy, timeout: timeout);

HttpClientAdapter createIOAdapter({bool enableProxy = true}) =>
    _IOProxyAdapter(enableProxy: enableProxy);

/// A `dart:io` client wired to the app's network settings.
///
/// Paths that deliberately bypass [AppDio] (ranged file downloads, scripts
/// asking for `http_client: dart:io`) must still go through this: `dart:io`
/// trusts only Flutter's built-in root list, never the system store, so a
/// MITM proxy's own root — which the rhttp path accepts — otherwise fails
/// on those paths alone.
HttpClient createIOHttpClient({String? proxy}) {
  final client = HttpClient();
  client.findProxy = (uri) => proxy == null ? 'DIRECT' : 'PROXY $proxy';
  if (appdata.settings['ignoreBadCertificate'] == true) {
    client.badCertificateCallback = (_, __, ___) => true;
  }
  return client;
}

Map<String, List<String>> buildRhttpDnsOverrides({
  required bool enabled,
  required Object? config,
}) {
  if (!enabled || config is! Map) return {};

  final result = <String, List<String>>{};
  for (final entry in config.entries) {
    final host = entry.key;
    if (host is! String || host.trim().isEmpty) continue;

    final value = entry.value;
    final addresses = <String>[];
    if (value is String) {
      final address = value.trim();
      if (address.isNotEmpty) addresses.add(address);
    } else if (value is Iterable) {
      for (final item in value) {
        if (item is! String) continue;
        final address = item.trim();
        if (address.isNotEmpty) addresses.add(address);
      }
    }

    if (addresses.isNotEmpty) {
      result[host.trim()] = addresses;
    }
  }
  return result;
}

rhttp.ClientSettings buildRhttpClientSettings({
  required String? proxy,
  required bool enableDnsOverrides,
  required Object? dnsOverrides,
  required bool sni,
  required bool verifyCertificates,
  Duration? timeout,
}) {
  return rhttp.ClientSettings(
    proxySettings: proxy == null
        ? const rhttp.ProxySettings.noProxy()
        : rhttp.ProxySettings.proxy(proxy),
    redirectSettings: const rhttp.RedirectSettings.limited(5),
    // `connectTimeout` only bounds connection establishment; `timeout` bounds
    // the whole request. Without the latter, a connected-but-stalled socket
    // (e.g. an iOS LAN socket left half-open after a network-state change) hangs
    // forever. Callers needing a hard ceiling (WebDAV sync) pass one in; null
    // keeps the previous unbounded behavior for long streaming image reads.
    timeoutSettings: rhttp.TimeoutSettings(
      timeout: timeout,
      connectTimeout: const Duration(seconds: 15),
      keepAliveTimeout: const Duration(seconds: 60),
      keepAlivePing: const Duration(seconds: 30),
    ),
    throwOnStatusCode: false,
    dnsSettings: rhttp.DnsSettings.static(
      overrides: buildRhttpDnsOverrides(
        enabled: enableDnsOverrides,
        config: dnsOverrides,
      ),
    ),
    tlsSettings: rhttp.TlsSettings(
      sni: sni,
      verifyCertificates: verifyCertificates,
    ),
  );
}

class RHttpAdapter implements HttpClientAdapter {
  RHttpAdapter({this.enableProxy = true, this.timeout});

  final bool enableProxy;

  /// Optional overall request timeout. Null (the default for the app-wide
  /// adapter) leaves requests bounded only by the connect timeout, preserving
  /// the existing behavior for long streaming image reads.
  final Duration? timeout;

  Future<rhttp.ClientSettings> get settings async {
    final proxy = enableProxy ? await getProxy() : null;
    return buildRhttpClientSettings(
      proxy: proxy,
      enableDnsOverrides: appdata.settings['enableDnsOverrides'] == true,
      dnsOverrides: appdata.settings['dnsOverrides'],
      sni: appdata.settings['sni'] != false,
      verifyCertificates: appdata.settings['ignoreBadCertificate'] != true,
      timeout: timeout,
    );
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await nativeInitRhttp();

    if (options.headers['User-Agent'] == null &&
        options.headers['user-agent'] == null) {
      options.headers['User-Agent'] = 'venera/v${App.version}';
    }

    // dio only reports the cancellation to its own caller; without forwarding
    // it the Rust side keeps streaming the body to completion. Harmless for a
    // small response, wasteful for a cancelled multi-hundred-MB download.
    rhttp.CancelToken? cancelToken;
    if (cancelFuture != null) {
      cancelToken = rhttp.CancelToken();
      cancelFuture.whenComplete(() => cancelToken!.cancel());
    }

    final res = await rhttp.Rhttp.request(
      method: rhttp.HttpMethod(options.method),
      url: options.uri.toString(),
      settings: await settings,
      expectBody: rhttp.HttpExpectBody.stream,
      cancelToken: cancelToken,
      body: requestStream == null ? null : rhttp.HttpBody.stream(requestStream),
      headers: rhttp.HttpHeaders.rawMap(
        Map.fromEntries(
          options.headers.entries.map(
            (e) => MapEntry(e.key, e.value.toString().trim()),
          ),
        ),
      ),
    );
    if (res is! rhttp.HttpStreamResponse) {
      throw Exception('Invalid response type: ${res.runtimeType}');
    }

    final headers = <String, List<String>>{};
    for (final entry in res.headers) {
      final key = entry.$1.toLowerCase();
      headers[key] ??= [];
      headers[key]!.add(entry.$2);
    }
    return ResponseBody(
      res.body,
      res.statusCode,
      statusMessage: _getStatusMessage(res.statusCode),
      isRedirect: false,
      headers: headers,
    );
  }

  static String _getStatusMessage(int statusCode) {
    return switch (statusCode) {
      200 => 'OK',
      201 => 'Created',
      202 => 'Accepted',
      204 => 'No Content',
      206 => 'Partial Content',
      301 => 'Moved Permanently',
      302 => 'Found',
      400 => 'Invalid Status Code 400: The Request is invalid.',
      401 => 'Invalid Status Code 401: The Request is unauthorized.',
      403 =>
        'Invalid Status Code 403: No permission to access the resource. Check your account or network.',
      404 => 'Invalid Status Code 404: Not found.',
      429 =>
        'Invalid Status Code 429: Too many requests. Please try again later.',
      _ => 'Invalid Status Code $statusCode',
    };
  }
}

class _IOProxyAdapter implements HttpClientAdapter {
  final bool enableProxy;

  _IOProxyAdapter({this.enableProxy = true});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final proxy = enableProxy ? await getProxy() : null;
    final adapter = IOHttpClientAdapter(
      createHttpClient: () => createIOHttpClient(proxy: proxy),
    );
    return adapter.fetch(options, requestStream, cancelFuture);
  }
}

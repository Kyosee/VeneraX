import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' hide Cookie;
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/webview.dart';
import 'package:venera/utils/io.dart';

import 'cookie_jar.dart';

class CloudflareException implements DioException {
  final String url;

  final Map<String, String> headers;

  CloudflareException(this.url, [this.headers = const {}]);

  @override
  String toString() {
    return "CloudflareException: $url";
  }

  static CloudflareException? fromString(String message) {
    var match = RegExp(r"CloudflareException: (.+)").firstMatch(message);
    if (match == null) return null;
    var url = match.group(1)!;
    return CloudflareException(url, _cloudflareRequestHeaders[url] ?? const {});
  }

  @override
  DioException copyWith({
    RequestOptions? requestOptions,
    Response<dynamic>? response,
    DioExceptionType? type,
    Object? error,
    StackTrace? stackTrace,
    String? message,
  }) {
    return this;
  }

  @override
  Object? get error => this;

  @override
  String? get message => toString();

  @override
  RequestOptions get requestOptions => RequestOptions();

  @override
  Response? get response => null;

  @override
  StackTrace get stackTrace => StackTrace.empty;

  @override
  DioExceptionType get type => DioExceptionType.badResponse;

  @override
  DioExceptionReadableStringBuilder? stringBuilder;
}

class CloudflareInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    if (options.method.toUpperCase() == 'GET' &&
        options.responseType != ResponseType.stream &&
        options.responseType != ResponseType.bytes) {
      var cachedHtml = _takeVerifiedHtml(options.uri);
      if (cachedHtml != null) {
        handler.resolve(
          Response<dynamic>(
            requestOptions: options,
            data: cachedHtml.html,
            statusCode: 200,
            statusMessage: 'OK',
            headers: Headers.fromMap({
              'content-type': ['text/html; charset=utf-8'],
            }),
          ),
        );
        return;
      }
    }

    var cookieHeader = _readHeaderIgnoreCase(options.headers, 'cookie');
    if (_containsCloudflareCookie(_parseCookieHeader(cookieHeader ?? '').keys) ||
        _isCloudflareVerifiedHost(options.uri.host)) {
      _applyBrowserHeaders(options);
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    if (err.response?.statusCode == 403) {
      handler.next(_check(err.response!) ?? err);
    } else {
      handler.next(err);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (response.statusCode == 403) {
      var err = _check(response);
      if (err != null) {
        handler.reject(err);
        return;
      }
    }
    handler.next(response);
  }

  CloudflareException? _check(Response response) {
    if (response.headers['cf-mitigated']?.firstOrNull == "challenge") {
      var uri = response.requestOptions.uri;
      var url = uri.toString();
      _cloudflareRequestHeaders[url] = _headersForBrowser(
        response.requestOptions.headers,
      );
      SingleInstanceCookieJar.instance?.deleteByName(
        uri,
        'cf_clearance',
      );
      _unmarkCloudflareVerifiedHost(uri.host);
      return CloudflareException(url, _cloudflareRequestHeaders[url]!);
    }
    return null;
  }
}

const _cloudflareVerifiedHostsKey = 'cloudflareVerifiedHosts';

final _cloudflareRequestHeaders = <String, Map<String, String>>{};

final _verifiedHtmlCache = <String, _VerifiedHtml>{};

class _VerifiedHtml {
  final String html;

  final DateTime expiresAt;

  _VerifiedHtml(this.html, this.expiresAt);
}

bool _isCloudflareCookieName(String cookieName) {
  var name = cookieName.trim().toLowerCase();
  return name == 'cf_clearance' ||
      name == '__cf_bm' ||
      name == '_cfuvid' ||
      name.startsWith('cf_chl_');
}

bool _containsCloudflareCookie(Iterable<String> cookieNames) {
  return cookieNames.any(_isCloudflareCookieName);
}

Map<String, String> _parseCookieHeader(String cookieHeader) {
  var cookies = <String, String>{};
  if (cookieHeader.trim().isEmpty) {
    return cookies;
  }
  for (var segment in cookieHeader.split(';')) {
    var part = segment.trim();
    if (part.isEmpty) {
      continue;
    }
    var idx = part.indexOf('=');
    if (idx <= 0) {
      continue;
    }
    var name = part.substring(0, idx).trim();
    var value = part.substring(idx + 1).trim();
    if (name.isNotEmpty) {
      cookies[name] = value;
    }
  }
  return cookies;
}

String? _readHeaderIgnoreCase(Map<String, dynamic> headers, String name) {
  for (var entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value?.toString();
    }
  }
  return null;
}

Map<String, String> _headersForBrowser(Map<String, dynamic> headers) {
  const skippedHeaders = {
    'accept-encoding',
    'connection',
    'content-length',
    'cookie',
    'host',
  };
  var result = <String, String>{};
  headers.forEach((key, value) {
    var normalizedKey = key.toLowerCase();
    if (value == null || skippedHeaders.contains(normalizedKey)) {
      return;
    }
    var normalizedValue = value.toString().trim();
    if (normalizedValue.isNotEmpty) {
      result[key] = normalizedValue;
    }
  });
  return result;
}

bool _headersNeedInAppWebview(Map<String, String> headers) {
  const browserControlledHeaders = {
    'accept',
    'accept-language',
    'upgrade-insecure-requests',
    'user-agent',
  };
  return headers.keys.any(
    (key) => !browserControlledHeaders.contains(key.toLowerCase()),
  );
}

bool _isCloudflareChallengePage(String head, String body) {
  var content = "$head\n$body".toLowerCase();
  return content.contains('#challenge-success-text') ||
      content.contains("#challenge-error-text") ||
      content.contains("#challenge-form") ||
      content.contains("challenge-platform") ||
      content.contains("/cdn-cgi/challenge-platform/") ||
      content.contains("window._cf_chl_opt") ||
      content.contains("__cf_chl_opt") ||
      content.contains("cf-browser-verification") ||
      content.contains("cf-challenge-running") ||
      content.contains("cf-challenge") ||
      content.contains("cf-turnstile") ||
      content.contains("cf_captcha_kind") ||
      content.contains("cf_chl_") ||
      content.contains("verify you are human") ||
      content.contains("checking your browser before accessing") ||
      content.contains("checking if the site connection is secure") ||
      content.contains("please wait while we verify") ||
      content.contains("<title>just a moment") ||
      content.contains("just a moment...");
}

String _normalizeDesktopWebviewValue(String? raw, String fallback) {
  if (raw == null || raw.isEmpty) {
    return fallback;
  }
  var value = raw.trim();
  try {
    var decoded = jsonDecode(value);
    if (decoded is String) {
      value = decoded;
    } else if (decoded != null) {
      value = decoded.toString();
    }
  } catch (_) {
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
  }
  value = value.trim();
  if (value.isEmpty) {
    return fallback;
  }
  return value;
}

String _verifiedHtmlCacheKey(Uri uri) => uri.toString();

bool _cacheVerifiedHtml(Uri uri, String html) {
  if (html.trim().isEmpty || _isCloudflareChallengePage('', html)) {
    return false;
  }
  _verifiedHtmlCache[_verifiedHtmlCacheKey(uri)] = _VerifiedHtml(
    html,
    DateTime.now().add(const Duration(minutes: 2)),
  );
  Log.info("Cloudflare", "Cached verified WebView HTML for $uri");
  return true;
}

_VerifiedHtml? _takeVerifiedHtml(Uri uri) {
  var cached = _verifiedHtmlCache.remove(_verifiedHtmlCacheKey(uri));
  if (cached == null || cached.expiresAt.isBefore(DateTime.now())) {
    return null;
  }
  Log.info("Cloudflare", "Using cached verified WebView HTML for $uri");
  return cached;
}

bool _sameSiteHost(String a, String b) {
  var left = a.toLowerCase();
  var right = b.toLowerCase();
  String site(String host) {
    var parts = host.split('.');
    if (parts.length <= 2) {
      return host;
    }
    return parts.sublist(parts.length - 2).join('.');
  }

  return left == right ||
      left.endsWith('.$right') ||
      right.endsWith('.$left') ||
      site(left) == site(right);
}

void _applyBrowserHeaders(RequestOptions options) {
  _setHeader(options, 'User-Agent', appdata.implicitData['ua'] ?? webUA);
  _putHeaderIfAbsent(
    options,
    'Accept',
    'text/html,application/xhtml+xml,application/xml;q=0.9,'
        'image/avif,image/webp,image/apng,*/*;q=0.8',
  );
  _putHeaderIfAbsent(options, 'Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8');
  if (options.method.toUpperCase() == 'GET') {
    _putHeaderIfAbsent(options, 'Upgrade-Insecure-Requests', '1');
  }
}

void _setHeader(RequestOptions options, String name, Object value) {
  var keys = options.headers.keys
      .where((key) => key.toLowerCase() == name.toLowerCase())
      .toList();
  for (var key in keys) {
    options.headers.remove(key);
  }
  options.headers[name] = value;
}

void _putHeaderIfAbsent(RequestOptions options, String name, Object value) {
  var exists = options.headers.keys.any(
    (key) => key.toLowerCase() == name.toLowerCase(),
  );
  if (!exists) {
    options.headers[name] = value;
  }
}

bool _isCloudflareVerifiedHost(String host) {
  var data = appdata.implicitData[_cloudflareVerifiedHostsKey];
  return data is List && data.contains(host);
}

void _markCloudflareVerifiedHost(String host) {
  var data = appdata.implicitData[_cloudflareVerifiedHostsKey];
  var hosts = data is List ? data.whereType<String>().toSet() : <String>{};
  if (hosts.add(host)) {
    appdata.implicitData[_cloudflareVerifiedHostsKey] = hosts.toList();
    appdata.writeImplicitData();
  }
}

void _unmarkCloudflareVerifiedHost(String host) {
  var data = appdata.implicitData[_cloudflareVerifiedHostsKey];
  if (data is! List) {
    return;
  }
  var hosts = data.whereType<String>().toSet();
  if (hosts.remove(host)) {
    appdata.implicitData[_cloudflareVerifiedHostsKey] = hosts.toList();
    appdata.writeImplicitData();
  }
}

String _cloudflareProfilePath(Uri uri) {
  var host = uri.host.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
  return "${App.dataPath}\\cloudflare_webview\\$host";
}

void _resetCloudflareProfile(Uri uri) {
  if (!App.isWindows) {
    return;
  }
  try {
    var dir = Directory(_cloudflareProfilePath(uri));
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  } catch (e, s) {
    Log.warning(
      "Cloudflare",
      "Failed to reset Cloudflare webview profile\n$e\n$s",
    );
  }
}

void passCloudflare(CloudflareException e, void Function() onFinished) async {
  var url = e.url;
  var uri = Uri.parse(url);
  var requestHeaders = e.headers;
  var completed = false;
  var verificationSucceeded = false;
  SingleInstanceCookieJar.instance?.deleteByName(uri, 'cf_clearance');
  _resetCloudflareProfile(uri);

  void finish() {
    if (completed) {
      return;
    }
    completed = true;
    if (verificationSucceeded) {
      _cloudflareRequestHeaders.remove(url);
      onFinished();
    }
  }

  bool saveCookies(Uri targetUri, Map<String, String> cookies) {
    if (cookies.isEmpty) {
      Log.info("Cloudflare", "Saved 0 cookies, cloudflareCookie=false");
      return false;
    }
    var domain = targetUri.host;
    var splits = domain.split('.');
    if (splits.length > 1) {
      domain = ".${splits[splits.length - 2]}.${splits[splits.length - 1]}";
    }
    var hasCloudflareCookie = _containsCloudflareCookie(cookies.keys);
    SingleInstanceCookieJar.instance?.deleteByName(targetUri, 'cf_clearance');
    SingleInstanceCookieJar.instance?.saveFromResponse(
      targetUri,
      List<Cookie>.generate(cookies.length, (index) {
        var cookie = Cookie(
          cookies.keys.elementAt(index),
          cookies.values.elementAt(index),
        );
        cookie.domain = domain;
        return cookie;
      }),
    );
    Log.info(
      "Cloudflare",
      "Saved ${cookies.length} cookies, "
          "cloudflareCookie=$hasCloudflareCookie",
    );
    if (hasCloudflareCookie) {
      _markCloudflareVerifiedHost(targetUri.host);
    }
    return hasCloudflareCookie;
  }

  // Desktop WebView can read cookies more reliably, but it cannot replay
  // request headers like Referer that some image/CDN challenges require.
  var useDesktopWebview = false;
  if (App.isDesktop && !_headersNeedInAppWebview(requestHeaders)) {
    try {
      useDesktopWebview = await DesktopWebview.isAvailable();
    } catch (e, s) {
      Log.warning(
        "Cloudflare",
        "Desktop webview is unavailable, fallback to AppWebview\n$e\n$s",
      );
    }
  }

  if (useDesktopWebview) {
    var webview = DesktopWebview(
      initialUrl: url,
      userDataFolderWindows: _cloudflareProfilePath(uri),
      onTitleChange: (title, controller) async {
        var currentUrl = _normalizeDesktopWebviewValue(
          await controller.evaluateJavascript("location.href"),
          url,
        );
        var currentUri = Uri.tryParse(currentUrl) ?? uri;
        var head = _normalizeDesktopWebviewValue(
          await controller.evaluateJavascript(
            "(document.head && document.head.innerHTML) || ''",
          ),
          '',
        );
        var body = _normalizeDesktopWebviewValue(
          await controller.evaluateJavascript(
            "(document.body && document.body.innerHTML) || ''",
          ),
          '',
        );
        Log.info("Cloudflare", "Checking head: $head");
        var isChallenging = _isCloudflareChallengePage(head, body);
        if (!isChallenging) {
          Log.info(
            "Cloudflare",
            "No Cloudflare challenge markers found",
          );
          var ua = controller.userAgent;
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var html = _normalizeDesktopWebviewValue(
            await controller.evaluateJavascript(
              "(document.documentElement && document.documentElement.outerHTML) || ''",
            ),
            '',
          );
          var hasVerifiedHtml = false;
          if (_sameSiteHost(currentUri.host, uri.host)) {
            hasVerifiedHtml = _cacheVerifiedHtml(uri, html);
            hasVerifiedHtml =
                _cacheVerifiedHtml(currentUri, html) || hasVerifiedHtml;
          }
          var cookiesMap = await controller.getCookies(currentUrl);
          try {
            var rawCookie = await controller.evaluateJavascript(
              "document.cookie",
            );
            cookiesMap.addAll(
              _parseCookieHeader(
                _normalizeDesktopWebviewValue(rawCookie, ''),
              ),
            );
          } catch (e, s) {
            Log.warning("Cloudflare", "Read document.cookie failed\n$e\n$s");
          }
          var hasCloudflareCookie = saveCookies(currentUri, cookiesMap);
          if (hasCloudflareCookie || hasVerifiedHtml) {
            _markCloudflareVerifiedHost(uri.host);
            _markCloudflareVerifiedHost(currentUri.host);
            verificationSucceeded = true;
            controller.close();
            finish();
          } else {
            Log.info("Cloudflare", "Waiting for Cloudflare cookie or HTML");
          }
        }
      },
      onClose: finish,
    );
    webview.open();
  } else {
    bool success = false;
    void check(InAppWebViewController controller) async {
      if (success) {
        return;
      }
      var head =
          (await controller.evaluateJavascript(
            source: "document.head.innerHTML",
          ))?.toString() ??
          "";
      var body =
          (await controller.evaluateJavascript(
            source: "document.body.innerHTML",
          ))?.toString() ??
          "";
      Log.info("Cloudflare", "Checking head: $head");
      var isChallenging = _isCloudflareChallengePage(head, body);
      if (!isChallenging) {
        Log.info(
          "Cloudflare",
          "No Cloudflare challenge markers found",
        );
        var ua = await controller.getUA();
        if (ua != null) {
          appdata.implicitData['ua'] = ua;
          appdata.writeImplicitData();
        }
        var currentUrl = (await controller.getUrl())?.toString() ?? url;
        var currentUri = Uri.tryParse(currentUrl) ?? uri;
        var htmlText =
            (await controller.evaluateJavascript(
              source:
                  "(document.documentElement && document.documentElement.outerHTML) || ''",
            ))?.toString() ??
            '';
        var hasVerifiedHtml = false;
        if (_sameSiteHost(currentUri.host, uri.host)) {
          hasVerifiedHtml = _cacheVerifiedHtml(uri, htmlText);
          hasVerifiedHtml =
              _cacheVerifiedHtml(currentUri, htmlText) || hasVerifiedHtml;
        }
        var cookies = <Cookie>[];
        for (var cookieUrl in {url, currentUrl}) {
          cookies.addAll(
            cookiesFromPlatformCookies(
              await controller.getCookies(cookieUrl),
              fallbackDomain: currentUri.host,
            ),
          );
        }
        try {
          var rawCookie = await controller.evaluateJavascript(
            source: "document.cookie",
          );
          var jsCookies = _parseCookieHeader(rawCookie?.toString() ?? '');
          cookies.addAll(
            jsCookies.entries.map((e) {
              var cookie = Cookie(e.key, e.value);
              cookie.domain = currentUri.host;
              return cookie;
            }),
          );
        } catch (e, s) {
          Log.warning("Cloudflare", "Read document.cookie failed\n$e\n$s");
        }
        var hasCloudflareCookie = cookies.any(
          (cookie) =>
              cookie.value.isNotEmpty && _isCloudflareCookieName(cookie.name),
        );
        SingleInstanceCookieJar.instance?.deleteByName(
          currentUri,
          'cf_clearance',
        );
        SingleInstanceCookieJar.instance?.saveFromResponse(currentUri, cookies);
        Log.info(
          "Cloudflare",
          "Saved ${cookies.length} cookies, "
              "cloudflareCookie=$hasCloudflareCookie",
        );
        if (hasCloudflareCookie || hasVerifiedHtml) {
          _markCloudflareVerifiedHost(uri.host);
          _markCloudflareVerifiedHost(currentUri.host);
          success = true;
          verificationSucceeded = true;
          App.rootPop();
        } else {
          Log.info("Cloudflare", "Waiting for Cloudflare cookie or HTML");
        }
      }
    }

    await App.rootContext.to(
      () => AppWebview(
        initialUrl: url,
        initialHeaders: requestHeaders.isEmpty ? null : requestHeaders,
        singlePage: true,
        onTitleChange: (title, controller) async {
          // Keep the webview open until page load stops; title changes can fire
          // before Cloudflare has flushed cookies to the platform store.
        },
        onLoadStop: (controller) async {
          check(controller);
        },
        onStarted: (controller) async {
          var ua = await controller.getUA();
          if (ua != null) {
            appdata.implicitData['ua'] = ua;
            appdata.writeImplicitData();
          }
          var startedUrl = (await controller.getUrl())?.toString() ?? url;
          var startedUri = Uri.tryParse(startedUrl) ?? uri;
          var cookies = cookiesFromPlatformCookies(
            await controller.getCookies(startedUrl),
            fallbackDomain: startedUri.host,
          );
          if (cookies.isNotEmpty) {
            SingleInstanceCookieJar.instance?.saveFromResponse(
              startedUri,
              cookies,
            );
          }
        },
      ),
    );
    finish();
  }
}

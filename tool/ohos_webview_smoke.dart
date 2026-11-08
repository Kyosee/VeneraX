import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../test/fixtures/tls_fixture.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _Fixture {
  _Fixture(this.first, this.second, this.tls, this.proxy);

  final io.HttpServer first;
  final io.HttpServer second;
  final io.HttpServer tls;
  final io.HttpServer proxy;
  final token =
      'venera_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
  final counts = <String, int>{};
  Future<void>? _closing;
  String? failure;
  int tlsRequests = 0;
  bool initialHeaders = false;

  String get path => '/$token/';
  String get visibleCookie => '${token}_visible';
  String get secretCookie => '${token}_http_only';
  String get nativeCookie => '${token}_native';
  String get originA => 'http://127.0.0.1:${first.port}';
  String get originB => 'http://127.0.0.1:${second.port}';
  String get landing => '$originA${path}landing';
  String get tlsUrl => 'https://127.0.0.1:${tls.port}${path}tls';

  static Future<_Fixture> start() async {
    final opened = <io.HttpServer>[];
    try {
      final a = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      opened.add(a);
      final b = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      opened.add(b);
      final context = io.SecurityContext()
        ..useCertificateChainBytes(utf8.encode(probeCertificate))
        ..usePrivateKeyBytes(utf8.encode(probePrivateKey));
      final tls = await io.HttpServer.bindSecure(
        io.InternetAddress.loopbackIPv4,
        0,
        context,
      );
      opened.add(tls);
      final proxy = await io.HttpServer.bind(
        io.InternetAddress.loopbackIPv4,
        0,
      );
      opened.add(proxy);
      final fixture = _Fixture(a, b, tls, proxy);
      a.listen((request) => fixture.serve(request, 'A'));
      b.listen((request) => fixture.serve(request, 'B'));
      proxy.listen((request) => fixture.serve(request, 'proxy'));
      tls.listen((request) async {
        fixture.tlsRequests++;
        request.response.write('TLS certificate was incorrectly accepted.');
        await request.response.close();
      }, onError: (Object _) {});
      return fixture;
    } catch (_) {
      for (final server in opened) {
        await server.close(force: true);
      }
      rethrow;
    }
  }

  Future<void> serve(io.HttpRequest request, String origin) async {
    try {
      if (request.uri.path == '/favicon.ico') {
        request.response.statusCode = io.HttpStatus.noContent;
        return;
      }
      check(
        request.uri.path.startsWith(path),
        'Unexpected fixture request path.',
      );
      final page = request.uri.path.substring(path.length);
      final countKey = '$origin/$page';
      counts[countKey] = (counts[countKey] ?? 0) + 1;
      request.response.headers.set(
        io.HttpHeaders.cacheControlHeader,
        'no-store',
      );
      if (page == 'start') {
        check(origin == 'A', 'Unexpected redirect origin.');
        check(
          request.headers.value('X-Venera-Probe') == token,
          'Initial custom request header was lost.',
        );
        check(
          request.headers.value(io.HttpHeaders.refererHeader) ==
              '$originA${path}referrer',
          'Initial Referer header changed: ${request.headers.value(io.HttpHeaders.refererHeader)}',
        );
        initialHeaders = true;
        request.response.statusCode = io.HttpStatus.found;
        request.response.headers.set(
          io.HttpHeaders.locationHeader,
          '${path}landing',
        );
        return;
      }
      if (origin == 'A' && page == 'landing') {
        request.response.cookies.add(
          io.Cookie(visibleCookie, 'visible')
            ..path = path
            ..httpOnly = false,
        );
        request.response.cookies.add(
          io.Cookie(secretCookie, 'secret')
            ..path = path
            ..httpOnly = true,
        );
      }
      if (page == 'echo' || page == 'deleted') {
        final cookies = {
          for (final cookie in request.cookies) cookie.name: cookie.value,
        };
        check(
          cookies[visibleCookie] == 'visible' &&
              cookies[secretCookie] == 'secret',
          'Network cookies were not sent back to the server.',
        );
        check(
          page == 'echo'
              ? cookies[nativeCookie] == 'native'
              : !cookies.containsKey(nativeCookie),
          'Native CookieManager update did not reach the server.',
        );
      }
      request.response.headers.contentType = io.ContentType.html;
      request.response.write(
        '''<!doctype html><html><head><meta charset="utf-8">
<title>Venera probe $origin</title></head><body><h1>本地 WebView 验证 $origin</h1>
<script>window.__veneraProbeExecuted = 0;</script></body></html>''',
      );
    } catch (error) {
      failure = error.toString();
      request.response.statusCode = io.HttpStatus.internalServerError;
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() => _closing ??= Future.wait(
    [first, second, tls, proxy].map((server) => server.close(force: true)),
  ).then((_) {});
}

class _NavigationFailure implements Exception {
  _NavigationFailure(this.error);
  final WebResourceError error;

  @override
  String toString() =>
      'WebView navigation failed: ${error.type}: ${error.description}';
}

class _WebViewProbe extends StatefulWidget {
  const _WebViewProbe(this.fixture);
  final _Fixture fixture;

  @override
  State<_WebViewProbe> createState() => _WebViewProbeState();
}

class _WebViewProbeState extends State<_WebViewProbe> {
  final _created = Completer<InAppWebViewController>();
  final _initial = Completer<void>();
  final _initialTitle = Completer<void>();
  final _initialProgress = Completer<void>();
  final _clock = Stopwatch();
  Duration _budget = const Duration(seconds: 90);
  final _loadStarts = <String>[];
  final _titles = <String>[];
  Completer<void>? _pending;
  String? _pendingUrl;
  String _status = 'Running local WebView checks…';
  String _step = 'platform view creation';
  bool _finished = false;
  bool _disposed = false;
  bool _cleaningUp = false;
  int _progress = 0;

  _Fixture get f => widget.fixture;
  String get _localKey => '${f.token}_local';
  String get _sessionKey => '${f.token}_session';
  List<String> get _hostileKeys => [
    '${f.token}_double", "ignored"); window.__veneraProbeExecuted = 1; //',
    "${f.token}_single', 'ignored'); window.__veneraProbeExecuted = 1; //",
    '${f.token}_quotes"\'\\\n中文',
  ];

  @override
  void initState() {
    super.initState();
    _created.future.ignore();
    _initial.future.ignore();
    _clock.start();
    unawaited(_run());
  }

  Future<T> _call<T>(
    Future<T> Function() action, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    check(!_disposed, 'Probe view was disposed.');
    final remaining = _budget - _clock.elapsed;
    if (remaining <= Duration.zero) {
      throw TimeoutException('Probe time budget expired.');
    }
    final value = await action().timeout(
      remaining < timeout ? remaining : timeout,
    );
    check(!_disposed, 'Probe view was disposed.');
    return value;
  }

  Future<dynamic> _evaluate(
    InAppWebViewController controller, {
    required String source,
  }) => _call(() => controller.evaluateJavascript(source: source));

  Future<void> _run() async {
    String result;
    try {
      await _checks();
      result =
          'PASS: WebView initial headers and redirect, URL/title/progress, '
          'JavaScript values, native and HttpOnly cookies, local/session storage, '
          'quoted keys without script execution, cross-origin isolation and reload, '
          'custom/direct/system proxy switching, '
          'default rejection of local self-signed TLS.';
    } catch (error, stack) {
      result =
          'FAIL: $_step: $error\n'
          'Fixture: ${f.failure}; requests: ${f.counts}; '
          'created: ${_created.isCompleted}; loaded: ${_initial.isCompleted}; '
          'title: ${_initialTitle.isCompleted}; progress: ${_initialProgress.isCompleted}\n$stack';
    }
    _cleaningUp = true;
    _budget = const Duration(seconds: 15);
    _clock.reset();
    try {
      if (_created.isCompleted && !_disposed) {
        await _cleanup();
      }
    } catch (error) {
      result += '\nCLEANUP FAILED: $error';
      if (result.startsWith('PASS:')) result = 'FAIL: $result';
    }
    try {
      await f.close();
    } catch (error) {
      result += '\nFIXTURE CLOSE FAILED: $error';
      if (result.startsWith('PASS:')) result = 'FAIL: $result';
    }
    _finished = true;
    debugPrint(result);
    if (mounted) setState(() => _status = result);
  }

  void _onLoadStop(WebUri? url) {
    final value = url?.toString();
    if (!_initial.isCompleted && value == f.landing) _initial.complete();
    if (value == _pendingUrl && _pending?.isCompleted == false) {
      _pending!.complete();
    }
  }

  void _onError(WebResourceRequest request, WebResourceError error) {
    if (request.isForMainFrame == false) return;
    final value = request.url.toString();
    final failure = _NavigationFailure(error);
    if (!_initial.isCompleted &&
        (value == f.landing || value == '${f.originA}${f.path}start')) {
      _initial.completeError(failure);
    }
    if (value == _pendingUrl && _pending?.isCompleted == false) {
      _pending!.completeError(failure);
    }
  }

  Future<void> _navigate(String url, {bool reload = false}) async {
    check(!_finished, 'Probe already finished.');
    final controller = await _call(() => _created.future);
    final done = Completer<void>();
    done.future.ignore();
    _pending = done;
    _pendingUrl = url;
    try {
      await _call(
        () => Future.wait<void>([
          done.future,
          reload
              ? controller.reload()
              : controller.loadUrl(urlRequest: URLRequest(url: WebUri(url))),
        ], eagerError: true),
      );
      if (!_cleaningUp) {
        check(f.failure == null, 'Fixture server failed: ${f.failure}');
      }
      check(
        (await _call(controller.getUrl)).toString() == url,
        'Current URL did not match loaded page.',
      );
    } finally {
      if (identical(_pending, done)) {
        _pending = null;
        _pendingUrl = null;
      }
    }
  }

  Future<void> _checks() async {
    await _call(
      () => Future.wait<Object?>([
        _created.future,
        _initial.future,
        _initialTitle.future,
        _initialProgress.future,
      ], eagerError: true),
      timeout: const Duration(seconds: 20),
    );
    final controller = await _call(() => _created.future);
    check(f.failure == null, 'Fixture server failed: ${f.failure}');
    check(
      f.initialHeaders &&
          (f.counts['A/start'] ?? 0) == 1 &&
          (f.counts['A/landing'] ?? 0) > 0,
      'The initial navigation did not follow the real redirect.',
    );
    check(
      (await _call(controller.getUrl)).toString() == f.landing,
      'Redirected URL was lost.',
    );
    check(
      await _call(controller.getTitle) == 'Venera probe A',
      'Page title was lost.',
    );
    check(
      _loadStarts.any((url) => url.startsWith('${f.originA}${f.path}')),
      'Load-start callback missing.',
    );
    check(
      _titles.contains('Venera probe A') && _progress == 100,
      'Title/progress callbacks missing.',
    );

    _step = 'JavaScript return values';
    const quoted = '鸿蒙 "double" \'single\' \\ newline\n';
    check(
      await _evaluate(controller, source: jsonEncode(quoted)) == quoted,
      'JS string was encoded incorrectly.',
    );
    check(
      await _evaluate(controller, source: 'null') == null,
      'JS null changed.',
    );
    check(
      await _evaluate(controller, source: 'true') == true,
      'JS boolean changed.',
    );
    check(
      await _evaluate(controller, source: '7.5') == 7.5,
      'JS number changed.',
    );
    final object = await _evaluate(
      controller,
      source: '({message: "鸿蒙", items: [1, false, null]})',
    );
    check(
      object is Map &&
          object['message'] == '鸿蒙' &&
          listEquals(object['items'] as List?, [1, false, null]),
      'JS object or array changed.',
    );
    final userAgent = await _evaluate(
      controller,
      source: 'navigator.userAgent',
    );
    check(
      userAgent is String && userAgent.isNotEmpty,
      'User agent unavailable.',
    );

    _step = 'native and HttpOnly cookies';
    final manager = CookieManager.instance();
    final cookieUrl = WebUri(f.landing);
    final cookies = await _call(
      () => manager.getCookies(url: cookieUrl, webViewController: controller),
    );
    check(
      cookies.any(
        (cookie) => cookie.name == f.visibleCookie && cookie.value == 'visible',
      ),
      'Native visible cookie missing.',
    );
    check(
      cookies.any(
        (cookie) => cookie.name == f.secretCookie && cookie.value == 'secret',
      ),
      'Native HttpOnly cookie missing.',
    );
    final scriptCookies = await _evaluate(
      controller,
      source: 'document.cookie',
    );
    check(
      scriptCookies is String &&
          scriptCookies.contains('${f.visibleCookie}=visible') &&
          !scriptCookies.contains(f.secretCookie),
      'Visible cookie missing or HttpOnly cookie exposed: $scriptCookies',
    );
    check(
      await _call(
        () => manager.setCookie(
          url: cookieUrl,
          name: f.nativeCookie,
          value: 'native',
          path: f.path,
          isHttpOnly: true,
          webViewController: controller,
        ),
      ),
      'Native cookie write failed.',
    );
    check(
      !(await _evaluate(controller, source: 'document.cookie') as String)
          .contains(f.nativeCookie),
      'Native HttpOnly cookie leaked to JavaScript.',
    );
    await _navigate('${f.originA}${f.path}echo');
    check(
      await _call(
        () => manager.deleteCookie(
          url: cookieUrl,
          name: f.nativeCookie,
          path: f.path,
          webViewController: controller,
        ),
      ),
      'Native cookie deletion failed.',
    );
    await _navigate('${f.originA}${f.path}deleted');

    _step = 'real local and session storage';
    final local = controller.webStorage.localStorage;
    final session = controller.webStorage.sessionStorage;
    await _call(() => local.setItem(key: _localKey, value: quoted));
    await _call(() => session.setItem(key: _sessionKey, value: 'session A'));
    check(
      await _call(() => local.getItem(key: _localKey)) == quoted,
      'Local storage read failed.',
    );
    check(
      await _call(() => session.getItem(key: _sessionKey)) == 'session A',
      'Session storage read failed.',
    );
    check(
      await _evaluate(
            controller,
            source: 'localStorage.getItem(${jsonEncode(_localKey)})',
          ) ==
          quoted,
      'Local data did not reach browser storage.',
    );
    check(
      await _evaluate(
            controller,
            source: 'sessionStorage.getItem(${jsonEncode(_sessionKey)})',
          ) ==
          'session A',
      'Session data did not reach browser storage.',
    );
    final items = await _call(local.getItems);
    check(
      items.any((item) => item.key == _localKey && item.value == quoted),
      'Storage item enumeration changed.',
    );

    _step = 'storage key script injection';
    for (final storage in <Storage>[local, session]) {
      for (final key in _hostileKeys) {
        await _call(() => storage.setItem(key: key, value: quoted));
        check(
          await _evaluate(controller, source: 'window.__veneraProbeExecuted') ==
              0,
          'A storage key executed JavaScript.',
        );
        check(
          await _call(() => storage.getItem(key: key)) == quoted,
          'Quoted storage key did not round trip.',
        );
        check(
          await _evaluate(controller, source: 'window.__veneraProbeExecuted') ==
              0,
          'Reading a storage key executed JavaScript.',
        );
        await _call(() => storage.removeItem(key: key));
        check(
          await _evaluate(controller, source: 'window.__veneraProbeExecuted') ==
              0,
          'Removing a storage key executed JavaScript.',
        );
        check(
          await _call(() => storage.getItem(key: key)) == null,
          'Quoted storage key was not removed.',
        );
      }
    }

    _step = 'origin isolation';
    await _navigate('${f.originB}${f.path}landing');
    check(
      await _call(() => local.getItem(key: _localKey)) == null &&
          await _call(() => session.getItem(key: _sessionKey)) == null,
      'Storage values leaked to another port origin.',
    );
    check(
      !(await _call(local.getItems)).any((item) => item.key == _localKey) &&
          !(await _call(
            session.getItems,
          )).any((item) => item.key == _sessionKey),
      'Storage enumeration leaked across origins.',
    );
    await _call(() => local.setItem(key: _localKey, value: 'local B'));
    await _call(() => session.setItem(key: _sessionKey, value: 'session B'));
    await _navigate('${f.originA}${f.path}landing');
    check(
      await _call(() => local.getItem(key: _localKey)) == quoted &&
          await _call(() => session.getItem(key: _sessionKey)) == 'session A',
      'Origin A storage was replaced by origin B.',
    );
    await _navigate(f.landing, reload: true);
    check(
      await _call(() => local.getItem(key: _localKey)) == quoted &&
          await _call(() => session.getItem(key: _sessionKey)) == 'session A',
      'Storage did not survive same-view reload.',
    );
    await _navigate('${f.originB}${f.path}landing');
    check(
      await _call(() => local.getItem(key: _localKey)) == 'local B' &&
          await _call(() => session.getItem(key: _sessionKey)) == 'session B',
      'Origin B storage was replaced by origin A.',
    );

    _step = 'custom/direct/system proxy switching';
    check(
      await _call(
        () => WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE),
      ),
      'Proxy override is unavailable.',
    );
    final proxyController = ProxyController.instance();
    Future<void> customProxy(String page) async {
      await _call(proxyController.clearProxyOverride);
      await _call(
        () => proxyController.setProxyOverride(
          settings: ProxySettings(
            proxyRules: [ProxyRule(url: 'http://127.0.0.1:${f.proxy.port}')],
            removeImplicitRules: true,
          ),
        ),
      );
      await _navigate('${f.originA}${f.path}$page');
      check(
        f.counts['proxy/$page'] == 1 && f.counts['A/$page'] == null,
        'Custom proxy was not used.',
      );
    }

    await customProxy('proxy-custom');
    await _call(proxyController.clearProxyOverride);
    await _call(
      () => proxyController.setProxyOverride(
        settings: ProxySettings(directs: ['*']),
      ),
    );
    await _navigate('${f.originA}${f.path}proxy-direct');
    check(
      f.counts['A/proxy-direct'] == 1 && f.counts['proxy/proxy-direct'] == null,
      'Direct mode retained the custom proxy.',
    );
    await customProxy('proxy-again');
    await _call(proxyController.clearProxyOverride);
    await _navigate('${f.originA}${f.path}proxy-system');
    check(
      f.counts['A/proxy-system'] == 1 && f.counts['proxy/proxy-system'] == null,
      'System mode retained the custom proxy.',
    );

    _step = 'default TLS rejection';
    Object? rejection;
    try {
      await _navigate(f.tlsUrl);
    } catch (error) {
      rejection = error;
    }
    check(
      rejection is _NavigationFailure,
      'No explicit certificate navigation error (or TLS was accepted): $rejection',
    );
    final failure = rejection as _NavigationFailure;
    check(
      RegExp(
        'ssl|tls|cert|trust',
        caseSensitive: false,
      ).hasMatch('${failure.error.type} ${failure.error.description}'),
      'TLS failed for a reason other than certificate validation: $failure',
    );
    check(
      f.tlsRequests == 0,
      'WebView sent HTTP data despite an untrusted certificate.',
    );
  }

  Future<void> _cleanup() async {
    await _call(ProxyController.instance().clearProxyOverride);
    final controller = await _call(() => _created.future);
    final keys = [
      _localKey,
      _sessionKey,
      ..._hostileKeys,
      '${f.token}_double',
      '${f.token}_single',
    ];
    for (final origin in [f.originB, f.originA]) {
      await _navigate('$origin${f.path}landing');
      await _evaluate(
        controller,
        source:
            '''
        ${jsonEncode(keys)}.forEach(function(key) {
          localStorage.removeItem(key); sessionStorage.removeItem(key);
        });
      ''',
      );
    }
    final manager = CookieManager.instance();
    for (final name in [f.visibleCookie, f.secretCookie, f.nativeCookie]) {
      await _call(
        () => manager.deleteCookie(
          url: WebUri(f.landing),
          name: name,
          path: f.path,
          webViewController: controller,
        ),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_initial.isCompleted) {
      _initial.completeError(StateError('Probe view was disposed.'));
    }
    if (_pending?.isCompleted == false) {
      _pending!.completeError(StateError('Probe view was disposed.'));
    }
    unawaited(
      f.close().catchError((Object error) {
        debugPrint('FAIL: WebView fixture disposal: $error');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('HarmonyOS WebView probe')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(_status),
        ),
        if (!_finished)
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('${f.originA}${f.path}start'),
                headers: {
                  'X-Venera-Probe': f.token,
                  'Referer': '${f.originA}${f.path}referrer',
                },
              ),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                domStorageEnabled: true,
              ),
              onWebViewCreated: (controller) {
                if (!_created.isCompleted) _created.complete(controller);
              },
              onLoadStart: (_, url) => _loadStarts.add(url?.toString() ?? ''),
              onLoadStop: (_, url) => _onLoadStop(url),
              onReceivedError: (_, request, error) => _onError(request, error),
              onTitleChanged: (_, title) {
                if (title != null) _titles.add(title);
                if (title == 'Venera probe A' && !_initialTitle.isCompleted) {
                  _initialTitle.complete();
                }
              },
              onProgressChanged: (_, progress) {
                _progress = progress;
                if (progress == 100 && !_initialProgress.isCompleted) {
                  _initialProgress.complete();
                }
              },
              // No trust callback: the platform must reject this certificate by default.
            ),
          ),
      ],
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final fixture = await _Fixture.start();
    runApp(MaterialApp(home: _WebViewProbe(fixture)));
  } catch (error, stack) {
    final message = 'FAIL: WebView fixture startup: $error\n$stack';
    debugPrint(message);
    runApp(
      MaterialApp(
        home: Scaffold(body: SafeArea(child: SelectableText(message))),
      ),
    );
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rhttp/rhttp.dart' hide HttpHeaders, HttpResponse;
import 'package:venera/network/app_dio_io.dart';

import '../test/fixtures/tls_fixture.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> rejects<T>(Future<Object?> operation) async {
  try {
    await operation;
  } catch (error) {
    if (error is T) return;
    rethrow;
  }
  throw StateError('Expected $T.');
}

Future<String> backgroundRequest(String url) async {
  await nativeInitRhttp();
  final client = await RhttpClient.create(
    settings: const ClientSettings(proxySettings: ProxySettings.noProxy()),
  );
  try {
    return (await client.get(url)).body;
  } finally {
    client.dispose();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final servers = <HttpServer>[];
  final clients = <RhttpClient>[];
  final delayed = <HttpResponse>[];
  String result;
  try {
    await nativeInitRhttp();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(server);
    server.listen((request) async {
      if (request.uri.path == '/slow') {
        delayed.add(request.response);
        return;
      }
      if (request.uri.path == '/cookie/set') {
        request.response.cookies.add(Cookie('venera', 'probe')..path = '/');
      } else if (request.uri.path == '/cookie/get') {
        request.response.write(
          request.headers.value(HttpHeaders.cookieHeader) ?? '',
        );
      } else if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(HttpHeaders.locationHeader, '/text');
      } else {
        request.response.write('Venera 鸿蒙 HTTP');
      }
      await request.response.close();
    });
    final client = await RhttpClient.create(
      settings: const ClientSettings(
        proxySettings: ProxySettings.noProxy(),
        cookieSettings: CookieSettings(storeCookies: true),
        dnsSettings: DnsSettings.static(
          overrides: {
            'venera-probe.invalid': ['127.0.0.1'],
          },
        ),
        timeoutSettings: TimeoutSettings(timeout: Duration(seconds: 5)),
      ),
    );
    clients.add(client);
    final base = 'http://venera-probe.invalid:${server.port}';
    check(
      (await client.get('$base/text')).body == 'Venera 鸿蒙 HTTP',
      'HTTP/DNS/Unicode failed.',
    );
    check(
      (await client.get('$base/redirect')).body == 'Venera 鸿蒙 HTTP',
      'Redirect failed.',
    );
    await client.get('$base/cookie/set');
    check(
      (await client.get('$base/cookie/get')).body.contains('venera=probe'),
      'Cookie failed.',
    );
    final stream = await client.getStream('$base/text');
    check(
      await utf8.decodeStream(stream.body) == 'Venera 鸿蒙 HTTP',
      'Streaming failed.',
    );
    final direct = 'http://127.0.0.1:${server.port}';
    check(
      await compute(backgroundRequest, '$direct/text') == 'Venera 鸿蒙 HTTP',
      'Background isolate failed.',
    );

    final adapter = dio.Dio()
      ..httpClientAdapter = createRHttpAdapter(enableProxy: false);
    try {
      check(
        (await adapter.get<String>('$direct/text')).data == 'Venera 鸿蒙 HTTP',
        'Application Dio adapter failed.',
      );
    } finally {
      adapter.close(force: true);
    }
    final dynamicClient = await RhttpClient.create(
      settings: ClientSettings(
        proxySettings: const ProxySettings.noProxy(),
        dnsSettings: DnsSettings.dynamic(
          resolver: (host) async => ['127.0.0.1'],
        ),
      ),
    );
    clients.add(dynamicClient);
    check(
      (await dynamicClient.get('$base/text')).body == 'Venera 鸿蒙 HTTP',
      'Dynamic DNS callback failed.',
    );
    final token = CancelToken();
    final cancelled = rejects<RhttpCancelException>(
      client.get('$base/slow', cancelToken: token),
    );
    await token.cancel();
    await cancelled;
    final timeoutClient = await RhttpClient.create(
      settings: const ClientSettings(
        proxySettings: ProxySettings.noProxy(),
        timeoutSettings: TimeoutSettings(timeout: Duration(milliseconds: 250)),
      ),
    );
    clients.add(timeoutClient);
    await rejects<RhttpTimeoutException>(timeoutClient.get('$direct/slow'));

    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servers.add(proxy);
    proxy.listen((request) async {
      request.response.write(
        request.uri.host == 'proxy-target.invalid'
            ? 'proxy ok'
            : 'wrong target',
      );
      await request.response.close();
    });
    final proxyClient = await RhttpClient.create(
      settings: ClientSettings(
        proxySettings: ProxySettings.proxy('http://127.0.0.1:${proxy.port}'),
      ),
    );
    clients.add(proxyClient);
    check(
      (await proxyClient.get('http://proxy-target.invalid/text')).body ==
          'proxy ok',
      'HTTP proxy failed.',
    );

    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(probeCertificate))
      ..usePrivateKeyBytes(utf8.encode(probePrivateKey));
    final tls = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    servers.add(tls);
    tls.listen((request) async {
      request.response.write('TLS verified');
      await request.response.close();
    }, onError: (Object _) {});
    final tlsUrl = 'https://venera-probe.invalid:${tls.port}/';
    await rejects<RhttpInvalidCertificateException>(client.get(tlsUrl));
    final trusted = await RhttpClient.create(
      settings: const ClientSettings(
        proxySettings: ProxySettings.noProxy(),
        dnsSettings: DnsSettings.static(
          overrides: {
            'venera-probe.invalid': ['127.0.0.1'],
            'wrong-name.invalid': ['127.0.0.1'],
          },
        ),
        tlsSettings: TlsSettings(
          trustRootCertificates: false,
          trustedRootCertificates: [probeCertificate],
        ),
      ),
    );
    clients.add(trusted);
    check(
      (await trusted.get(tlsUrl)).body == 'TLS verified',
      'Trusted local TLS failed.',
    );
    await rejects<RhttpInvalidCertificateException>(
      trusted.get('https://wrong-name.invalid:${tls.port}/'),
    );
    result =
        'PASS: rhttp initialization; HTTP, Unicode, static/dynamic DNS, redirects, cookies, streaming, background isolate, Dio adapter, cancellation, timeout, proxy, TLS trust and hostname rejection.';
  } catch (error, stack) {
    result = 'FAIL: $error\n$stack';
  } finally {
    for (final client in clients) {
      client.dispose(cancelRunningRequests: true);
    }
    for (final response in delayed) {
      unawaited(response.close().catchError((Object _) => response));
    }
    for (final server in servers) {
      await server.close(force: true);
    }
  }
  debugPrint(result);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(result),
          ),
        ),
      ),
    ),
  );
}

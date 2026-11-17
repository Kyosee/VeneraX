import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  late HttpServer server;
  late webdav.Client client;
  late List<(String, String?)> requests;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = webdav.newClient('http://127.0.0.1:${server.port}/');
    requests = [];
    server.listen((request) async {
      requests.add((request.method, request.headers.value('depth')));
      await request.drain<void>();
      if (request.method == 'PROPFIND') {
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('''<d:multistatus xmlns:d="DAV:">
<d:response><d:href>/books/</d:href><d:propstat><d:prop>
<d:resourcetype><d:collection/></d:resourcetype>
</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>''');
      } else {
        request.response.statusCode = 204;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    client.c.close(force: true);
    await server.close(force: true);
  });

  test('metadata reads do not list directory children', () async {
    final props = await client.readProps('/books/');
    expect(props.isDir, isTrue);
    expect(requests, [('PROPFIND', '0')]);
  });

  test('directory reads still request immediate children', () async {
    await client.readDir('/books/');
    expect(requests, [('PROPFIND', '1')]);
  });

  for (final copy in [false, true]) {
    test(
      '${copy ? 'copy' : 'rename'} respects cancellation before sending',
      () async {
        final token = CancelToken()..cancel('cancelled by user');
        await expectLater(
          copy
              ? client.copy('/source', '/target', false, token)
              : client.rename('/source', '/target', false, token),
          throwsA(
            isA<DioException>().having(
              (error) => error.type,
              'type',
              DioExceptionType.cancel,
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );
  }
}

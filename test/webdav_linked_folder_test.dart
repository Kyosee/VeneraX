import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  group('WebDAV linked comic folders', () {
    test('keeps the existing single-request behavior when disabled', () async {
      final adapter = _WebdavAdapter();
      final result = await _client(
        adapter,
        detectLinkedFolders: false,
      ).listEntries();

      expect(result.error, isFalse);
      expect(result.data.map((entry) => entry.name), [
        'archive.cbz',
        'Regular',
      ]);
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.headers['depth'], '1');
    });

    test('detects a linked folder with a Depth 0 property probe', () async {
      final adapter = _WebdavAdapter();
      final result = await _client(
        adapter,
        detectLinkedFolders: true,
      ).listEntries();

      expect(result.error, isFalse);
      expect(result.data.map((entry) => entry.name), [
        'archive.cbz',
        'Linked',
        'Regular',
      ]);
      expect(
        adapter.requests
            .where((request) => request.headers['depth'] == '0')
            .map((request) => request.uri.path),
        ['/comics/Linked/', '/comics/readme.txt/'],
      );
      expect(
        adapter.requests.any(
          (request) => request.uri.path == '/comics/archive.cbz/',
        ),
        isFalse,
      );
    });

    test('isolates a failed linked-folder probe from the listing', () async {
      final adapter = _WebdavAdapter(failLinkedProbe: true);
      final result = await _client(
        adapter,
        detectLinkedFolders: true,
      ).listEntries();

      expect(result.error, isFalse);
      expect(result.data.map((entry) => entry.name), [
        'archive.cbz',
        'Regular',
      ]);
    });

    test('counts detected linked folders during migration checks', () async {
      final adapter = _WebdavAdapter();
      final names = await _client(
        adapter,
        detectLinkedFolders: true,
      ).remoteFolderNames('/comics/');

      expect(names, {'Linked', 'Regular'});
    });
  });
}

WebdavLibraryClient _client(
  _WebdavAdapter adapter, {
  required bool detectLinkedFolders,
}) {
  final config = WebdavLibraryConfig(
    id: 'test',
    sourceKey: 'webdav_library_test',
    name: 'Test',
    url: 'https://example.test',
    user: '',
    pass: '',
    root: '/comics',
    detectLinkedFolders: detectLinkedFolders,
  );
  return WebdavLibraryClient(
    config,
    clientFactory: (_) => webdav.newClient(config.url, adapter: adapter),
  );
}

class _WebdavAdapter implements HttpClientAdapter {
  _WebdavAdapter({this.failLinkedProbe = false});

  final bool failLinkedProbe;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final path = options.uri.path;
    final depth = options.headers['depth'];
    if (path == '/comics/' && depth == '1') {
      return _xmlResponse(_rootListing);
    }
    if (path == '/comics/Linked/' && depth == '0') {
      if (failLinkedProbe) return ResponseBody.fromString('', 404);
      return _xmlResponse(_linkedFolderProps);
    }
    if (path == '/comics/readme.txt/' && depth == '0') {
      return _xmlResponse(_fileProps);
    }
    return ResponseBody.fromString('', 404);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _xmlResponse(String body) => ResponseBody.fromString(
  body,
  207,
  headers: {
    Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
  },
);

const _rootListing = '''
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/comics/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/comics/Regular/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/comics/Linked</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/comics/readme.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/comics/archive.cbz</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>12</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>
''';

const _linkedFolderProps = '''
<D:multistatus xmlns:D="DAV:" xmlns:lp1="DAV:">
  <D:response>
    <D:href>/comics/Linked/</D:href>
    <D:propstat><D:prop><lp1:resourcetype><D:collection/></lp1:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>
''';

const _fileProps = '''
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/comics/readme.txt/</D:href>
    <D:propstat><D:prop><D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>
''';

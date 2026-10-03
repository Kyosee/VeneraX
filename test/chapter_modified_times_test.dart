import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/webdav_library_store.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  test(
    'local timestamps use the reader directory mapping and ignore missing chapters',
    () async {
      final root = Directory.systemTemp.createTempSync('venera-chapter-times-');
      addTearDown(() => root.deleteSync(recursive: true));
      final chapter = Directory('${root.path}/part_2')..createSync();
      File('${root.path}/not-a-directory').writeAsStringSync('page');
      final comic = LocalComic(
        id: 'comic',
        title: 'Comic',
        subtitle: '',
        tags: const [],
        directory: root.path,
        chapters: const ComicChapters({'part/2': 'Two'}),
        cover: '',
        comicType: ComicType.local,
        downloadedChapters: const ['part/2'],
        createdAt: DateTime(2024),
      );
      final times = await comic.chapterModifiedTimes([
        'part/2',
        'missing',
        'not-a-directory',
        'part/2',
      ]);
      expect(times.keys, ['part/2']);
      expect(times['part/2'], chapter.statSync().modified);
    },
  );

  test(
    'WebDAV batches hundreds of chapter timestamps by parent and handles missing metadata',
    () async {
      final adapter = _TimestampAdapter();
      final config = WebdavLibraryConfig(
        id: 'test',
        sourceKey: 'webdav_library_test',
        name: 'Test',
        url: 'https://example.test',
        user: '',
        pass: '',
        root: '/comics',
      );
      final client = WebdavLibraryClient(
        config,
        clientFactory: (_) => webdav.newClient(config.url, adapter: adapter),
      );
      final ids = [
        for (var i = 1; i <= 300; i++) '/comics/book/Group A/$i/',
        '/comics/book/Group B/1',
        '/comics/book/Group A/missing/',
      ];
      final times = await client.chapterModifiedTimes(ids);
      expect(adapter.parents, [
        '/comics/book/Group A/',
        '/comics/book/Group B/',
      ]);
      expect(times, hasLength(2));
      expect(
        times['/comics/book/Group A/1/']?.toUtc(),
        DateTime.utc(2024, 1, 1),
      );
      expect(
        times['/comics/book/Group B/1']?.toUtc(),
        DateTime.utc(2024, 1, 1),
      );
      expect(times.containsKey('/comics/book/Group A/2/'), isFalse);
      expect(times.containsKey('/comics/book/Group A/missing/'), isFalse);
      adapter.fail = true;
      await expectLater(
        client.chapterModifiedTimes(ids),
        throwsA(isA<DioException>()),
      );
    },
  );
}

class _TimestampAdapter implements HttpClientAdapter {
  final parents = <String>[];
  bool fail = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (fail) throw DioException(requestOptions: options);
    expect(options.method, 'PROPFIND');
    expect(options.headers['depth'], '1');
    final parent = Uri.decodeComponent(options.uri.path);
    parents.add(parent);
    String entry(String name, {bool directory = true, bool dated = true}) =>
        '''
      <d:response><d:href>${Uri(path: '$parent$name').toString()}</d:href>
      <d:propstat><d:prop><d:resourcetype>${directory ? '<d:collection/>' : ''}</d:resourcetype>
      ${dated ? '<d:getlastmodified>Mon, 01 Jan 2024 00:00:00 GMT</d:getlastmodified>' : ''}
      </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>''';
    final xml = '''<?xml version="1.0" encoding="utf-8"?>
      <d:multistatus xmlns:d="DAV:">${entry('')}${entry('1/')}${entry('2/', dated: false)}${entry('3/', directory: false)}</d:multistatus>''';
    return ResponseBody.fromBytes(
      utf8.encode(xml),
      207,
      headers: {
        Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

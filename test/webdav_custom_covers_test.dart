import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_cover_store.dart';
import 'package:venera/utils/webdav_covers.dart';
import 'package:webdav_client/webdav_client.dart' as dav;

void main() {
  test('skipped snapshots inherit exactly one portable cover reference', () {
    const legacy = '20500-1.android.venera';
    final token = WebdavCovers.inherit(legacy);
    expect(WebdavCovers.legacyBackup(token), legacy);
    expect(WebdavCovers.inherit('20500-2.ios.$token.venera'), token);
    expect(WebdavCovers.inherit(null), 'c1');
    expect(WebdavCovers.inherit('20500-3.win.c0.venera'), 'c0');
    expect(ComicCoverStore.nameOf('collection://../cover.png'), isNull);
    expect(ComicCoverStore.nameOf('collection://a/b.png'), isNull);
  });

  test('uploads only changed images and restores skipped and historical snapshots', () async {
    final root = await Directory.systemTemp.createTemp('webdav-cover-test-');
    App.dataPath = root.path;
    App.cachePath = root.path;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = dav.newClient('http://127.0.0.1:${server.port}/');
    final sync = WebdavCovers(client);
    final files = <String, List<int>>{};
    final puts = <String>[];
    final gets = <String>[];
    server.listen((request) async {
      final path = request.uri.path;
      final body = await request.fold(<int>[], (List<int> result, part) => result..addAll(part));
      final response = request.response;
      switch (request.method) {
        case 'MKCOL':
          response.statusCode = 201;
        case 'PROPFIND':
          String item(String href, String prop) =>
              '<d:response><d:href>$href</d:href><d:propstat><d:prop>$prop</d:prop>'
              '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
          response.statusCode = 207;
          response.headers.contentType = ContentType('application', 'xml');
          response.write('<d:multistatus xmlns:d="DAV:">');
          response.write(item('/venera-covers/', '<d:resourcetype><d:collection/></d:resourcetype>'));
          for (final entry in files.entries) {
            response.write(item(entry.key, '<d:resourcetype/><d:getcontentlength>${entry.value.length}</d:getcontentlength>'));
          }
          response.write('</d:multistatus>');
        case 'PUT':
          puts.add(path);
          files[path] = body;
          response.statusCode = 201;
        case 'COPY':
          final destination = Uri.parse(request.headers.value('destination')!).path;
          files[destination] = files[path]!;
          response.statusCode = 201;
        case 'GET':
          gets.add(path);
          if (!files.containsKey(path)) {
            response.statusCode = 404;
          } else {
            response.add(files[path]!);
          }
        default:
          response.statusCode = 204;
      }
      await response.close();
    });
    addTearDown(() async {
      client.c.close(force: true);
      await server.close(force: true);
      await root.delete(recursive: true);
    });

    const a = 'collection://A.png';
    const b = 'collection://B.jpg';
    final one = {
      'customComicCovers': {'source': {'id': a}},
      'comicCollections': {'series': a},
    };
    final two = {
      'customComicCovers': {'source': {'id': a}},
      'comicCollections': {'series': b},
    };
    final localA = ComicCoverStore.fileFor(a)!;
    final localB = ComicCoverStore.fileFor(b)!;
    await localA.parent.create(recursive: true);
    await localA.writeAsBytes([1, 2, 3]);
    final first = await sync.publish(one, null, directoryExists: false);
    final firstBackup = '20500-1.android.$first.venera';
    expect(puts.where((p) => p.endsWith('.png')), ['/venera-covers/A.png']);
    puts.clear();
    expect(await sync.publish(one, firstBackup, directoryExists: true), first);
    expect(puts, isEmpty);

    await localB.writeAsBytes([4, 5]);
    final second = await sync.publish(two, firstBackup, directoryExists: true);
    expect(puts.where((p) => !p.endsWith('.json')), ['/venera-covers/B.jpg']);
    final inherited = WebdavCovers.inherit('20500-2.android.$second.venera');
    final skippedBackup = '20500-3.ios.$inherited.venera';
    await localB.delete();
    gets.clear();
    expect(await sync.restore(skippedBackup, {}), two);
    expect(await localB.readAsBytes(), [4, 5]);
    expect(gets.where((p) => !p.endsWith('.json')), ['/venera-covers/B.jpg']);
    expect(await sync.restore(firstBackup, {}), one);
    expect(await sync.publish(WebdavCovers.emptyChoices, firstBackup, directoryExists: true), 'c0');

    await localA.delete();
    expect(await sync.restore('20500-4.win.venera', one), one);
    expect(await localA.readAsBytes(), [1, 2, 3]);
    expect(await sync.restore('20500-5.win.venera', {
      ComicCoverStore.inheritedWebdavKey: inherited,
    }), two);

    const legacy = '20500-6.win.venera';
    final zip = Archive()
      ..addFile(ArchiveFile.string('appdata.json', jsonEncode({
        'settings': {'comicCollections': [{'id': 'series', 'customCover': b}]},
      })))
      ..addFile(ArchiveFile('collection_covers/B.jpg', 2, [4, 5]));
    files['/$legacy'] = ZipEncoder().encode(zip);
    gets.clear();
    final oldToken = await sync.inheritForUpload(legacy, directoryExists: true);
    expect(gets, isEmpty);
    files.remove('/$legacy');
    await localB.delete();
    expect(await sync.restoreLatest('20500-7.win.$oldToken.venera'), {
      'comicCollections': {'series': b},
    });
    expect(await localB.readAsBytes(), [4, 5]);

    files.remove('/venera-covers/$first.json');
    puts.clear();
    expect(await sync.publish(one, firstBackup, directoryExists: true), isNot(first));
    expect(puts, hasLength(1));
    expect(puts.single, endsWith('.json'));

    await localB.delete();
    files.remove('/venera-covers/B.jpg');
    await expectLater(sync.restore(skippedBackup, {}), throwsA(anything));
    expect(await localB.exists(), isFalse);
  });
}

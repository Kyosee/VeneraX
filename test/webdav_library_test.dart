import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/webdav_library.dart';

void main() {
  group('WebdavLibrary id encoding', () {
    test('encode/decode round-trips a directory path and normalizes trailing /', () {
      final id = WebdavLibrary.encodeId('/comics/One Piece');
      // Opaque id must not leak the raw path (so it survives as a comic id
      // without needing URL-escaping through the reader/history layers).
      expect(id.contains('/'), isFalse);
      expect(WebdavLibrary.decodeId(id), '/comics/One Piece/');
    });

    test('decode tolerates an already-trailing slash', () {
      final id = WebdavLibrary.encodeId('/a/b/');
      expect(WebdavLibrary.decodeId(id), '/a/b/');
    });

    test('decode of a non-encoded value falls back to a normalized path', () {
      // Defensive: a raw path that was never encoded still yields a usable dir.
      expect(WebdavLibrary.decodeId('/raw/path'), '/raw/path/');
    });
  });

  group('WebdavLibrary.isArchive', () {
    test('recognizes common archive extensions case-insensitively', () {
      expect(WebdavLibrary.isArchive('vol1.cbz'), isTrue);
      expect(WebdavLibrary.isArchive('vol1.ZIP'), isTrue);
      expect(WebdavLibrary.isArchive('vol1.7z'), isTrue);
      expect(WebdavLibrary.isArchive('vol1.cb7'), isTrue);
    });

    test('rejects image and extension-less names', () {
      expect(WebdavLibrary.isArchive('001.jpg'), isFalse);
      expect(WebdavLibrary.isArchive('cover'), isFalse);
    });
  });

  group('WebdavLibrary.titleOf', () {
    test('extracts the last path segment and decodes percent-encoding', () {
      expect(WebdavLibrary.titleOf('/comics/One%20Piece/'), 'One Piece');
      expect(WebdavLibrary.titleOf('/comics/Naruto'), 'Naruto');
    });
  });
}

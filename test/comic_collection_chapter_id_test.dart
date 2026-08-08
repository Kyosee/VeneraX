import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_collection_chapter_id.dart';

void main() {
  group('collection chapter id', () {
    test('round-trips a plain reference', () {
      final id = encodeCollectionChapterId(
        sourceKey: 'jm',
        comicId: '12345',
        chapterId: 'ch1',
      );
      final ref = decodeCollectionChapterId(id);
      expect(ref, isNotNull);
      expect(ref!.sourceKey, 'jm');
      expect(ref.comicId, '12345');
      expect(ref.chapterId, 'ch1');
      expect(ref.memberChapterArg, 'ch1');
    });

    test('survives separators and slashes in the member chapter id', () {
      // WebDAV libraries use paths as chapter ids, and script sources hand out
      // ids containing colons; a naive delimiter would split them apart.
      const messy = '/Comics/Vol 1: Start/ch:02/';
      final id = encodeCollectionChapterId(
        sourceKey: 'webdav_library_a1b2',
        comicId: '/Comics/Vol 1: Start/',
        chapterId: messy,
      );
      final ref = decodeCollectionChapterId(id)!;
      expect(ref.chapterId, messy);
      expect(ref.comicId, '/Comics/Vol 1: Start/');
      expect(ref.sourceKey, 'webdav_library_a1b2');
    });

    test('survives non-ascii ids', () {
      final id = encodeCollectionChapterId(
        sourceKey: '本地',
        comicId: '漫画/第一部',
        chapterId: '第 1 话',
      );
      final ref = decodeCollectionChapterId(id)!;
      expect(ref.sourceKey, '本地');
      expect(ref.comicId, '漫画/第一部');
      expect(ref.chapterId, '第 1 话');
    });

    test('an empty member chapter id means "no chapter argument"', () {
      final id = encodeCollectionChapterId(
        sourceKey: 'jm',
        comicId: '1',
        chapterId: '',
      );
      final ref = decodeCollectionChapterId(id)!;
      expect(ref.chapterId, '');
      expect(ref.memberChapterArg, isNull);
    });

    test('is stable for the same reference', () {
      String make() => encodeCollectionChapterId(
        sourceKey: 'a',
        comicId: 'b',
        chapterId: 'c',
      );
      // Ids are baked into download directories and history rows, so the same
      // reference must always encode identically.
      expect(make(), make());
    });

    test('distinct members never collide', () {
      final a = encodeCollectionChapterId(
        sourceKey: 's1',
        comicId: 'c',
        chapterId: '1',
      );
      final b = encodeCollectionChapterId(
        sourceKey: 's2',
        comicId: 'c',
        chapterId: '1',
      );
      expect(a, isNot(b));
    });

    test('produces filesystem-safe ids', () {
      final id = encodeCollectionChapterId(
        sourceKey: 'webdav',
        comicId: '/a b/c',
        chapterId: '/d/e f.cbz',
      );
      // Download code names chapter directories after the id; only the segment
      // separator may appear beyond base64url's own alphabet.
      expect(RegExp(r'^[A-Za-z0-9_\-=:]+$').hasMatch(id), isTrue);
    });

    test('rejects ids that are not ours', () {
      expect(decodeCollectionChapterId(null), isNull);
      expect(decodeCollectionChapterId(''), isNull);
      expect(decodeCollectionChapterId('ch1'), isNull);
      expect(decodeCollectionChapterId('/Comics/Vol 1/'), isNull);
      // Right shape, wrong version prefix.
      expect(decodeCollectionChapterId('cx9:YQ==:Yg==:Yw=='), isNull);
      // Right prefix, wrong arity.
      expect(decodeCollectionChapterId('cx1:YQ==:Yg=='), isNull);
      expect(isCollectionChapterId('ch1'), isFalse);
    });

    test('rejects a corrupted payload instead of throwing', () {
      // A truncated or hand-edited id must read back as "unresolvable chapter",
      // not take down the whole collection.
      expect(decodeCollectionChapterId('cx1:!!!:Yg==:Yw=='), isNull);
      // An empty source key or comic id addresses nothing.
      expect(decodeCollectionChapterId('cx1::Yg==:Yw=='), isNull);
      expect(decodeCollectionChapterId('cx1:YQ==::Yw=='), isNull);
    });

    test('references compare by value', () {
      const a = CollectionChapterRef(
        sourceKey: 's',
        comicId: 'c',
        chapterId: 'e',
      );
      const b = CollectionChapterRef(
        sourceKey: 's',
        comicId: 'c',
        chapterId: 'e',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}

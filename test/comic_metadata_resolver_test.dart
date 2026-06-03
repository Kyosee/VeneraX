import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/cbz.dart';

void main() {
  group('ComicMetaData new fields', () {
    test('defaults description/artist/status to empty', () {
      final m = ComicMetaData(title: 't', author: 'a', tags: []);
      expect(m.description, '');
      expect(m.artist, '');
      expect(m.status, '');
    });

    test('round-trips new fields through json', () {
      final m = ComicMetaData(
        title: 't', author: 'a', tags: ['x'],
        description: 'desc', artist: 'art', status: '1',
      );
      final back = ComicMetaData.fromJson(m.toJson());
      expect(back.description, 'desc');
      expect(back.artist, 'art');
      expect(back.status, '1');
    });

    test('fromJson tolerates legacy json without new fields', () {
      final back = ComicMetaData.fromJson({
        'title': 't', 'author': 'a', 'tags': ['x'],
      });
      expect(back.description, '');
      expect(back.artist, '');
      expect(back.status, '');
    });
  });
}

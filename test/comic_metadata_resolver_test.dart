import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/comic_metadata_resolver.dart';

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

  group('resolveMetadata', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('vmeta'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('details.json wins and maps fields + status tag', () {
      File('${tmp.path}/details.json').writeAsStringSync(
        '{"title":"T","author":"A","artist":"R","description":"D",'
        '"genre":["g1","g2"],"status":"2"}');
      final m = resolveMetadata(tmp);
      expect(m.title, 'T');
      expect(m.author, 'A');
      expect(m.artist, 'R');
      expect(m.description, 'D');
      expect(m.tags, containsAll(['g1', 'g2']));
      expect(m.tags, contains('Status:Completed'));
    });

    test('ComicInfo.xml used when no details.json', () {
      File('${tmp.path}/ComicInfo.xml').writeAsStringSync(
        '<ComicInfo><Series>S</Series><Writer>W</Writer>'
        '<Penciller>P</Penciller><Summary>Sum</Summary>'
        '<Genre>a, b</Genre><Status>Ongoing</Status></ComicInfo>');
      final m = resolveMetadata(tmp);
      expect(m.title, 'S');
      expect(m.author, 'W');
      expect(m.artist, 'P');
      expect(m.description, 'Sum');
      expect(m.tags, containsAll(['a', 'b']));
      expect(m.tags, contains('Status:Ongoing'));
    });

    test('falls back to directory name when nothing present', () {
      final m = resolveMetadata(tmp);
      expect(m.title, tmp.path.split(Platform.pathSeparator).last);
      expect(m.description, '');
    });

    test('status 0/unknown produces no tag', () {
      File('${tmp.path}/details.json').writeAsStringSync(
        '{"title":"T","status":"0","genre":[]}');
      final m = resolveMetadata(tmp);
      expect(m.tags.where((t) => t.startsWith('Status:')), isEmpty);
    });

    test('resolveMetadataOrNull returns null when nothing present', () {
      expect(resolveMetadataOrNull(tmp), isNull);
    });
  });
}

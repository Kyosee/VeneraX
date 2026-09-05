import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/utils/ext.dart';

void main() {
  group('script file name', () {
    test('drops a query string', () {
      expect(
        ComicSourceParser.scriptFileName('example.js?token=ghp_secret'),
        'example.js',
      );
    });

    test('drops a fragment', () {
      expect(ComicSourceParser.scriptFileName('example.js#v2'), 'example.js');
    });

    test('keeps a plain name unchanged', () {
      expect(ComicSourceParser.scriptFileName('example.js'), 'example.js');
    });

    test('appends the js suffix when missing', () {
      expect(ComicSourceParser.scriptFileName('example'), 'example.js');
      expect(
        ComicSourceParser.scriptFileName('example?token=abc'),
        'example.js',
      );
    });

    test('keeps only the last path segment', () {
      expect(
        ComicSourceParser.scriptFileName('https://a.b/c/d/example.js?t=1'),
        'example.js',
      );
      expect(
        ComicSourceParser.scriptFileName(r'sources\nested\example.js'),
        'example.js',
      );
    });

    test('replaces characters that are illegal in a path', () {
      expect(
        ComicSourceParser.scriptFileName('a<b>c:d"e|f*g.js'),
        'a_b_c_d_e_f_g.js',
      );
    });

    test('falls back to a generic name when nothing usable remains', () {
      expect(ComicSourceParser.scriptFileName(''), 'source.js');
      expect(ComicSourceParser.scriptFileName('?token=abc'), 'source.js');
      expect(ComicSourceParser.scriptFileName('/'), 'source.js');
      expect(ComicSourceParser.scriptFileName('.js'), 'source.js');
    });
  });

  group('download url with a query', () {
    test('is still recognised as a url', () {
      expect('https://a.b/c/example.js?token=ghp_secret'.isURL, isTrue);
    });
  });
}

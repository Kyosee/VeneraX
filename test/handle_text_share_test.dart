import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/handle_text_share.dart';

void main() {
  group('extractSharedHttpUris', () {
    test('extracts a URL from shared title and text', () {
      final uris = extractSharedHttpUris(
        'Comic title\nhttps://reader.example.test/comic/42',
      );

      expect(uris.map((uri) => uri.toString()), [
        'https://reader.example.test/comic/42',
      ]);
    });

    test('removes surrounding sentence punctuation', () {
      final uris = extractSharedHttpUris(
        '打开（https://reader.example.test/comic/42）。',
      );

      expect(uris.single.toString(), 'https://reader.example.test/comic/42');
    });

    test('keeps URL order and removes duplicates', () {
      final uris = extractSharedHttpUris(
        'https://first.example.test/1 '
        'https://second.example.test/2 '
        'https://first.example.test/1',
      );

      expect(uris.map((uri) => uri.host), [
        'first.example.test',
        'second.example.test',
      ]);
    });

    test('ignores non-web and invalid URLs', () {
      expect(
        extractSharedHttpUris('ftp://reader.example.test/1 https:///broken'),
        isEmpty,
      );
    });
  });

  group('tryHandleSharedTextLinks', () {
    test('stops after the first source-supported URL', () async {
      final attempted = <String>[];

      final handled = await tryHandleSharedTextLinks(
        'https://first.example.test/1 https://second.example.test/2',
        (uri) async {
          attempted.add(uri.host);
          return uri.host == 'second.example.test';
        },
      );

      expect(handled, isTrue);
      expect(attempted, ['first.example.test', 'second.example.test']);
    });

    test('returns false so unsupported text can fall back to search', () async {
      final handled = await tryHandleSharedTextLinks(
        'Title only',
        (_) async => true,
      );

      expect(handled, isFalse);
    });
  });
}

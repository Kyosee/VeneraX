import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/source_url.dart';

void main() {
  group('credentials in a source url', () {
    test('are split out of the address', () {
      final parsed = SourceUrlCredentials.parse(
        'https://user:secret@a.b/c/index.json',
      );
      expect(parsed.url, 'https://a.b/c/index.json');
      expect(parsed.basicAuth, base64Encode(utf8.encode('user:secret')));
    });

    test('leave a url without them untouched', () {
      final parsed = SourceUrlCredentials.parse('https://a.b/c/index.json');
      expect(parsed.url, 'https://a.b/c/index.json');
      expect(parsed.basicAuth, isNull);
    });

    test('survive a token that contains no colon', () {
      final parsed = SourceUrlCredentials.parse('https://token@a.b/c.js');
      expect(parsed.url, 'https://a.b/c.js');
      expect(parsed.basicAuth, base64Encode(utf8.encode('token')));
    });

    test('are kept out of the address when a query is also present', () {
      final parsed = SourceUrlCredentials.parse(
        'https://user:secret@a.b/c.js?ref=main',
      );
      expect(parsed.url, 'https://a.b/c.js?ref=main');
      expect(parsed.url, isNot(contains('secret')));
    });

    test('become an Authorization header', () {
      final parsed = SourceUrlCredentials.parse('https://user:secret@a.b/c.js');
      final headers = parsed.headersWith({'cache-time': 'no'});
      expect(headers['cache-time'], 'no');
      expect(
        headers['Authorization'],
        'Basic ${base64Encode(utf8.encode('user:secret'))}',
      );
    });

    test('add no header when absent', () {
      final parsed = SourceUrlCredentials.parse('https://a.b/c.js');
      expect(parsed.headersWith({'cache-time': 'no'}), {'cache-time': 'no'});
    });
  });

  group('source url validation', () {
    test('accepts an address carrying credentials', () {
      expect(isValidSourceUrl('https://user:secret@a.b/index.json'), isTrue);
      expect(isValidSourceUrl('https://token@a.b/c.js'), isTrue);
    });

    test('accepts a host with no dot', () {
      expect(isValidSourceUrl('http://localhost:8080/index.json'), isTrue);
      expect(isValidSourceUrl('http://localhost/c.js'), isTrue);
    });

    test('accepts an IPv6 literal', () {
      expect(isValidSourceUrl('http://[::1]:8080/c.js'), isTrue);
    });

    test('accepts the plain forms that already worked', () {
      expect(isValidSourceUrl('https://a.b/c.js'), isTrue);
      expect(isValidSourceUrl('https://a.b/c.js?token=x'), isTrue);
      expect(isValidSourceUrl('https://a.b:8443/c.js'), isTrue);
      expect(isValidSourceUrl('http://127.0.0.1:8080/c.js'), isTrue);
    });

    test('tolerates surrounding whitespace', () {
      expect(isValidSourceUrl('  https://a.b/c.js  '), isTrue);
    });

    test('rejects a scheme the downloader cannot fetch', () {
      expect(isValidSourceUrl('ftp://a.b/c.js'), isFalse);
      expect(isValidSourceUrl('file:///c.js'), isFalse);
    });

    test('rejects an address with no scheme or no host', () {
      expect(isValidSourceUrl('a.b/c.js'), isFalse);
      expect(isValidSourceUrl('//a.b/c.js'), isFalse);
      expect(isValidSourceUrl('https://'), isFalse);
      expect(isValidSourceUrl(''), isFalse);
    });
  });
}

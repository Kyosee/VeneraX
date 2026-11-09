import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/proxy.dart';

void main() {
  test('system proxy supports IP addresses and hostnames', () {
    expect(parseSystemProxy('127.0.0.1:7890'), '127.0.0.1:7890');
    expect(parseSystemProxy('proxy.example:80'), 'proxy.example:80');
    expect(parseSystemProxy(' proxy.example:8080 '), 'proxy.example:8080');
    expect(parseSystemProxy('localhost:1080'), 'localhost:1080');
    expect(parseSystemProxy('[::1]:7890'), '[::1]:7890');
    expect(parseSystemProxy('[2001:db8::1]:8080'), '[2001:db8::1]:8080');
  });

  test('Windows per-protocol proxy selects the HTTPS authority', () {
    expect(
      parseSystemProxy('http=127.0.0.1:8080; https=proxy.example:8443'),
      'proxy.example:8443',
    );
    expect(parseSystemProxy('https=[::1]:7890'), '[::1]:7890');
  });

  test('invalid authorities cannot inject URL components or proxy directives', () {
    for (final value in [
      '', 'No Proxy', 'proxy.example', 'proxy.example:0',
      'proxy.example:65536', 'proxy.example:abc', ':8080',
      '::1:8080', 'http://proxy.example:8080', 'user:pass@proxy.example:8080',
      'proxy.example:8080/path', 'proxy.example:8080?query',
      'proxy.example:8080#fragment', 'proxy.example:8080;DIRECT',
      'proxy.example:8080\nDIRECT', 'proxy example:8080',
      'proxy.example:8080\\path', 'http=proxy.example:8080',
    ]) {
      expect(parseSystemProxy(value), isNull, reason: value);
    }
  });
}

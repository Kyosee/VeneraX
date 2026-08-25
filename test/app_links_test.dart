import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/app_links.dart';
import 'package:xml/xml.dart';

void main() {
  setUpAll(() => Log.isMuted = true);
  tearDownAll(() => Log.isMuted = false);

  group('resolveAppLink', () {
    test('uses domains and parser supplied by an installed source', () {
      final target = resolveAppLink(
        Uri.parse('https://reader.example.test/comic/42'),
        [
          (
            sourceKey: 'example_source',
            linkHandler: LinkHandler([
              'reader.example.test',
            ], (url) => Uri.parse(url).pathSegments.last),
          ),
        ],
      );

      expect(target?.sourceKey, 'example_source');
      expect(target?.comicId, '42');
    });

    test('does not call a source parser for an undeclared domain', () {
      var called = false;

      final target = resolveAppLink(
        Uri.parse('https://other.example.test/comic/42'),
        [
          (
            sourceKey: 'example_source',
            linkHandler: LinkHandler(['reader.example.test'], (url) {
              called = true;
              return '42';
            }),
          ),
        ],
      );

      expect(target, isNull);
      expect(called, isFalse);
    });

    test(
      'tries another installed source when the first cannot parse the URL',
      () {
        final target = resolveAppLink(
          Uri.parse('https://reader.example.test/title/second'),
          [
            (
              sourceKey: 'first_source',
              linkHandler: LinkHandler(['reader.example.test'], (_) => null),
            ),
            (
              sourceKey: 'second_source',
              linkHandler: LinkHandler([
                'READER.EXAMPLE.TEST',
              ], (_) => 'second'),
            ),
          ],
        );

        expect(target?.sourceKey, 'second_source');
        expect(target?.comicId, 'second');
      },
    );

    test('continues after a source parser throws', () {
      final target = resolveAppLink(
        Uri.parse('https://reader.example.test/title/working'),
        [
          (
            sourceKey: 'broken_source',
            linkHandler: LinkHandler([
              'reader.example.test',
            ], (_) => throw StateError('broken parser')),
          ),
          (
            sourceKey: 'working_source',
            linkHandler: LinkHandler(['reader.example.test'], (_) => 'working'),
          ),
        ],
      );

      expect(target?.sourceKey, 'working_source');
      expect(target?.comicId, 'working');
    });
  });

  test('Android web intent filter contains no hardcoded hosts', () {
    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    String? androidAttribute(XmlElement element, String name) {
      for (final attribute in element.attributes) {
        if (attribute.name.local == name) return attribute.value;
      }
      return null;
    }

    final webData = manifest
        .findAllElements('intent-filter')
        .where(
          (filter) => filter
              .findElements('action')
              .any(
                (action) =>
                    androidAttribute(action, 'name') ==
                    'android.intent.action.VIEW',
              ),
        )
        .expand((filter) => filter.findElements('data'))
        .where(
          (data) => const {
            'http',
            'https',
          }.contains(androidAttribute(data, 'scheme')),
        )
        .toList();

    expect(
      webData.map((data) => androidAttribute(data, 'scheme')).toSet(),
      containsAll({'http', 'https'}),
    );
    expect(
      webData.map((data) => androidAttribute(data, 'host')).whereType<String>(),
      isEmpty,
    );
  });
}

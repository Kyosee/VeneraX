import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/guide_document.dart';

void main() {
  group('parseGuideMarkdown', () {
    test('reads heading levels and strips the anchor tag', () {
      var blocks = parseGuideMarkdown('# Title\n## Section {#my-id}\n### Sub');
      expect(blocks.map((b) => b.type), [
        GuideBlockType.heading1,
        GuideBlockType.heading2,
        GuideBlockType.heading3,
      ]);
      expect(blocks[1].text, 'Section');
      expect(blocks[1].anchor, 'my-id');
      expect(blocks[0].anchor, isNull);
    });

    test('reads bullets with their nesting depth', () {
      var blocks = parseGuideMarkdown('- one\n  - two\n    - three');
      expect(blocks.every((b) => b.type == GuideBlockType.bullet), isTrue);
      expect(blocks.map((b) => b.indent), [0, 1, 2]);
      expect(blocks.map((b) => b.text), ['one', 'two', 'three']);
    });

    test('keeps the authored number of a numbered item', () {
      var blocks = parseGuideMarkdown('1. first\n2. second\n4. fourth');
      expect(blocks.every((b) => b.type == GuideBlockType.numbered), isTrue);
      expect(blocks.map((b) => b.number), [1, 2, 4]);
    });

    test('splits bold and code runs out of a line', () {
      var blocks = parseGuideMarkdown('plain **bold** and `code` tail');
      var spans = blocks.single.spans;
      expect(spans.map((s) => s.text), [
        'plain ',
        'bold',
        ' and ',
        'code',
        ' tail',
      ]);
      expect(spans.map((s) => s.style), [
        GuideSpanStyle.plain,
        GuideSpanStyle.bold,
        GuideSpanStyle.plain,
        GuideSpanStyle.code,
        GuideSpanStyle.plain,
      ]);
    });

    test('drops blank lines and tolerates CRLF', () {
      var blocks = parseGuideMarkdown('# A\r\n\r\nbody\r\n');
      expect(blocks.map((b) => b.text), ['A', 'body']);
    });

    test('keeps an unrecognized line as a paragraph', () {
      var blocks = parseGuideMarkdown('> quoted\n| a | b |');
      expect(blocks.every((b) => b.type == GuideBlockType.paragraph), isTrue);
      expect(blocks.length, 2);
    });
  });

  group('shipped guides', () {
    // Every guide the app can load, keyed by asset path.
    final paths = ['doc/guide.zh.md', 'doc/guide.en.md'];

    for (final path in paths) {
      test('$path defines every anchor the app links to', () {
        var blocks = parseGuideMarkdown(File(path).readAsStringSync());
        var anchors = blocks
            .map((b) => b.anchor)
            .whereType<String>()
            .toSet();
        for (final anchor in GuideAnchor.values) {
          expect(
            anchors,
            contains(anchor.id),
            reason: '$path is missing the {#${anchor.id}} heading',
          );
        }
      });

      test('$path parses into headings and body text', () {
        var blocks = parseGuideMarkdown(File(path).readAsStringSync());
        expect(blocks, isNotEmpty);
        expect(blocks.first.type, GuideBlockType.heading1);
        expect(
          blocks.any((b) => b.type == GuideBlockType.bullet),
          isTrue,
        );
        // A stray '**' or '`' would surface as literal text in the app.
        for (final block in blocks) {
          expect(block.text, isNot(contains('**')));
        }
      });
    }
  });
}

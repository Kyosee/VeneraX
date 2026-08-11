import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/guide_document.dart';

void main() {
  group('parseGuideMarkdown', () {
    test('reads heading levels', () {
      var blocks = parseGuideMarkdown('# Title\n## Section\n### Sub');
      expect(blocks.map((b) => b.type), [
        GuideBlockType.heading1,
        GuideBlockType.heading2,
        GuideBlockType.heading3,
      ]);
      expect(blocks.map((b) => b.text), ['Title', 'Section', 'Sub']);
    });

    test('attaches an anchor comment to the following heading', () {
      var blocks = parseGuideMarkdown('<!--anchor:my-id-->\n## Section\n## Other');
      expect(blocks.length, 2);
      expect(blocks[0].anchor, 'my-id');
      expect(blocks[0].text, 'Section');
      // The anchor is consumed, not inherited by later blocks.
      expect(blocks[1].anchor, isNull);
    });

    test('drops other HTML comments', () {
      var blocks = parseGuideMarkdown('<!-- a note -->\nbody');
      expect(blocks.map((b) => b.text), ['body']);
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

    test('reads a table as rows, dropping the header', () {
      var blocks = parseGuideMarkdown(
        '| Setting | Effect |\n| --- | --- |\n| Workers | Threads |\n| Pages | Count |',
      );
      expect(blocks.every((b) => b.type == GuideBlockType.tableRow), isTrue);
      expect(blocks.map((b) => b.text), ['Workers', 'Pages']);
      expect(blocks.map((b) => b.trailingText), ['Threads', 'Count']);
    });

    test('splits bold, code and contents links out of a line', () {
      var blocks = parseGuideMarkdown(
        'plain **bold** and `code` see [Section](#section)',
      );
      var spans = blocks.single.spans;
      expect(spans.map((s) => s.text), [
        'plain ',
        'bold',
        ' and ',
        'code',
        ' see ',
        'Section',
      ]);
      expect(spans.map((s) => s.style), [
        GuideSpanStyle.plain,
        GuideSpanStyle.bold,
        GuideSpanStyle.plain,
        GuideSpanStyle.code,
        GuideSpanStyle.plain,
        GuideSpanStyle.link,
      ]);
      expect(spans.last.isLink, isTrue);
    });

    test('drops blank lines and tolerates CRLF', () {
      var blocks = parseGuideMarkdown('# A\r\n\r\nbody\r\n');
      expect(blocks.map((b) => b.text), ['A', 'body']);
    });

    test('keeps an unrecognized line as a paragraph', () {
      var blocks = parseGuideMarkdown('> quoted\nplain line');
      expect(blocks.every((b) => b.type == GuideBlockType.paragraph), isTrue);
      expect(blocks.length, 2);
    });
  });

  group('shipped guides', () {
    // Every guide the app can load, keyed by asset path.
    final paths = ['doc/guide.zh.md', 'doc/guide.en.md'];

    for (final path in paths) {
      List<GuideBlock> load() =>
          parseGuideMarkdown(File(path).readAsStringSync());

      test('$path defines every anchor the app links to', () {
        var anchors = load().map((b) => b.anchor).whereType<String>().toSet();
        for (final anchor in GuideAnchor.values) {
          expect(
            anchors,
            contains(anchor.id),
            reason: '$path is missing the <!--anchor:${anchor.id}--> marker',
          );
        }
      });

      // Both guides must expose the same anchors, or a language would lose a
      // jump target. Extra markers are dead markup.
      test('$path declares exactly the anchors in GuideAnchor', () {
        var anchors = load().map((b) => b.anchor).whereType<String>().toSet();
        expect(anchors, GuideAnchor.values.map((a) => a.id).toSet());
      });

      List<String> headingTexts(List<GuideBlock> blocks) => blocks
          .where(
            (b) =>
                b.type == GuideBlockType.heading1 ||
                b.type == GuideBlockType.heading2 ||
                b.type == GuideBlockType.heading3,
          )
          .map((b) => b.text)
          .toList();

      // The in-app contents resolves a link by heading text, so two headings
      // sharing a title would make one of the entries jump to the wrong place.
      test('$path heading texts are unique', () {
        var texts = headingTexts(load());
        expect(texts.toSet().length, texts.length, reason: '$path: $texts');
      });

      test('$path contents entries all resolve to a heading', () {
        var blocks = load();
        var headings = headingTexts(blocks).toSet();
        var links = blocks
            .expand((b) => b.spans)
            .where((s) => s.isLink)
            .map((s) => s.text)
            .toList();
        expect(links, isNotEmpty, reason: '$path has no contents list');
        for (final link in links) {
          expect(
            headings,
            contains(link),
            reason: '$path contents entry "$link" matches no heading',
          );
        }
      });

      test('$path parses into headings and body text', () {
        var blocks = load();
        expect(blocks, isNotEmpty);
        expect(blocks.first.type, GuideBlockType.heading1);
        expect(blocks.any((b) => b.type == GuideBlockType.bullet), isTrue);
        expect(blocks.any((b) => b.type == GuideBlockType.tableRow), isTrue);
        // Leftover markup would surface as literal text in the app.
        for (final block in blocks) {
          expect(block.text, isNot(contains('**')));
          expect(block.text, isNot(contains('<!--')));
          expect(block.text, isNot(contains('](#')));
        }
      });
    }
  });
}

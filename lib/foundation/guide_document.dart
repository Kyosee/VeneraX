/// Parsing for the user guide shipped as markdown under `doc/`.
///
/// The guide is authored once and read in two places: the repository page and
/// [GuidePage]. Only the small subset of markdown the guide actually uses is
/// understood here — pulling in a full markdown package for four block types is
/// not worth the dependency. Anything unrecognized degrades to a paragraph
/// rather than being dropped, so an unexpected construct still reaches the
/// reader as plain text.
library;

/// A section of the guide that a feature screen can link into. [id] must match
/// the `{#id}` tag on that section's heading in every guide file.
enum GuideAnchor {
  translation('ai-translation'),
  collections('collections'),
  gestures('gestures');

  const GuideAnchor(this.id);

  final String id;
}

enum GuideBlockType { heading1, heading2, heading3, paragraph, bullet, numbered }

enum GuideSpanStyle { plain, bold, code }

class GuideSpan {
  const GuideSpan(this.text, this.style);

  final String text;
  final GuideSpanStyle style;
}

class GuideBlock {
  const GuideBlock({
    required this.type,
    required this.spans,
    this.anchor,
    this.indent = 0,
    this.number = 0,
  });

  final GuideBlockType type;
  final List<GuideSpan> spans;

  /// `{#id}` tag stripped off the heading, used as a scroll target.
  final String? anchor;

  /// Nesting depth of a list item, in list levels.
  final int indent;

  /// Display number of a [GuideBlockType.numbered] item.
  final int number;

  /// The block's text with styling dropped, for tests and search.
  String get text => spans.map((s) => s.text).join();
}

final _anchorPattern = RegExp(r'\s*\{#([a-z0-9-]+)\}\s*$');
final _numberedPattern = RegExp(r'^(\d+)\.\s+');
final _inlinePattern = RegExp(r'\*\*(.+?)\*\*|`(.+?)`');

/// Parses the guide's markdown subset: ATX headings with an optional
/// `{#anchor}`, `-` bullets (nested by two-space indent), `1.` numbered items
/// and paragraphs, with `**bold**` and `` `code` `` inline.
List<GuideBlock> parseGuideMarkdown(String markdown) {
  var blocks = <GuideBlock>[];
  for (var raw in markdown.replaceAll('\r\n', '\n').split('\n')) {
    var indent = 0;
    var line = raw;
    // Two spaces per nesting level; a tab counts as one level.
    while (line.startsWith('  ') || line.startsWith('\t')) {
      indent++;
      line = line.startsWith('\t') ? line.substring(1) : line.substring(2);
    }
    line = line.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('#')) {
      var level = 0;
      while (level < line.length && line[level] == '#') {
        level++;
      }
      var text = line.substring(level).trim();
      String? anchor;
      var match = _anchorPattern.firstMatch(text);
      if (match != null) {
        anchor = match.group(1);
        text = text.substring(0, match.start).trim();
      }
      blocks.add(
        GuideBlock(
          type: switch (level) {
            1 => GuideBlockType.heading1,
            2 => GuideBlockType.heading2,
            _ => GuideBlockType.heading3,
          },
          spans: parseGuideInline(text),
          anchor: anchor,
        ),
      );
      continue;
    }

    if (line.startsWith('- ')) {
      blocks.add(
        GuideBlock(
          type: GuideBlockType.bullet,
          spans: parseGuideInline(line.substring(2).trim()),
          indent: indent,
        ),
      );
      continue;
    }

    var numbered = _numberedPattern.firstMatch(line);
    if (numbered != null) {
      blocks.add(
        GuideBlock(
          type: GuideBlockType.numbered,
          spans: parseGuideInline(line.substring(numbered.end).trim()),
          indent: indent,
          number: int.parse(numbered.group(1)!),
        ),
      );
      continue;
    }

    blocks.add(
      GuideBlock(
        type: GuideBlockType.paragraph,
        spans: parseGuideInline(line),
      ),
    );
  }
  return blocks;
}

List<GuideSpan> parseGuideInline(String text) {
  var spans = <GuideSpan>[];
  var cursor = 0;
  for (var match in _inlinePattern.allMatches(text)) {
    if (match.start > cursor) {
      spans.add(
        GuideSpan(text.substring(cursor, match.start), GuideSpanStyle.plain),
      );
    }
    var bold = match.group(1);
    if (bold != null) {
      spans.add(GuideSpan(bold, GuideSpanStyle.bold));
    } else {
      spans.add(GuideSpan(match.group(2)!, GuideSpanStyle.code));
    }
    cursor = match.end;
  }
  if (cursor < text.length) {
    spans.add(GuideSpan(text.substring(cursor), GuideSpanStyle.plain));
  }
  return spans;
}

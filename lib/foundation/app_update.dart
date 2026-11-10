import 'package:venera/foundation/guide_document.dart';

/// Keeps release-note sections and their order using the existing Markdown parser.
List<GuideBlock> parseAppChangelog(String markdown) {
  final blocks = parseGuideMarkdown(markdown);
  const documentTitles = {"what's changed", '更新内容', '更新內容'};
  if (blocks.isNotEmpty &&
      isChangelogHeading(blocks.first) &&
      documentTitles.contains(blocks.first.text.toLowerCase())) {
    blocks.removeAt(0);
  }
  // The dialog provides its own release-page link, outside the authored notes.
  blocks.removeWhere(
    (block) =>
        block.type == GuideBlockType.paragraph &&
        RegExp(
          r'^(Full Changelog|完整更新日志|完整更新日誌)\s*[:：]\s*https://',
          caseSensitive: false,
        ).hasMatch(block.text),
  );
  return blocks;
}

bool isChangelogHeading(GuideBlock block) => switch (block.type) {
  GuideBlockType.heading1 ||
  GuideBlockType.heading2 ||
  GuideBlockType.heading3 => true,
  _ => false,
};

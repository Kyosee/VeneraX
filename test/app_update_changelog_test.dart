import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app_update.dart';
import 'package:venera/foundation/guide_document.dart';

void main() {
  test('keeps all category headings, authored order and inline content', () {
    final blocks = parseAppChangelog('''
## 更新内容
### 新增
- 新增 **多选** 入口。
### 修复
- 修复侧栏文字溢出。
### 优化
- 优化 `Windows` 菜单。
### 移除
- 本版本未移除功能。
### 其他说明
这段正文也要保留。
**注意事项**
''');
    expect(blocks.where(isChangelogHeading).map((block) => block.text), [
      '新增',
      '修复',
      '优化',
      '移除',
      '其他说明',
    ]);
    expect(blocks.where((b) => b.type == GuideBlockType.bullet), hasLength(4));
    expect(blocks[1].text, '新增 多选 入口。');
    expect(blocks[1].spans.any((s) => s.style == GuideSpanStyle.bold), isTrue);
    expect(blocks.last.text, '注意事项');
  });

  test('does not drop a category when it is the first heading', () {
    final blocks = parseAppChangelog('# Added\n- One\n## Fixed\n- Two');
    expect(blocks.where(isChangelogHeading).map((b) => b.text), [
      'Added',
      'Fixed',
    ]);
  });

  test('reuses nested lists, paragraphs and code parsing', () {
    final blocks = parseAppChangelog('''
### Changed
- Parent
  - Child
1. Step
```
# literal code
```
''');
    expect(blocks[2].indent, 1);
    expect(blocks[3].type, GuideBlockType.numbered);
    expect(blocks.last.type, GuideBlockType.codeBlock);
    expect(blocks.last.text, '# literal code');
  });

  for (final language in ['zh-CN', 'en']) {
    test(
      'current release keeps every category and all 17 entries ($language)',
      () {
        final markdown = File(
          'release-notes/v2.3.12.$language.md',
        ).readAsStringSync();
        final blocks = parseAppChangelog(markdown);
        expect(
          blocks.where(isChangelogHeading).map((b) => b.text),
          language == 'en'
              ? ['Added', 'Changed', 'Fixed', 'Removed']
              : ['新增', '变更', '修复', '移除'],
        );
        expect(
          blocks.where((b) => b.type == GuideBlockType.bullet),
          hasLength(17),
        );
        expect(
          blocks.any((b) => b.text.contains('https://github.com/')),
          isFalse,
        );
      },
    );
  }

  test('empty or unavailable notes stay empty', () {
    expect(parseAppChangelog(''), isEmpty);
    expect(parseAppChangelog('## 更新内容\n\n'), isEmpty);
  });
}

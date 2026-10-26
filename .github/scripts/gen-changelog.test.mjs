import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildChangelog, notesBody, parseReleases } from './gen-changelog.mjs';

test('keeps only stable tags, newest first by version', () => {
  const releases = parseReleases([
    'v2.0.9\t2026-06-01T10:00:00Z',
    'v2.0.10\t2026-06-05T10:00:00Z\r',
    'v2.1.8-beta.1\t2026-07-01T10:00:00Z',
    'not-a-tag\t2026-07-01T10:00:00Z',
    'v2.1.0\t',
    '',
  ].join('\n'));
  assert.deepEqual(releases, [
    { tag: 'v2.0.10', date: '2026-06-05' },
    { tag: 'v2.0.9', date: '2026-06-01' },
  ]);
});

test('drops the file title but keeps sections and the footer', () => {
  const body = notesBody(
    '## 更新内容\r\n\r\n### 新增\r\n- a\r\n\r\n**完整更新日志**: https://x/compare/a...b\r\n',
  );
  assert.equal(body, '### 新增\n- a\n\n**完整更新日志**: https://x/compare/a...b');
});

test('lists versions under their own headings, with the older-versions link last', () => {
  const out = buildChangelog('en', [
    { tag: 'v2.0.10', date: '2026-06-05', body: '### Fixed\n- b' },
    { tag: 'v2.0.9', date: '2026-06-01', body: '### Added\n- a' },
  ]);
  const lines = out.split('\n');
  assert.ok(lines[0].startsWith('<!--'));
  assert.equal(lines[2], '# Changelog');
  const newer = out.indexOf('## [v2.0.10](https://github.com/Kyosee/VeneraX/releases/tag/v2.0.10) - 2026-06-05');
  const older = out.indexOf('## [v2.0.9]');
  assert.ok(newer > 0 && older > newer);
  assert.ok(out.trimEnd().endsWith('[GitHub Releases](https://github.com/Kyosee/VeneraX/releases).'));
  assert.ok(out.endsWith('\n') && !out.endsWith('\n\n'));
});

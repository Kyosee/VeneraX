import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';

const workflow = readFileSync(new URL('../workflows/main.yml', import.meta.url), 'utf8')
  .replaceAll('\r\n', '\n');
const start = workflow.indexOf('          require_asset() {');
const end = workflow.indexOf('          body_file=', start);
assert.ok(start >= 0 && end > start, 'Release asset validation step must exist');
const validation = workflow.slice(start, end).replace(/^ {10}/gm, '');
const bash = process.env.VENERA_BASH || 'bash';
const packages = [
  'VeneraX-ios-9.8.7+654.ipa',
  'VeneraX-9.8.7+654.dmg',
  'VeneraX-9.8.7.apk',
  'VeneraX-9.8.7-armeabi-v7a.apk',
  'VeneraX-9.8.7-arm64-v8a.apk',
  'VeneraX-9.8.7-x86_64.apk',
  'VeneraX-9.8.7-windows.zip',
  'VeneraX-9.8.7-windows-installer.exe',
  'VeneraX-9.8.7-amd64.deb',
  'VeneraX-9.8.7-arm64.deb',
  'VeneraX-9.8.7-654-x86_64.pkg.tar.zst',
  'VeneraX-9.8.7-x86_64.AppImage',
  'VeneraX-9.8.7-aarch64.AppImage',
];

function validate(t, { missing, empty } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'venera-release-assets-'));
  t.after(() => {
    assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
    rmSync(directory, { recursive: true, force: true });
  });
  mkdirSync(join(directory, 'release-assets'));
  for (const filename of packages) {
    if (filename !== missing) {
      writeFileSync(join(directory, 'release-assets', filename), filename === empty ? '' : 'package');
    }
  }
  writeFileSync(join(directory, 'release-assets', 'VeneraX-debug-9.8.7-654-x86_64.pkg.tar.zst'), 'debug symbols');
  const result = spawnSync(bash, ['-c', `set -euo pipefail\n${validation}`], {
    cwd: directory,
    env: { ...process.env, app_version: '9.8.7+654', version: '9.8.7' },
    encoding: 'utf8',
  });
  assert.ifError(result.error);
  return result;
}

test('accepts a complete set of release packages', (t) => {
  const result = validate(t);
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

for (const filename of packages) {
  test(`rejects a release missing ${filename}`, (t) => {
    const result = validate(t, { missing: filename });
    assert.equal(result.status, 1, `Missing ${filename} was accepted: ${result.stdout}${result.stderr}`);
    assert.match(result.stdout, /Missing/);
  });
}

test('rejects an empty release package', (t) => {
  const result = validate(t, { empty: 'VeneraX-9.8.7.apk' });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /Empty release asset/);
});

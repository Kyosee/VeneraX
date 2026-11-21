import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { releaseDownloads } from './release-downloads.mjs';

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
  'VeneraX-9.8.7+654-harmonyos-unsigned.hap',
];

test('manual download links cover exactly the required full packages', () => {
  for (const version of ['9.8.7', '9.8.7-beta.1']) {
    const body = releaseDownloads('https://github.com/Kyosee/VeneraX', `v${version}`, `${version}+654`);
    const links = [...body.matchAll(/\]\((https:[^)]+)\)/g)].map(match => new URL(match[1]));
    assert.equal(links.length, packages.length);
    assert.deepEqual(
      links.map(url => decodeURIComponent(url.pathname.split('/').at(-1))).sort(),
      packages.map(name => name.replace('9.8.7', version)).sort(),
    );
    assert.ok(links.every(url => url.pathname.startsWith(`/Kyosee/VeneraX/releases/download/v${version}/`)));
    assert.match(body, /无需手动下载/);
    assert.match(body, /cannot be installed manually/);
  }
});

test('mobile previews link only to the four APKs and the ARM64 HAP', () => {
  const body = releaseDownloads('https://github.com/Kyosee/VeneraX', 'mobile-9.8.7-beta.1', '9.8.7-beta.1+654', 'mobile');
  const assets = [...body.matchAll(/\]\((https:[^)]+)\)/g)]
    .map(match => decodeURIComponent(new URL(match[1]).pathname.split('/').at(-1))).sort();
  assert.deepEqual(assets, packages.filter(name => /\.(apk|hap)$/.test(name))
    .map(name => name.replace('9.8.7', '9.8.7-beta.1')).sort());
});

test('a new mobile draft can be used before it appears in the releases list', () => {
  const script = readFileSync(new URL('./publish-mobile-preview.sh', import.meta.url), 'utf8')
    .replaceAll('\r\n', '\n');
  const setup = script.match(/^api="repos\/\$GITHUB_REPOSITORY"[\s\S]*?(?=^read_release\(\))/m);
  assert.ok(setup, 'Mobile draft setup must exist');
  const result = spawnSync(bash, ['-c', `set -euo pipefail
    root=. tag=mobile-1.0.0-beta.1 body_file=notes.md title='VeneraX 1.0.0 Beta 1 (Android & HarmonyOS)'
    GITHUB_REPOSITORY=test/app GITHUB_SHA=abc123
    fail() { echo "$*" >&2; exit 1; }
    gh() {
      case "$*" in
        *'/releases?per_page='*) ;; # The list has not indexed the new draft yet.
        *'/git/matching-refs/'*) echo "refs/tags/$tag" ;;
        *'/commits/refs/tags/'*) echo "$GITHUB_SHA" ;;
        *'POST repos/test/app/releases '*"name=$title"*) echo 314 ;;
        'release create '*) echo "https://example.com/draft" ;;
        *) fail "Unexpected request: $*" ;;
      esac
    }
    ${setup[0]}
    [[ "$id" == 314 ]]
  `], { encoding: 'utf8' });
  assert.ifError(result.error);
  assert.equal(result.status, 0, result.stdout + result.stderr);
});

test('prerelease titles describe only platforms with an installable package', () => {
  const script = fileURLToPath(new URL('./prerelease-title.mjs', import.meta.url));
  for (const [version, files, expected] of [
    ['3.0.2-beta.2', ['a.hap', 'one.apk', 'two.apk'], 'VeneraX 3.0.2 Beta 2 (Android & HarmonyOS)'],
    ['2.3.12-test.1', ['device.hap', 'HarmonyOS-TESTING.md'], 'VeneraX 2.3.12 Test 1 (HarmonyOS)'],
    ['9.8.7-rc.10', packages, 'VeneraX 9.8.7 RC 10 (Android, HarmonyOS, iOS, Windows, macOS & Linux)'],
  ]) {
    const result = spawnSync(process.execPath, [script, version, ...files], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), expected);
  }
});

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

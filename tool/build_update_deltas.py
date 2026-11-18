"""Fetch compatible released packages, then generate optional update deltas.

Deltas are optional. Any failure here leaves a release with full packages only.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

from create_update_deltas import generate, validate_policy

TAG = re.compile(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?')
MANIFEST = 'update-manifest.json'
NOTE = '''
### Incremental updates / 增量更新
The Android and Windows apps download a smaller update automatically when one matches the installed version. For new installs or manual updates, use a full package above. `.patch` files and `update-manifest.json` are only used by the app and cannot be installed.

Android 和 Windows 应用在有匹配当前版本的增量包时会自动下载较小的更新。首次安装或手动更新请使用上方的完整安装包；`.patch` 和 `update-manifest.json` 仅供应用使用，无法直接安装。
'''


def previous_tags(pages, current, prerelease):
    result = []
    for page in pages:
        for release in page:
            tag = release.get('tag_name', '')
            if (release.get('draft') is not False
                    or release.get('prerelease') is not prerelease
                    or not TAG.fullmatch(tag)
                    or ('-' in tag) != prerelease or tag == current or tag in result):
                continue
            result.append(tag)
            if len(result) == 2:
                return result
    return result


def read_policy(notes, tag):
    path = notes / f'{tag}.update.json'
    if not path.is_file():
        return {}
    return validate_policy(json.loads(path.read_text(encoding='utf-8')))


def check_policies(notes):
    """Reject a mistyped policy before tagging rather than at release time."""
    for path in sorted(notes.glob('*.update.json')):
        if not TAG.fullmatch(path.name[:-len('.update.json')]):
            raise ValueError(f'{path.name}: policy file must be named <tag>.update.json')
        try:
            validate_policy(json.loads(path.read_text(encoding='utf-8')))
        except ValueError as error:
            raise ValueError(f'{path.name}: {error}') from error


def stale_delta_assets(pages, tag):
    """Delta assets an earlier attempt uploaded to this draft; a rerun replaces them."""
    return [asset['id'] for page in pages for release in page
            if release.get('tag_name') == tag and release.get('draft') is True
            for asset in release.get('assets') or []
            if asset.get('name', '').endswith('.patch') or asset.get('name') == MANIFEST]


def gh(*args, timeout):
    # Release notes are UTF-8; the locale codec (GBK on Chinese Windows) cannot decode them.
    return subprocess.run(['gh', *args], check=True, capture_output=True, encoding='utf-8',
                          timeout=timeout)


def build(tag, prerelease, repo, temporary, current=Path('release-assets'),
          notes=Path('release-notes'), output=None):
    if not TAG.fullmatch(tag):
        raise ValueError('Invalid release tag')
    policy = read_policy(notes, tag)
    try:
        pages = json.loads(gh('api', '--paginate', '--slurp',
                              f'repos/{repo}/releases?per_page=100', timeout=60).stdout)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print('::warning::Release history unavailable; publishing full packages only', flush=True)
        pages = []
    for asset_id in stale_delta_assets(pages, tag):
        gh('api', '-X', 'DELETE', f'repos/{repo}/releases/assets/{asset_id}', timeout=60)
    patterns = []
    for platform, pattern in [('android', '*.apk'), ('windows', '*-windows.zip')]:
        if policy.get(platform, 'auto') == 'auto':
            patterns.extend(['--pattern', pattern])
    previous = []
    for old_tag in previous_tags(pages, tag, prerelease) if patterns else []:
        destination = temporary / old_tag
        destination.mkdir(parents=True, exist_ok=True)
        try:
            gh('release', 'download', old_tag, '--repo', repo, *patterns,
               '--dir', str(destination), '--clobber', timeout=300)
            previous.append((old_tag[1:], destination))
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            print(f'::warning::Previous packages unavailable for {old_tag}; '
                  'full updates remain available', flush=True)
    return generate(current, previous, output or current, tag[1:], policy=policy)


def publish(manifest, output, assets, body=None):
    """Copy deltas beside the full packages; the manifest goes last and only if used."""
    if not manifest['deltas']:
        return
    copied = []
    try:
        for name in [entry['patchAsset'] for entry in manifest['deltas']] + [MANIFEST]:
            shutil.copyfile(output / name, assets / name)
            copied.append(assets / name)
    except OSError:
        for path in copied:
            path.unlink(missing_ok=True)
        raise
    if body is not None:
        with body.open('a', encoding='utf-8') as notes:
            notes.write(NOTE)


def main():
    temporary = Path(os.environ['RUNNER_TEMP'])
    output = temporary / 'venera-delta-output'
    assets = Path('release-assets')
    try:
        manifest = build(os.environ['TAG'], os.environ['PRERELEASE'] == 'true',
                         os.environ['GITHUB_REPOSITORY'], temporary / 'venera-delta-previous',
                         assets, output=output)
        body = os.environ.get('BODY_FILE')
        publish(manifest, output, assets, Path(body) if body else None)
    except Exception as error:  # noqa: BLE001 - deltas must never block a release
        print(f'::warning::Incremental updates skipped; full packages only: {error}', flush=True)
        return
    print(f'Published {len(manifest["deltas"])} incremental update package(s)', flush=True)


if __name__ == '__main__':
    main()

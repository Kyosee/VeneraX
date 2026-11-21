"""Fetch compatible released packages, then generate optional update deltas.

Deltas are optional. Any failure here leaves a release with full packages only.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from create_update_deltas import generate, validate_policy

TAG = re.compile(r'v\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?')
MANIFEST = 'update-manifest.json'
FIRST_DELTA_CLIENT = (3, 0, 1)
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
            version = tuple(map(int, tag[1:].split('-', 1)[0].split('.')))
            # Delta support first shipped in stable v3.0.1.
            if version < FIRST_DELTA_CLIENT or (version == FIRST_DELTA_CLIENT and prerelease):
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


def release_history(repo):
    return json.loads(gh('api', '--paginate', '--slurp',
                         f'repos/{repo}/releases?per_page=100', timeout=60).stdout)


def clean_draft(repo, tag):
    for asset_id in stale_delta_assets(release_history(repo), tag):
        gh('api', '-X', 'DELETE', f'repos/{repo}/releases/assets/{asset_id}', timeout=60)


def build(tag, prerelease, repo, temporary, current=Path('release-assets'),
          notes=Path('release-notes'), output=None, platform=None):
    if not TAG.fullmatch(tag):
        raise ValueError('Invalid release tag')
    policy = read_policy(notes, tag)
    try:
        pages = release_history(repo)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        print('::warning::Release history unavailable; publishing full packages only', flush=True)
        pages = []
    patterns = []
    for target, pattern in [('android', '*.apk'), ('windows', '*-windows.zip')]:
        if platform and platform != target:
            policy[target] = 'full'
        if policy.get(target, 'auto') == 'auto':
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


def merge(parts, output, version):
    records = []
    # Commit the directory only after both fragments and all referenced patches are intact.
    with tempfile.TemporaryDirectory(dir=output.parent) as temporary:
        staged = Path(temporary) / 'combined'
        staged.mkdir()
        for platform in ('android', 'windows'):
            part = parts / f'deltas-{platform}'
            manifest = json.loads((part / MANIFEST).read_text(encoding='utf-8'))
            if manifest['schema'] != 1 or manifest['version'] != version:
                raise ValueError(f'Unexpected {platform} delta manifest version')
            for entry in manifest['deltas']:
                name = entry['patchAsset']
                expected = f'VeneraX-update-{entry["fromVersion"]}-to-{version}-{platform}-{entry["architecture"]}.patch'
                if (name != expected or Path(name).name != name or (staged / name).exists()
                        or entry['platform'] != platform or entry['toVersion'] != version):
                    raise ValueError(f'Unexpected patch in {platform} fragment: {name}')
                source = part / name
                if source.stat().st_size != entry['patchSize']:
                    raise ValueError(f'Incomplete patch: {name}')
                shutil.copyfile(source, staged / name)
                records.append(entry)
        if records:
            manifest = dict(schema=1, version=version, deltas=records)
            (staged / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
            staged.rename(output)
    print(f'Prepared {len(records)} incremental update package(s)', flush=True)
    return len(records)


def publish(output, assets, body):
    """Copy just the referenced patches; commit the manifest last."""
    manifest = json.loads((output / MANIFEST).read_text(encoding='utf-8'))
    copied = []
    try:
        for name in [entry['patchAsset'] for entry in manifest['deltas']] + [MANIFEST]:
            dest = assets / name
            copied.append(dest)
            shutil.copyfile(output / name, dest)
        with body.open('a', encoding='utf-8') as notes:
            notes.write(NOTE)
    except OSError:
        for path in copied:
            path.unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['android', 'windows', 'merge', 'clean-draft', 'publish'])
    action = parser.parse_args().action
    repo = os.environ['GITHUB_REPOSITORY']
    tag = os.environ.get('TAG', '')
    if not tag and action in ('android', 'windows', 'merge'):
        # Manual build-only runs use the version embedded in the new packages.
        version = re.search(r'^version:\s*([^\s+]+)', Path('pubspec.yaml').read_text(encoding='utf-8'), re.M)
        tag = f'v{version[1]}' if version else ''
    if not TAG.fullmatch(tag):
        raise ValueError('Invalid release tag')
    if action == 'clean-draft':
        clean_draft(repo, tag)
    elif action == 'merge':
        merge(Path('delta-parts'), Path('update-deltas'), tag[1:])
    elif action == 'publish':
        publish(Path('update-deltas'), Path('release-assets'), Path(os.environ['BODY_FILE']))
    else:
        build(tag, '-' in tag, repo, Path(os.environ['RUNNER_TEMP']) / 'venera-delta-previous',
              output=Path('delta-output'), platform=action)


if __name__ == '__main__':
    main()

"""Build optional BSDIFF40 updates from final release assets (no re-signing)."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import tempfile
import zipfile

import bsdiff4

MAX_FILE = 512 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(name):
    return (bool(name) and len(name) <= 240 and '\\' not in name
            and all(part and part not in ('.', '..') and not part.endswith(('.', ' '))
                    and not re.search(r'[\x00-\x1f<>:"|?*]', part)
                    and not re.match(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)', part, re.I)
                    for part in name.split('/')))


def zip_files(path):
    with zipfile.ZipFile(path) as source:
        result = {}
        seen = set()
        total = 0
        for item in source.infolist():
            if item.is_dir():
                continue
            if (not safe_path(item.filename) or item.filename.lower() in seen
                    or (item.external_attr >> 16) & 0o170000 == 0o120000
                    or item.file_size > MAX_FILE):
                raise ValueError('Unsafe Windows archive entry')
            seen.add(item.filename.lower())
            total += item.file_size
            if total > 2 * 1024 * 1024 * 1024:
                raise ValueError('Windows archive too large')
            if PurePosixPath(item.filename).name.lower().startswith('unins'):
                continue
            result[item.filename] = source.read(item)
        if 'venera.exe' not in result or 'data/app.so' not in result:
            raise ValueError('Not a Windows application package')
        return result


def verified_diff(old, new):
    patch = bsdiff4.diff(old, new)
    if bsdiff4.patch(old, patch) != new:
        raise ValueError('BSDIFF40 round trip failed')
    return patch


def windows_patch(old_path, new_path, output, old_version, new_version):
    old = zip_files(old_path)
    new = zip_files(new_path)
    records = []
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for index, (name, data) in enumerate(sorted(new.items())):
            record = dict(path=name, size=len(data), sha256=digest(data))
            previous = old.get(name)
            if previous == data:
                record.update(mode='copy', oldSha256=digest(previous))
            else:
                payload = data
                mode = 'full'
                if previous is not None:
                    patch = verified_diff(previous, data)
                    # Compare compressed payloads, since unchanged libraries often compress well.
                    import zlib
                    if len(patch) < len(zlib.compress(data, 9)):
                        payload, mode = patch, 'bsdiff'
                        record['oldSha256'] = digest(previous)
                record.update(mode=mode, payload=f'payload/{index}')
                archive.writestr(record['payload'], payload)
            records.append(record)
        archive.writestr('delta.json', json.dumps(dict(schema=1, fromVersion=old_version,
            toVersion=new_version, files=records), separators=(',', ':')))


def generate(current, previous, output, version, min_saving=0.2):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise ValueError('Invalid release version')
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for old_version, old_dir in previous[:2]:
        if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', old_version):
            raise ValueError('Invalid previous version')
        if old_version == version or ('-' in old_version) != ('-' in version):
            continue
        for architecture in ['universal', 'arm64-v8a', 'armeabi-v7a', 'x86_64', 'windows-x64']:
            windows = architecture == 'windows-x64'
            suffix = '-windows.zip' if windows else ('.apk' if architecture == 'universal' else f'-{architecture}.apk')
            old = old_dir / f'VeneraX-{old_version}{suffix}'
            new = current / f'VeneraX-{version}{suffix}'
            if not old.is_file() or not new.is_file():
                continue
            if max(old.stat().st_size, new.stat().st_size) > MAX_FILE:
                continue
            platform = 'windows' if windows else 'android'
            arch = 'x64' if windows else architecture
            name = f'VeneraX-{old_version}-to-{version}-{platform}-{arch}.patch'
            with tempfile.TemporaryDirectory(prefix='venera-delta-') as temporary:
                patch = Path(temporary) / name
                if windows:
                    windows_patch(old, new, patch, old_version, version)
                else:
                    patch.write_bytes(verified_diff(old.read_bytes(), new.read_bytes()))
                data = patch.read_bytes()
                if len(data) >= new.stat().st_size * (1 - min_saving):
                    print(f'Skipped {name}: savings below {min_saving:.0%}', flush=True)
                    continue
                (output / name).write_bytes(data)
                record = dict(format='bsdiff40-v1', platform=platform, architecture=arch,
                    fromVersion=old_version, toVersion=version, fullAsset=new.name,
                    fullSha256=digest(new.read_bytes()), patchAsset=name, patchSize=len(data),
                    patchSha256=digest(data))
                if not windows:
                    record['oldSha256'] = digest(old.read_bytes())
                records.append(record)
                print(f'{name}: {len(data):,} / {new.stat().st_size:,} bytes', flush=True)
    manifest = dict(schema=1, version=version, deltas=records)
    (output / 'update-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--current', type=Path, required=True)
    parser.add_argument('--previous', action='append', default=[], help='VERSION=DIRECTORY (newest first)')
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    generate(args.current, [(v, Path(d)) for v, d in (arg.split('=', 1) for arg in args.previous)],
             args.output, args.version)

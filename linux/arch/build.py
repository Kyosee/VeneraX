import json
from pathlib import Path
import re
import subprocess
from urllib.parse import urljoin, urlparse
from urllib.request import url2pathname


def build():
    pubspec = Path('pubspec.yaml')
    original = pubspec.read_bytes()
    content = original.decode('utf-8')
    match = re.search(r'^version:[ \t]*([^\s+]+)\+(\d+)[ \t]*\r?$', content, re.MULTILINE)
    if match is None:
        raise ValueError('Expected version: <version>+<build number> in pubspec.yaml')
    version, build_number = match.groups()
    # A letter suffix sorts before the stable release in pacman.
    pkgver = version.replace('-', '')

    config = Path('.dart_tool/package_config.json').resolve()
    packages = json.loads(config.read_text(encoding='utf-8'))['packages']
    package = next(p for p in packages if p['name'] == 'flutter_to_arch')
    entrypoint = urljoin(
        config.as_uri(), package['rootUri'].rstrip('/') + '/bin/flutter_to_arch.dart'
    )
    entrypoint = url2pathname(urlparse(entrypoint).path)
    try:
        pubspec.write_bytes((content[:match.start(1)] + pkgver + content[match.end(1):]).encode('utf-8'))
        # Run the locked tool directly; the temporary Arch version is not SemVer.
        subprocess.run(['dart', f'--packages={config}', entrypoint], check=True)
    finally:
        pubspec.write_bytes(original)

    # Keep release asset names consistent with the app version and release checks.
    if pkgver != version:
        output = Path('build/linux/arch')
        for name in ('venera', 'venera-debug'):
            package = output / f'{name}-{pkgver}-{build_number}-x86_64.pkg.tar.zst'
            if name == 'venera' or package.exists():
                package.rename(output / f'{name}-{version}-{build_number}-x86_64.pkg.tar.zst')


if __name__ == '__main__':
    build()

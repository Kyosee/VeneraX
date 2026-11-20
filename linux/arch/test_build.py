import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).with_name('build.py')


class ArchBuildTest(unittest.TestCase):
    def test_versions_restoration_and_release_names(self):
        for version, pkgver in (
            ('3.0.1-beta.1', '3.0.1beta.1'),
            ('3.0.1-rc.2', '3.0.1rc.2'),
            ('3.0.1', '3.0.1'),
        ):
            for fail in (False, True):
                for absolute_uri in (False, True):
                    with self.subTest(version=version, fail=fail, absolute_uri=absolute_uri), tempfile.TemporaryDirectory() as directory:
                        root = Path(directory)
                        newline = '\r\n' if absolute_uri else '\n'
                        original = f'name: venera{newline}version: {version}+259{newline}'.encode()
                        (root / 'pubspec.yaml').write_bytes(original)
                        tool = root / 'pub cache/flutter_to_arch'
                        (tool / 'bin').mkdir(parents=True)
                        config = root / '.dart_tool/package_config.json'
                        config.parent.mkdir()
                        config.write_text(json.dumps({'packages': [{
                            'name': 'flutter_to_arch',
                            'rootUri': tool.as_uri() if absolute_uri else '../pub%20cache/flutter_to_arch',
                        }]}))
                        output = root / 'build/linux/arch'
                        output.mkdir(parents=True)

                        def run(command, **kwargs):
                            self.assertEqual(command, ['dart', f'--packages={config.resolve()}', str(tool / 'bin/flutter_to_arch.dart')])
                            self.assertTrue(kwargs['check'])
                            self.assertIn(f'version: {pkgver}+259', (root / 'pubspec.yaml').read_text())
                            if fail:
                                raise subprocess.CalledProcessError(1, command)
                            for name in ('venera', 'venera-debug'):
                                (output / f'{name}-{pkgver}-259-x86_64.pkg.tar.zst').write_bytes(b'package')

                        cwd = Path.cwd()
                        try:
                            os.chdir(root)
                            with patch('subprocess.run', side_effect=run):
                                if fail:
                                    with self.assertRaises(subprocess.CalledProcessError):
                                        runpy.run_path(str(SCRIPT), run_name='__main__')
                                else:
                                    runpy.run_path(str(SCRIPT), run_name='__main__')
                                    self.assertEqual(sorted(p.name for p in output.iterdir()), sorted(
                                        f'{name}-{version}-259-x86_64.pkg.tar.zst'
                                        for name in ('venera', 'venera-debug')
                                    ))
                            self.assertEqual((root / 'pubspec.yaml').read_bytes(), original)
                        finally:
                            os.chdir(cwd)


if __name__ == '__main__':
    unittest.main()

import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import call, patch


SCRIPT = Path(__file__).with_name('build.py')


class DebianBuildTest(unittest.TestCase):
    def test_locked_tool_and_template_restoration(self):
        commands = [
            ['flutter', 'pub', 'get', '--enforce-lockfile'],
            ['flutter', 'build', 'linux', '--no-pub'],
            ['dart', 'run', 'flutter_to_debian'],
        ]
        for failure_at in [None, 0, 1, 2]:
            with self.subTest(failure_at=failure_at), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / 'debian/gui').mkdir(parents=True)
                templates = {
                    'debian/debian.yaml': '{{Version}} {{Arch}} {{Architecture}}',
                    'debian/gui/venera.desktop': 'Version={{Version}}',
                }
                for name, content in templates.items():
                    (root / name).write_text(content)
                (root / 'pubspec.yaml').write_text('version: 3.0.1+259\n')
                index = 0

                def run(command, **kwargs):
                    nonlocal index
                    self.assertEqual((root / 'debian/debian.yaml').read_text(), '3.0.1 x64 amd64')
                    self.assertTrue(kwargs['check'])
                    current = index
                    index += 1
                    if current == failure_at:
                        raise subprocess.CalledProcessError(1, command)

                original_directory = Path.cwd()
                try:
                    os.chdir(root)
                    with patch('subprocess.run', side_effect=run) as process, patch.object(sys, 'argv', ['build.py', 'x64']):
                        if failure_at is None:
                            runpy.run_path(str(SCRIPT), run_name='__main__')
                        else:
                            with self.assertRaises(subprocess.CalledProcessError):
                                runpy.run_path(str(SCRIPT), run_name='__main__')
                        expected = commands if failure_at is None else commands[:failure_at + 1]
                        self.assertEqual(process.call_args_list, [call(command, check=True) for command in expected])
                    for name, content in templates.items():
                        self.assertEqual((root / name).read_text(), content)
                finally:
                    os.chdir(original_directory)


if __name__ == '__main__':
    unittest.main()

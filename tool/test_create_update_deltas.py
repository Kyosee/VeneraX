import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('deltas', Path(__file__).with_name('create_update_deltas.py'))
deltas = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deltas)


class DeltaGenerationTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='venera-delta-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old, self.new, self.out = [self.root / n for n in ('old', 'new', 'out')]
        for directory in (self.old, self.new, self.out):
            directory.mkdir()

    def generate(self, version='1.0.1', previous='1.0.0'):
        return deltas.generate(self.new, [(previous, self.old)], self.out, version)

    def test_apk_round_trip_and_manifest(self):
        old = b'unchanged data' * 10000
        new = old[:1000] + b'new feature' + old[1000:]
        (self.old / 'VeneraX-1.0.0-arm64-v8a.apk').write_bytes(old)
        (self.new / 'VeneraX-1.0.1-arm64-v8a.apk').write_bytes(new)
        manifest = self.generate()
        entry = manifest['deltas'][0]
        patch = (self.out / entry['patchAsset']).read_bytes()
        self.assertEqual(deltas.bsdiff4.patch(old, patch), new)
        self.assertEqual(entry['oldSha256'], deltas.digest(old))
        self.assertEqual(entry['fullSha256'], deltas.digest(new))
        self.assertEqual(entry['patchSize'], len(patch))
        self.assertEqual(json.loads((self.out / 'update-manifest.json').read_text()), manifest)

    def test_first_release_and_cross_channel_have_no_patch(self):
        self.assertEqual(self.generate()['deltas'], [])
        self.assertEqual(self.generate(previous='1.0.0-beta.1')['deltas'], [])

    def test_large_patch_is_not_published(self):
        (self.old / 'VeneraX-1.0.0.apk').write_bytes(b'a')
        (self.new / 'VeneraX-1.0.1.apk').write_bytes(b'b')
        self.assertEqual(self.generate()['deltas'], [])

    def test_windows_file_manifest_reconstructs_exact_tree(self):
        old = {'venera.exe': b'old app', 'data/app.so': b'old AOT' * 1000,
               'flutter_windows.dll': b'engine' * 10000, 'removed.dll': b'obsolete'}
        new = {**old, 'venera.exe': b'new app', 'data/app.so': b'new AOT' + old['data/app.so'],
               'added.dll': b'new plugin'}
        del new['removed.dll']
        for version, files, directory in [('1.0.0', old, self.old), ('1.0.1', new, self.new)]:
            with zipfile.ZipFile(directory / f'VeneraX-{version}-windows.zip', 'w') as archive:
                for name, data in files.items():
                    archive.writestr(name, data)
        entry = self.generate()['deltas'][0]
        with zipfile.ZipFile(self.out / entry['patchAsset']) as archive:
            metadata = json.loads(archive.read('delta.json'))
            result = {}
            for item in metadata['files']:
                name = item['path']
                if item['mode'] == 'copy':
                    data = old[name]
                elif item['mode'] == 'bsdiff':
                    data = deltas.bsdiff4.patch(old[name], archive.read(item['payload']))
                else:
                    data = archive.read(item['payload'])
                self.assertEqual(deltas.digest(data), item['sha256'])
                result[name] = data
            self.assertEqual(result, new)

    def test_unsafe_zip_paths_and_links_are_rejected(self):
        for name in ['../bad', 'C:/bad', 'a\\b', 'NUL', 'a.', '/root']:
            with self.subTest(name=name):
                self.assertFalse(deltas.safe_path(name))
        path = self.root / 'bad.zip'
        with zipfile.ZipFile(path, 'w') as archive:
            item = zipfile.ZipInfo('link')
            item.external_attr = 0o120777 << 16
            archive.writestr(item, '../outside')
        with self.assertRaises(ValueError):
            deltas.zip_files(path)


if __name__ == '__main__':
    unittest.main()

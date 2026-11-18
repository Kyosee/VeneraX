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

    def test_only_two_previous_versions_receive_direct_patches(self):
        (self.new / 'VeneraX-1.0.3.apk').write_bytes(b'x' * 10000 + b'new')
        previous = []
        for version in ['1.0.2', '1.0.1', '1.0.0']:
            directory = self.root / version
            directory.mkdir()
            (directory / f'VeneraX-{version}.apk').write_bytes(b'x' * 10000 + version.encode())
            previous.append((version, directory))
        manifest = deltas.generate(self.new, previous, self.out, '1.0.3')
        self.assertEqual([entry['fromVersion'] for entry in manifest['deltas']], ['1.0.2', '1.0.1'])
        self.assertTrue(all(entry['toVersion'] == '1.0.3' for entry in manifest['deltas']))

    def test_release_policy_can_force_full_updates_per_platform(self):
        (self.old / 'VeneraX-1.0.0.apk').write_bytes(b'a' * 10000)
        (self.new / 'VeneraX-1.0.1.apk').write_bytes(b'a' * 9999 + b'b')
        def generate(policy):
            return deltas.generate(self.new, [('1.0.0', self.old)], self.out, '1.0.1', policy=policy)
        self.assertEqual(generate({'android': 'full'})['deltas'], [])
        self.assertEqual(len(generate({'windows': 'full'})['deltas']), 1)
        self.assertEqual(len(list(self.out.glob('*.patch'))), 1)
        self.assertEqual(generate({'android': 'full', 'windows': 'full'})['deltas'], [])
        self.assertEqual(list(self.out.glob('*.patch')), [])
        for policy in [[], {'android': 'delta'}, {'andriod': 'full'}, {'windows': 1}]:
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                generate(policy)

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
        first = (self.out / entry['patchAsset']).read_bytes()
        self.assertEqual(self.generate()['deltas'], [entry])
        self.assertEqual((self.out / entry['patchAsset']).read_bytes(), first,
                         'a rerun must reproduce identical patch bytes')
        manifest = deltas.generate(self.new, [('1.0.0', self.old)], self.out,
                                   '1.0.1', policy={'windows': 'full'})
        self.assertEqual(manifest['deltas'], [])
        self.assertEqual(list(self.out.glob('*.patch')), [])

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

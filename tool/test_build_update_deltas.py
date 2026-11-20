import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_update_deltas as builder

REPOSITORY_NOTES = Path(__file__).resolve().parent.parent / 'release-notes'


class ReleaseDeltaWorkflowTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='venera-delta-release-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.notes = self.root / 'notes'
        self.notes.mkdir()

    def build(self, policy=None):
        if policy is not None:
            (self.notes / 'v3.0.3.update.json').write_text(json.dumps(policy), encoding='utf-8')
        return builder.build('v3.0.3', False, 'example/app', self.root / 'previous',
                             self.root / 'assets', self.notes)

    def test_history_filters_drafts_channels_current_and_duplicates(self):
        def release(tag, draft=False, prerelease=False):
            return dict(tag_name=tag, draft=draft, prerelease=prerelease)
        pages = [[release('v3.0.3'), release('v3.0.4', draft=True),
                  release('v3.0.4-beta.1', prerelease=True), release('../../bad'),
                  release('v3.0.2'), release('v3.0.2')],
                 [release('v3.0.1'), release('v3.0.0')]]
        self.assertEqual(builder.previous_tags(pages, 'v3.0.3', False), ['v3.0.2', 'v3.0.1'])
        self.assertEqual(builder.previous_tags(pages, 'v3.0.5-beta.1', True), ['v3.0.4-beta.1'])

    @patch.object(builder.subprocess, 'run')
    def test_first_delta_release_never_downloads_pre_delta_clients(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps([[
            dict(tag_name=tag, draft=False, prerelease=False)
            for tag in ['v3.0.0', 'v2.3.12']]]))
        manifest = builder.build('v3.0.1', False, 'example/app', self.root / 'previous',
                                 self.root / 'assets', self.notes)
        self.assertEqual(manifest['deltas'], [])
        self.assertEqual(run.call_count, 1, 'unsupported clients must not be downloaded')

    def test_history_starts_with_first_supported_client(self):
        pages = [[dict(tag_name=tag, draft=False, prerelease=False)
                  for tag in ['v3.0.1', 'v3.0.0', 'v2.3.12']]]
        self.assertEqual(builder.previous_tags(pages, 'v3.0.2', False), ['v3.0.1'])
        beta = [[dict(tag_name=tag, draft=False, prerelease=True)
                 for tag in ['v3.0.2-beta.1', 'v3.0.1-beta.1', 'v3.0.0-beta.1']]]
        self.assertEqual(builder.previous_tags(beta, 'v3.0.3-beta.1', True), ['v3.0.2-beta.1'])

    @patch.object(builder.subprocess, 'run')
    def test_full_only_never_fetches_previous_packages(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps([[
            dict(tag_name='v3.0.2', draft=False, prerelease=False)]]))
        self.assertEqual(self.build({'android': 'full', 'windows': 'full'})['deltas'], [])
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0][:2], ['gh', 'api'])

    @patch.object(builder, 'generate')
    @patch.object(builder.subprocess, 'run')
    def test_rerun_removes_only_stale_delta_assets_from_its_draft(self, run, generate):
        def release(tag, draft, assets):
            return dict(tag_name=tag, draft=draft, prerelease=False,
                        assets=[dict(id=index, name=name) for index, name in assets])
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps([[
            release('v3.0.3', True, [(1, 'VeneraX-3.0.3.apk'), (2, 'old.patch'),
                                     (3, 'update-manifest.json')]),
            release('v3.0.2', False, [(4, 'VeneraX-update-3.0.1-to-3.0.2-android-x86_64.patch')])]]))
        self.build({'android': 'full', 'windows': 'full'})
        deletes = [call.args[0][-1] for call in run.call_args_list if '-X' in call.args[0]]
        self.assertEqual(deletes, ['repos/example/app/releases/assets/2',
                                   'repos/example/app/releases/assets/3'])

    def test_publish_copies_used_deltas_with_manifest_and_release_note(self):
        output, assets = self.root / 'output', self.root / 'release-assets'
        output.mkdir()
        assets.mkdir()
        body = self.root / 'body.md'
        body.write_text('notes\n', encoding='utf-8')
        builder.publish(dict(deltas=[]), output, assets, body)
        self.assertEqual(list(assets.iterdir()), [])
        self.assertEqual(body.read_text(encoding='utf-8'), 'notes\n')
        (output / 'a.patch').write_bytes(b'patch')
        (output / 'update-manifest.json').write_text('{}', encoding='utf-8')
        builder.publish(dict(deltas=[dict(patchAsset='a.patch')]), output, assets, body)
        self.assertEqual(sorted(path.name for path in assets.iterdir()),
                         ['a.patch', 'update-manifest.json'])
        self.assertIn('update-manifest.json', body.read_text(encoding='utf-8'))
        (assets / 'a.patch').unlink()
        (assets / 'update-manifest.json').unlink()
        with self.assertRaises(OSError):
            builder.publish(dict(deltas=[dict(patchAsset='a.patch'), dict(patchAsset='gone.patch')]),
                            output, assets, None)
        self.assertEqual(list(assets.iterdir()), [], 'a partial copy is removed')

    def test_failures_never_block_the_full_release(self):
        environment = dict(TAG='v1.0.2', PRERELEASE='false', GITHUB_REPOSITORY='example/app',
                           RUNNER_TEMP=str(self.root))
        for failure in [ValueError('Update policy must map android/windows to auto/full'),
                        MemoryError(), OSError('disk full')]:
            with self.subTest(failure=failure), patch.dict(os.environ, environment), \
                    patch.object(builder, 'build', side_effect=failure), \
                    patch.object(builder, 'publish') as publish, \
                    patch('builtins.print') as output:
                builder.main()
                publish.assert_not_called()
                self.assertIn('::warning::', output.call_args.args[0])

    def test_repository_release_policies_are_valid(self):
        builder.check_policies(REPOSITORY_NOTES)
        for name, text in [('v1.0.2.update.json', '{"android": "ful"}'),
                           ('v1.0.2.update.json', 'not json'),
                           ('1.0.2.update.json', '{"android": "full"}')]:
            with self.subTest(name=name, text=text), tempfile.TemporaryDirectory() as notes:
                (Path(notes) / name).write_text(text, encoding='utf-8')
                with self.assertRaises(ValueError):
                    builder.check_policies(Path(notes))

    @patch.object(builder.subprocess, 'run')
    def test_invalid_policy_fails_before_network(self, run):
        for policy in [{'andriod': 'full'}, {'windows': 'force'}, [], 'full']:
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                self.build(policy)
        (self.notes / 'v3.0.3.update.json').write_text('null', encoding='utf-8')
        with self.assertRaises(ValueError):
            self.build()
        run.assert_not_called()

    @patch.object(builder, 'generate')
    @patch.object(builder.subprocess, 'run')
    def test_platform_policy_only_downloads_needed_assets(self, run, generate):
        run.return_value = subprocess.CompletedProcess([], 0, json.dumps([[
            dict(tag_name='v3.0.2', draft=False, prerelease=False)]]))
        self.build({'android': 'full'})
        args = run.call_args_list[1].args[0]
        self.assertIn('*-windows.zip', args)
        self.assertNotIn('*.apk', args)
        self.assertTrue(all(call.kwargs.get('encoding') == 'utf-8'
                            for call in run.call_args_list),
                        'release notes in the API output are UTF-8 on every OS')
        self.assertEqual(generate.call_args.args[1], [('3.0.2', self.root / 'previous/v3.0.2')])

    @patch.object(builder.subprocess, 'run')
    def test_missing_history_preserves_full_update_release(self, run):
        for failure in [subprocess.CalledProcessError(1, 'gh'), subprocess.TimeoutExpired('gh', 60)]:
            run.side_effect = failure
            self.assertEqual(self.build()['deltas'], [])

    @patch.object(builder, 'generate')
    @patch.object(builder.subprocess, 'run')
    def test_partial_failed_download_is_never_used_as_a_base(self, run, generate):
        run.side_effect = [subprocess.CompletedProcess([], 0, json.dumps([[
            dict(tag_name='v3.0.2', draft=False, prerelease=False),
            dict(tag_name='v3.0.1', draft=False, prerelease=False)]])),
            subprocess.CalledProcessError(1, 'gh'), subprocess.CompletedProcess([], 0)]
        self.build()
        self.assertEqual(generate.call_args.args[1], [('3.0.1', self.root / 'previous/v3.0.1')])


if __name__ == '__main__':
    unittest.main()

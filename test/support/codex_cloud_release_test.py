import importlib.util
import io
import os
import pathlib
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('cloud', ROOT / 'priv/dev_boxes/codex_cloud.py')
cloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud)


class HarnessReleaseTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.base = pathlib.Path(self.directory.name)
        self.box = cloud.Cloud.__new__(cloud.Cloud)
        self.box.state = self.base / 'state'
        self.box.tools = self.box.state / 'tools'
        self.box.tools.mkdir(parents=True)
        self.box.config = {'harness_version': '2.0.700'}
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def archive(self, destination):
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tarfile.open(destination, 'w:gz') as archive:
            data = b'#!/bin/sh\nexit 0\n'
            entry = tarfile.TarInfo('bin/cms_harness')
            entry.size = len(data)
            entry.mode = 0o755
            archive.addfile(entry, io.BytesIO(data))

    def test_numeric_release_selects_matching_published_archive(self):
        for version in ('2.0.700', 'v2.0.700'):
            with self.subTest(version=version):
                self.box.config['harness_version'] = version
                with patch.object(self.box, 'download', side_effect=lambda url, path: self.archive(path)) as download:
                    self.box.install_harness()
                if version == '2.0.700':
                    download.assert_called_once_with(
                        'https://github.com/Code-My-Spec/plugins/releases/download/v2.0.700/cms-linux-x64.tar.gz',
                        self.box.state / 'cache/cms-2.0.700-linux-x64.tar.gz')
                self.assertTrue((self.box.tools / 'harness/bin/cms_harness').is_file())

    def test_exact_tag_build_output_is_accepted_by_installer(self):
        repository = self.base / 'release-source'
        repository.mkdir()
        subprocess.run(['git', 'init', '--quiet', str(repository)], check=True)
        subprocess.run(['git', '-c', 'user.name=ReleaseTest', '-c', 'user.email=release@example.invalid',
                        'commit', '--quiet', '--allow-empty', '-m', 'Release source'], cwd=repository, check=True)
        subprocess.run(['git', 'tag', 'v2.0.700'], cwd=repository, check=True)
        version = subprocess.check_output(['bash', str(ROOT / 'scripts/version.sh')],
                                          cwd=repository, text=True).strip()
        self.assertEqual(version, '2.0.700')
        self.box.config['harness_version'] = version
        with patch.object(self.box, 'download', side_effect=lambda url, path: self.archive(path)) as download:
            self.box.install_harness()
        self.assertIn('/v' + version + '/', download.call_args.args[0])
        self.assertTrue((self.box.tools / 'harness/bin/cms_harness').is_file())

    def test_development_version_is_rejected_before_download(self):
        self.box.config['harness_version'] = '2.0.10+4555.gf3d7c5b07'
        with patch.object(self.box, 'download') as download:
            with self.assertRaisesRegex(cloud.SetupError, 'published version'):
                self.box.install_harness()
            download.assert_not_called()

    def test_numeric_override_installs_local_candidate_without_network(self):
        archive = self.base / 'candidate.tar.gz'
        self.archive(archive)
        self.box.config['harness_version'] = '2.0.10+4555.gf3d7c5b07'
        with patch.dict(os.environ, CMS_HARNESS_VERSION='2.0.700', CMS_HARNESS_ARCHIVE=str(archive)):
            with patch.object(self.box, 'download') as download:
                self.box.install_harness()
                download.assert_not_called()
        self.assertTrue((self.box.tools / 'harness/bin/cms_harness').is_file())


if __name__ == '__main__':
    unittest.main()

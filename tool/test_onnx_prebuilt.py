import hashlib
import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "onnx_prebuilt", Path(__file__).parents[1] / ".github/actions/onnx-prebuilt/prebuilt.py"
)
PREBUILT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREBUILT)


class AppleArchiveTests(unittest.TestCase):
    def run_download(self, *, mirror_available=True, corrupt_mirror=False,
                     runtime_name="onnxruntime-libs-1.23.0.zip"):
        runtime = f"https://github.com/masicai/onnxruntime-swift-package-manager/releases/download/1.23.1/{runtime_name}"
        extensions = "https://download.onnxruntime.ai/pod-archive-onnxruntime-extensions-c-0.13.0.zip"
        payloads = {runtime: b"pinned runtime archive", extensions: b"pinned extensions archive"}
        manifest = "\n".join(
            f'Target.binaryTarget(name: "{name}", url: "{url}", '
            f'checksum: "{hashlib.sha256(payloads[url]).hexdigest()}")'
            for name, url in [("onnxruntime", runtime), ("onnxruntime_extensions", extensions)]
        )
        requests = []

        def fetch(url, destination):
            requests.append(url)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if url.endswith("flutter_onnxruntime/Package.swift"):
                destination.write_text(
                    '.package(url: "https://github.com/masicai/onnxruntime-swift-package-manager", exact: "1.23.1")',
                    encoding="utf-8",
                )
                return
            if url.endswith("Package.swift"):
                destination.write_text(manifest, encoding="utf-8")
                return
            is_mirror = url.startswith("https://github.com/Kyosee/flutter_onnxruntime/releases/")
            if is_mirror and not mirror_available:
                raise subprocess.CalledProcessError(22, "curl")
            # Reproduce unavailable upstream archives while the owned mirror is healthy.
            if not is_mirror and mirror_available and runtime_name == "onnxruntime-libs-1.23.0.zip":
                raise subprocess.CalledProcessError(22, "curl")
            original = next(key for key in payloads if key.rsplit("/", 1)[-1] == url.rsplit("/", 1)[-1])
            destination.write_bytes(b"wrong archive" if is_mirror and corrupt_mirror else payloads[original])

        with tempfile.TemporaryDirectory() as root, patch.object(
            PREBUILT, "plugin_pin", return_value=("https://github.com/Kyosee/flutter_onnxruntime", "a" * 40)
        ), patch.object(PREBUILT, "download", side_effect=fetch):
            output, temp = Path(root) / "cache", Path(root) / "temp"
            PREBUILT.download_apple(output, temp)
            for url, expected in payloads.items():
                self.assertEqual((output / re.sub(r"[^A-Za-z0-9_]", "_", url)).read_bytes(), expected)
        return requests

    def test_owned_archives_work_when_upstream_downloads_are_unavailable(self):
        self.run_download()

    def test_mirror_content_must_match_the_existing_swiftpm_checksum(self):
        with self.assertRaisesRegex(ValueError, "failed its SwiftPM checksum"):
            self.run_download(corrupt_mirror=True)

    def test_unavailable_mirror_falls_back_to_the_pinned_upstream_archive(self):
        self.run_download(mirror_available=False)

    def test_new_dependency_versions_do_not_reuse_an_old_archive(self):
        requests = self.run_download(runtime_name="onnxruntime-libs-1.24.3.zip")
        self.assertTrue(any(url.endswith("onnxruntime-libs-1.24.3.zip") for url in requests))
        self.assertFalse(any("Kyosee/flutter_onnxruntime/releases/" in url and url.endswith("onnxruntime-libs-1.24.3.zip")
                             for url in requests))


if __name__ == "__main__":
    unittest.main()

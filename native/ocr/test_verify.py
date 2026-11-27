import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile


spec = importlib.util.spec_from_file_location("ocr_verify", Path(__file__).with_name("verify.py"))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class OcrPackageTests(unittest.TestCase):
    def _apk(self, root, machine=None):
        apk = Path(root) / "app.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("lib/arm64-v8a/libflutter.so", b"flutter")
            if machine is not None:
                data = bytearray(64)
                data[:6] = b"\x7fELF\x02\x01"
                data[18:20] = machine.to_bytes(2, "little")
                archive.writestr("lib/arm64-v8a/libvenera_ocr.so", data)
        return apk

    def test_apk_rejects_a_missing_ocr_library(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(KeyError):
                verify.verify_apk(self._apk(directory))

    def test_apk_rejects_the_wrong_cpu(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "ABI"):
                verify.verify_apk(self._apk(directory, machine=62))

    def test_apk_requires_a_defined_exported_symbol(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = self._apk(directory, machine=183)
            with patch.object(verify.subprocess, "check_output", return_value="GLOBAL DEFAULT UND venera_ocr_detector_rgb"):
                with self.assertRaisesRegex(RuntimeError, "entry point"):
                    verify.verify_apk(apk)
            with patch.object(verify.subprocess, "check_output", return_value="GLOBAL DEFAULT 12 venera_ocr_detector_rgb"):
                verify.verify_apk(apk)


if __name__ == "__main__":
    unittest.main()

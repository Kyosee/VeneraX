import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_android_probe
from run_apple_probe import parse_report, run_probe


class OcrProbeTests(unittest.TestCase):
    def test_apple_waits_for_complete_output_and_checks_the_backend(self):
        report = {
            "backend": "compare",
            "nativeAvailable": True,
            "cases": [{"bitwiseEqual": True}],
        }
        encoded = json.dumps(report)
        logs = "\n".join([
            "flutter: VENERAX_OCR_BENCHMARK_PART=" + encoded[:20],
            "flutter: VENERAX_OCR_BENCHMARK_PART=" + encoded[20:],
        ])
        self.assertIsNone(parse_report(logs, True))
        logs += "\nflutter: VENERAX_OCR_BENCHMARK_DONE"
        self.assertEqual(parse_report(logs, True), report)
        with self.assertRaises(RuntimeError):
            parse_report(logs, False)
        with self.assertRaises(RuntimeError):
            parse_report("VENERAX_OCR_BENCHMARK_ERROR=failed", True)

    def test_apple_requires_comparison_on_the_missing_library_path(self):
        report = {
            "backend": "compare",
            "nativeAvailable": False,
            "cases": [{"bitwiseEqual": True}],
        }

        def logs():
            return (
                "VENERAX_OCR_BENCHMARK_PART=" + json.dumps(report)
                + "\nVENERAX_OCR_BENCHMARK_DONE"
            )

        self.assertEqual(parse_report(logs(), False), report)
        report["backend"] = "dart"
        with self.assertRaises(RuntimeError):
            parse_report(logs(), False)
        report["backend"] = "compare"
        report["cases"][0]["bitwiseEqual"] = False
        with self.assertRaises(RuntimeError):
            parse_report(logs(), False)

    def test_android_clears_the_old_process_and_filters_logs_by_app_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            apk = root / "build/app/outputs/apk/release/test-x86_64.apk"
            apk.parent.mkdir(parents=True)
            apk.touch()
            logs = (
                'VENERAX_OCR_BENCHMARK_PART={"nativeAvailable":true}\n'
                'VENERAX_OCR_BENCHMARK_DONE\n'
            )
            with patch.object(run_android_probe, "Path", side_effect=lambda p: root / p), \
                    patch.object(run_android_probe.subprocess, "run") as run, \
                    patch.object(run_android_probe.subprocess, "check_output", side_effect=["123\n", logs]) as output:
                run_android_probe.main()
            run.assert_any_call(
                ["adb", "shell", "am", "force-stop", "io.github.kyosee.venera"], check=True
            )
            self.assertIn("--pid=123", output.call_args.args[0])
            self.assertTrue((root / "build/ocr/android-compare.json").is_file())

    def test_ios_reads_the_current_report_when_startup_logs_are_missing(self):
        report = {
            "backend": "compare",
            "nativeAvailable": True,
            "cases": [{"bitwiseEqual": True}],
        }
        process = Mock()
        process.poll.return_value = None

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "tmp").mkdir()
            result = root / "tmp/venera-ocr-native.json"
            result.write_text('{"error":"stale"}', encoding="utf-8")

            def run_command(command, **options):
                if command[2] == "launch":
                    self.assertEqual(options["env"]["SIMCTL_CHILD_VENERAX_OCR_REPORT"], str(result))
                    self.assertFalse(result.exists())
                    result.write_text(json.dumps(report), encoding="utf-8")

            app = root / "Runner.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "io.github.kyosee.venera",
                "CFBundleExecutable": "Runner",
            }))
            with patch("run_apple_probe.subprocess.Popen", return_value=process), \
                    patch("run_apple_probe.subprocess.check_output", return_value=str(root)) as container, \
                    patch("run_apple_probe.subprocess.run", side_effect=run_command):
                run_probe(app, "ios", "device", root, True)
            container.assert_called_once_with([
                "xcrun", "simctl", "get_app_container", "device", "io.github.kyosee.venera", "data",
            ], text=True)
            self.assertEqual(json.loads((root / "ios-native.json").read_text()), report)
            process.terminate.assert_called_once()


if __name__ == "__main__":
    unittest.main()

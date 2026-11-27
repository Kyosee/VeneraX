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

    def test_ios_reads_dart_output_from_system_logs(self):
        report = {
            "backend": "compare",
            "nativeAvailable": True,
            "cases": [{"bitwiseEqual": True}],
        }
        process = Mock()
        process.poll.return_value = None

        def start(command, *, stdout, stderr):
            self.assertEqual(command[:8], [
                "xcrun", "simctl", "spawn", "device", "log", "stream",
                "--style", "compact",
            ])
            self.assertIn('processImagePath ENDSWITH "/Runner"', command)
            stdout.write("Runner: VENERAX_OCR_BENCHMARK_PART=" + json.dumps(report) + "\n")
            stdout.write("Runner: VENERAX_OCR_BENCHMARK_DONE\n")
            stdout.flush()
            return process

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Runner.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "io.github.kyosee.venera",
                "CFBundleExecutable": "Runner",
            }))
            with patch("run_apple_probe.subprocess.Popen", side_effect=start), \
                    patch("run_apple_probe.subprocess.run") as run:
                run_probe(app, "ios", "device", root, True)
            run.assert_any_call([
                "xcrun", "simctl", "launch", "--terminate-running-process",
                "device", "io.github.kyosee.venera",
            ], check=True, timeout=180)
            self.assertEqual(json.loads((root / "ios-native.json").read_text()), report)
            process.terminate.assert_called_once()


if __name__ == "__main__":
    unittest.main()

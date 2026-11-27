"""Run the packaged AOT probe on an already booted Android test device."""

import json
from pathlib import Path
import subprocess
import time


def main():
    output = Path("build/ocr")
    output.mkdir(parents=True, exist_ok=True)
    apks = list(Path("build/app/outputs/apk/release").glob("*-x86_64.apk"))
    if len(apks) != 1:
        raise RuntimeError("Expected exactly one x86_64 probe APK.")
    subprocess.run(["adb", "install", "-r", str(apks[0])], check=True)
    subprocess.run(["adb", "shell", "am", "force-stop", "io.github.kyosee.venera"], check=True)
    subprocess.run(["adb", "logcat", "-c"], check=True)
    subprocess.run([
        "adb", "shell", "am", "start", "-W", "-n",
        "io.github.kyosee.venera/.MainActivity",
    ], check=True)
    pid = subprocess.check_output(
        ["adb", "shell", "pidof", "io.github.kyosee.venera"], text=True
    ).strip()
    if not pid.isdecimal():
        raise RuntimeError("The Android OCR probe did not start.")
    deadline = time.monotonic() + 180
    marker = "VENERAX_OCR_BENCHMARK_PART="
    while time.monotonic() < deadline:
        logs = subprocess.check_output(
            ["adb", "logcat", "-d", "-v", "brief", f"--pid={pid}"], text=True
        )
        (output / "android-probe.log").write_text(logs, encoding="utf-8")
        if "VENERAX_OCR_BENCHMARK_ERROR=" in logs or "FATAL EXCEPTION" in logs:
            raise RuntimeError("Android OCR probe failed. See android-probe.log.")
        if "VENERAX_OCR_BENCHMARK_DONE" in logs:
            parts = [line.split(marker, 1)[1] for line in logs.splitlines() if marker in line]
            report = json.loads("".join(parts))
            if not report["nativeAvailable"]:
                raise RuntimeError("The packaged Android OCR library was not loaded.")
            (output / "android-compare.json").write_text(
                json.dumps(report, indent=2), encoding="utf-8"
            )
            print(json.dumps(report))
            return
        time.sleep(2)
    raise RuntimeError("Android OCR probe timed out. See android-probe.log.")


if __name__ == "__main__":
    main()

"""Check packaged OCR loading and missing-framework fallback on Apple hosts."""

import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time


def parse_report(logs, expected_native):
    marker = "VENERAX_OCR_BENCHMARK_PART="
    if "VENERAX_OCR_BENCHMARK_ERROR=" in logs:
        raise RuntimeError("Apple OCR probe reported an error.")
    if "VENERAX_OCR_BENCHMARK_DONE" not in logs:
        return None
    parts = [line.split(marker, 1)[1] for line in logs.splitlines() if marker in line]
    report = json.loads("".join(parts))
    if report["nativeAvailable"] != expected_native:
        raise RuntimeError("Apple OCR probe loaded the wrong backend.")
    if report["backend"] != "compare" or not report["cases"]:
        raise RuntimeError("Apple OCR probe did not compare the production path.")
    if not all(case["bitwiseEqual"] for case in report["cases"]):
        raise RuntimeError("Apple OCR output differs from Dart.")
    return report


def run_probe(app, platform, device, output, expected_native):
    contents = app / "Contents" if platform == "macos" else app
    with (contents / "Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    identifier = metadata["CFBundleIdentifier"]
    if platform == "ios":
        subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
        command = [
            "xcrun", "simctl", "launch", "--console", "--terminate-running-process",
            device, identifier,
        ]
    else:
        command = [str(contents / "MacOS" / metadata["CFBundleExecutable"])]
    label = "native" if expected_native else "fallback"
    log = output / f"{platform}-{label}.log"
    with log.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 180
            while time.monotonic() < deadline:
                report = parse_report(log.read_text(encoding="utf-8", errors="replace"), expected_native)
                if report is not None:
                    (output / f"{platform}-{label}.json").write_text(
                        json.dumps(report, indent=2), encoding="utf-8"
                    )
                    print(json.dumps(report))
                    return
                if process.poll() is not None:
                    raise RuntimeError(f"Apple OCR probe exited early. See {log}.")
                time.sleep(1)
            raise RuntimeError(f"Apple OCR probe timed out. See {log}.")
        finally:
            if platform == "ios":
                subprocess.run(
                    ["xcrun", "simctl", "terminate", device, identifier],
                    stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=False,
                )
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=["ios", "macos"])
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    output = Path("build/ocr")
    output.mkdir(parents=True, exist_ok=True)
    device = None
    if args.platform == "ios":
        devices = json.loads(subprocess.check_output(
            ["xcrun", "simctl", "list", "devices", "available", "--json"], text=True
        ))["devices"]
        phone = next(d for group in devices.values() for d in group if d["name"].startswith("iPhone"))
        device = phone["udid"]
        if phone["state"] != "Booted":
            subprocess.run(["xcrun", "simctl", "boot", device], check=True)
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    app = args.app.resolve()
    run_probe(app, args.platform, device, output, True)
    fallback = output / f"{args.platform}-fallback" / app.name
    shutil.copytree(app, fallback, symlinks=True, dirs_exist_ok=True)
    contents = fallback / "Contents" if args.platform == "macos" else fallback
    shutil.rmtree(contents / "Frameworks/VeneraOcr.framework")
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(fallback)], check=True)
    run_probe(fallback.resolve(), args.platform, device, output, False)


if __name__ == "__main__":
    main()

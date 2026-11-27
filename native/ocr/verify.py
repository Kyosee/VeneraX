"""Check the OCR library in the application's native packaging layout."""

import argparse
from pathlib import Path
import subprocess
import tempfile
import zipfile


ELF_MACHINES = {"armeabi-v7a": 40, "arm64-v8a": 183, "x86_64": 62}
SYMBOL = "venera_ocr_detector_rgb"


def verify_apk(apk):
    with zipfile.ZipFile(apk) as archive:
        abis = {
            name.split("/")[1] for name in archive.namelist()
            if name.startswith("lib/") and name.endswith("/libflutter.so")
        }
        if not abis:
            raise RuntimeError("The APK contains no Flutter native libraries.")
        for abi in sorted(abis):
            data = archive.read(f"lib/{abi}/libvenera_ocr.so")
            expected_class = 1 if abi == "armeabi-v7a" else 2
            if (data[:4] != b"\x7fELF" or data[4] != expected_class or data[5] != 1
                    or int.from_bytes(data[18:20], "little") != ELF_MACHINES[abi]):
                raise RuntimeError(f"The OCR library does not match APK ABI {abi}.")
            with tempfile.TemporaryDirectory(prefix="ocr-verify-") as directory:
                library = Path(directory) / "libvenera_ocr.so"
                library.write_bytes(data)
                symbols = subprocess.check_output(
                    ["readelf", "--dyn-syms", "--wide", str(library)], text=True
                )
                if not any(SYMBOL in line and "GLOBAL" in line and "UND" not in line
                           for line in symbols.splitlines()):
                    raise RuntimeError(f"The OCR entry point is absent in APK ABI {abi}.")
    print(f"Verified Rust OCR in {apk.name}: {', '.join(sorted(abis))}")


def verify_apple(app):
    import plistlib

    macos = (app / "Contents").is_dir()
    contents = app / "Contents" if macos else app
    with (contents / "Info.plist").open("rb") as stream:
        executable = plistlib.load(stream)["CFBundleExecutable"]
    binary = (contents / "MacOS" if macos else contents) / executable
    framework = contents / "Frameworks/VeneraOcr.framework/VeneraOcr"
    architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    library_arches = subprocess.check_output(["lipo", "-archs", str(framework)], text=True).split()
    if set(architectures) != set(library_arches):
        raise RuntimeError("The OCR framework architectures do not match the app.")
    for architecture in architectures:
        symbols = subprocess.check_output(
            ["nm", "-arch", architecture, "-gU", str(framework)], text=True
        )
        if f"_{SYMBOL}" not in symbols:
            raise RuntimeError(f"The OCR entry point is absent for {architecture}.")
    dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    if "VeneraOcr.framework" in dependencies:
        raise RuntimeError("The app must load OCR on demand to retain missing-library fallback.")
    print(f"Verified Rust OCR in {app.name}: {', '.join(architectures)}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--apk", type=Path)
    mode.add_argument("--apple-app", type=Path)
    args = parser.parse_args()
    if args.apk:
        verify_apk(args.apk)
    else:
        verify_apple(args.apple_app)


if __name__ == "__main__":
    main()

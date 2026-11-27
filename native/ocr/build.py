"""Build the OCR kernel for the ABI selected by the application's build."""

import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


SOURCE = Path(__file__).resolve().parent
ANDROID_TARGETS = {
    "aarch64-linux-android": "aarch64-linux-android",
    "armv7-linux-androideabi": "armv7a-linux-androideabi",
    "x86_64-linux-android": "x86_64-linux-android",
}
APPLE_TARGETS = {
    ("iphoneos", "arm64"): "aarch64-apple-ios",
    ("iphonesimulator", "arm64"): "aarch64-apple-ios-sim",
    ("iphonesimulator", "x86_64"): "x86_64-apple-ios",
    ("macosx", "arm64"): "aarch64-apple-darwin",
    ("macosx", "x86_64"): "x86_64-apple-darwin",
}


def compile_library(target, output, *, linker=None, link_args=()):
    compiler = shutil.which("rustc")
    if compiler is None:
        raise RuntimeError("Rust is required to build the OCR library.")
    command = [
        compiler, "--crate-name", "venera_ocr", "--crate-type", "cdylib",
        "--edition=2021", "--target", target,
        "-C", "opt-level=3", "-C", "panic=abort", "-C", "debuginfo=0",
        "detector.rs", "-o", str(output),
    ]
    if linker:
        command += ["-C", f"linker={linker}"]
    for argument in link_args:
        command += ["-C", f"link-arg={argument}"]
    subprocess.run(command, cwd=SOURCE, check=True)
    if not output.is_file() or output.stat().st_size == 0:
        raise RuntimeError(f"Rust produced no OCR library for {target}.")


def android_linker(ndk, target, api):
    host = {"win32": "windows-x86_64", "darwin": "darwin-x86_64"}.get(
        sys.platform, "linux-x86_64"
    )
    toolchain = ndk / "toolchains/llvm/prebuilt" / host
    suffix = ".exe" if sys.platform == "win32" else ""
    linker = toolchain / "bin" / f"clang{suffix}"
    if not linker.is_file():
        raise RuntimeError("The configured Android NDK has no clang linker.")
    return linker, [
        f"--target={ANDROID_TARGETS[target]}{api}",
        f"--sysroot={toolchain / 'sysroot'}",
        "-Wl,-z,max-page-size=16384",
        "-Wl,-soname,libvenera_ocr.so",
    ]


def build_apple_framework(output):
    platform = os.environ["PLATFORM_NAME"]
    architectures = os.environ["ARCHS"].split()
    targets = [APPLE_TARGETS[(platform, arch)] for arch in architectures]
    if not targets:
        raise RuntimeError("Xcode supplied no architectures for the OCR framework.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ocr-", dir=output.parent) as temporary:
        staging = Path(temporary)
        libraries = []
        for arch, target in zip(architectures, targets):
            library = staging / f"VeneraOcr-{arch}"
            compile_library(target, library, link_args=[
                "-Wl,-install_name,@rpath/VeneraOcr.framework/VeneraOcr",
            ])
            libraries.append(str(library))
        framework = staging / "VeneraOcr.framework"
        framework.mkdir()
        binary_directory = framework
        resources = framework
        if platform == "macosx":
            binary_directory = framework / "Versions/A"
            resources = binary_directory / "Resources"
            resources.mkdir(parents=True)
            (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
            (framework / "VeneraOcr").symlink_to("Versions/Current/VeneraOcr")
            (framework / "Resources").symlink_to("Versions/Current/Resources", target_is_directory=True)
        subprocess.run([
            "xcrun", "lipo", "-create", *libraries,
            "-output", str(binary_directory / "VeneraOcr"),
        ], check=True)
        metadata = {
            "CFBundleExecutable": "VeneraOcr",
            "CFBundleIdentifier": "io.github.kyosee.venera.ocr",
            "CFBundleName": "VeneraOcr",
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleSupportedPlatforms": [{
                "iphoneos": "iPhoneOS", "iphonesimulator": "iPhoneSimulator",
                "macosx": "MacOSX",
            }[platform]],
        }
        if platform == "macosx":
            metadata["LSMinimumSystemVersion"] = os.environ["MACOSX_DEPLOYMENT_TARGET"]
        else:
            metadata["MinimumOSVersion"] = os.environ["IPHONEOS_DEPLOYMENT_TARGET"]
        with (resources / "Info.plist").open("wb") as stream:
            plistlib.dump(metadata, stream)
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") or "-"
        if os.environ.get("CODE_SIGNING_ALLOWED") != "NO":
            subprocess.run([
                "codesign", "--force", "--sign", identity, "--timestamp=none",
                str(framework),
            ], check=True)
        # The framework is loaded explicitly, so it adds no launch-time dependency.
        if output.exists():
            shutil.rmtree(output)
        shutil.copytree(framework, output, symlinks=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--target")
    mode.add_argument("--apple-framework", action="store_true")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--android-ndk", type=Path)
    parser.add_argument("--android-api", type=int, default=24)
    parser.add_argument("--linker")
    parser.add_argument("--link-arg", action="append", default=[])
    args = parser.parse_args()
    output = args.output.resolve()
    if args.apple_framework:
        if output.name != "VeneraOcr.framework":
            parser.error("The Apple output must be a VeneraOcr.framework directory.")
        build_apple_framework(output)
        return
    linker, link_args = args.linker, args.link_arg
    if args.android_ndk:
        linker, android_args = android_linker(
            args.android_ndk.resolve(), args.target, args.android_api
        )
        link_args = [*link_args, *android_args]
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ocr-", dir=output.parent) as temporary:
        library = Path(temporary) / output.name
        compile_library(args.target, library, linker=linker, link_args=link_args)
        os.replace(library, output)


if __name__ == "__main__":
    main()

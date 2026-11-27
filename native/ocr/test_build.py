import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("ocr_build", Path(__file__).with_name("build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class OcrBuildTests(unittest.TestCase):
    def _build_framework(self, platform):
        with tempfile.TemporaryDirectory() as directory:
            framework = Path(directory) / "VeneraOcr.framework"
            commands = []

            def compile_stub(target, output, **kwargs):
                output.write_bytes(target.encode())

            def run_stub(command, **kwargs):
                commands.append(command)
                if command[:2] == ["xcrun", "lipo"]:
                    Path(command[-1]).write_bytes(b"universal")

            environment = {
                "PLATFORM_NAME": platform, "ARCHS": "arm64 x86_64",
                "IPHONEOS_DEPLOYMENT_TARGET": "15.1",
                "MACOSX_DEPLOYMENT_TARGET": "14.0",
                "CODE_SIGNING_ALLOWED": "YES",
                "EXPANDED_CODE_SIGN_IDENTITY": "",
            }
            with patch.dict(os.environ, environment), patch.object(
                build, "compile_library", side_effect=compile_stub
            ) as compile_mock, patch.object(build.subprocess, "run", side_effect=run_stub):
                build.build_apple_framework(framework)
            self.assertEqual(compile_mock.call_count, 2)
            self.assertEqual((framework / "VeneraOcr").read_bytes(), b"universal")
            info = framework / ("Resources/Info.plist" if platform == "macosx" else "Info.plist")
            with info.open("rb") as stream:
                metadata = plistlib.load(stream)
            self.assertEqual(metadata["CFBundleExecutable"], "VeneraOcr")
            self.assertIn(["codesign", "--force", "--sign", "-", "--timestamp=none"],
                          [command[:5] for command in commands])
            if platform == "macosx":
                self.assertTrue((framework / "Versions/Current").is_symlink())
                self.assertEqual(metadata["LSMinimumSystemVersion"], "14.0")
            else:
                self.assertEqual(metadata["MinimumOSVersion"], "15.1")

    def test_ios_framework_has_simulator_architectures_and_ad_hoc_signature(self):
        self._build_framework("iphonesimulator")

    @unittest.skipIf(os.name == "nt", "macOS framework symlinks are verified on Unix hosts")
    def test_macos_framework_uses_versioned_layout(self):
        self._build_framework("macosx")

    def test_failed_apple_build_preserves_the_existing_framework(self):
        with tempfile.TemporaryDirectory() as directory:
            framework = Path(directory) / "VeneraOcr.framework"
            framework.mkdir()
            (framework / "VeneraOcr").write_bytes(b"previous")
            with patch.dict(os.environ, {"PLATFORM_NAME": "iphoneos", "ARCHS": "arm64"}), patch.object(
                build, "compile_library", side_effect=subprocess.CalledProcessError(1, "rustc")
            ):
                with self.assertRaises(subprocess.CalledProcessError):
                    build.build_apple_framework(framework)
            self.assertEqual((framework / "VeneraOcr").read_bytes(), b"previous")

    def test_android_targets_use_the_configured_ndk_api_and_16k_pages(self):
        with tempfile.TemporaryDirectory() as directory:
            ndk = Path(directory)
            clang = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin/clang"
            clang.parent.mkdir(parents=True)
            clang.touch()
            with patch.object(build.sys, "platform", "linux"):
                for rust, android in build.ANDROID_TARGETS.items():
                    linker, args = build.android_linker(ndk, rust, 24)
                    self.assertEqual(linker, clang)
                    self.assertIn(f"--target={android}24", args)
                    self.assertIn("-Wl,-z,max-page-size=16384", args)

    def test_android_rejects_a_missing_ndk(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "NDK"):
                build.android_linker(Path(directory), "aarch64-linux-android", 24)

    def test_failed_compile_does_not_replace_a_previous_library(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "libvenera_ocr.so"
            output.write_bytes(b"previous")
            with patch.object(build.sys, "argv", [
                "build.py", "--target", "aarch64-unknown-linux-ohos",
                "--output", str(output),
            ]), patch.object(build, "compile_library", side_effect=subprocess.CalledProcessError(1, "rustc")):
                with self.assertRaises(subprocess.CalledProcessError):
                    build.main()
            self.assertEqual(output.read_bytes(), b"previous")
            self.assertEqual(list(output.parent.iterdir()), [output])

    def test_success_replaces_library_only_after_compilation(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "libvenera_ocr.so"

            def compile_stub(target, temporary, **kwargs):
                self.assertEqual(target, "aarch64-unknown-linux-ohos")
                self.assertFalse(output.exists())
                self.assertEqual(kwargs["linker"], "clang")
                self.assertEqual(kwargs["link_args"], ["--target=aarch64-linux-ohos"])
                temporary.write_bytes(b"compiled")

            with patch.object(build.sys, "argv", [
                "build.py", "--target", "aarch64-unknown-linux-ohos",
                "--output", str(output), "--linker=clang",
                "--link-arg=--target=aarch64-linux-ohos",
            ]), patch.object(build, "compile_library", side_effect=compile_stub):
                build.main()
            self.assertEqual(output.read_bytes(), b"compiled")

    def test_ios_device_and_simulator_arm64_use_distinct_targets(self):
        self.assertEqual(build.APPLE_TARGETS[("iphoneos", "arm64")], "aarch64-apple-ios")
        self.assertEqual(build.APPLE_TARGETS[("iphonesimulator", "arm64")], "aarch64-apple-ios-sim")

    def test_rust_failure_propagates_instead_of_claiming_a_build(self):
        with patch.object(build.shutil, "which", return_value="rustc"), patch.object(
            build.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "rustc")
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                build.compile_library("x86_64-unknown-linux-gnu", Path("unused.so"))

    @unittest.skipUnless(os.name == "nt", "Verifies Windows multi-configuration installs")
    def test_windows_install_without_rust(self):
        cmake = shutil.which("cmake")
        if cmake is None:
            self.skipTest("CMake is required for the Windows install test")
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory)
            output = project / "build"
            (project / "CMakeLists.txt").write_text(
                'cmake_minimum_required(VERSION 3.14)\n'
                'project(ocr_install NONE)\n'
                'set(CMAKE_CONFIGURATION_TYPES Debug Profile Release)\n'
                'set(FLUTTER_TARGET_PLATFORM windows-x64)\n'
                'set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_BINARY_DIR}/bundle/$<CONFIG>")\n'
                'set(saved_path "$ENV{PATH}")\n'
                'set(ENV{PATH} "${CMAKE_BINARY_DIR}/no-rust")\n'
                f'add_subdirectory("{build.SOURCE.as_posix()}" ocr)\n'
                'set(ENV{PATH} "${saved_path}")\n',
                encoding="utf-8",
            )
            # Exercise all three install modes from a single configure.
            env = {k: v for k, v in os.environ.items() if not k.startswith("CMAKE_GENERATOR")}
            if shutil.which("ninja"):
                env["CMAKE_GENERATOR"] = "Ninja Multi-Config"
            config = subprocess.run([
                cmake, "-S", project, "-B", output,
                f"-DVENERA_OCR_PYTHON:FILEPATH={sys.executable}",
            ], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            self.assertEqual(config.returncode, 0, config.stdout)
            self.assertIn("Rust is required to build the OCR library", config.stdout)
            for mode in ("Debug", "Profile", "Release"):
                with self.subTest(mode=mode):
                    library = output / "bundle" / mode / "venera_ocr.dll"
                    library.parent.mkdir(parents=True)
                    library.write_bytes(b"previous build")
                    install = subprocess.run([
                        cmake, "--install", output, "--config", mode,
                    ], capture_output=True, text=True)
                    self.assertFalse(library.exists())
                    if mode == "Release":
                        self.assertNotEqual(install.returncode, 0)
                        self.assertIn("venera_ocr.dll", install.stderr)
                    else:
                        self.assertEqual(install.returncode, 0, install.stderr)


if __name__ == "__main__":
    unittest.main()

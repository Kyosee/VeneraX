import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import build


class AppImageTest(unittest.TestCase):
    def test_bundle_keeps_flutter_and_webkit_runtime_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            repo, bundle, appdir = root / "repo", root / "bundle", root / "AppDir"
            libdir, datadir = root / "usr/lib/test-linux-gnu", root / "usr/share"
            files = {
                repo / "debian/gui/venera.desktop": "[Desktop Entry]\nName=VeneraX\n",
                repo / "LICENSE": "license",
                bundle / "venera": "executable",
                bundle / "data/icudtl.dat": "icu",
                bundle / "data/flutter_assets/asset.txt": "asset",
                bundle / "lib/libflutter_linux_gtk.so": "flutter",
                bundle / "lib/libapp.so": "dart",
                bundle / "lib/libonnxruntime.so.1": "onnx",
                libdir / "webkit2gtk-4.1/WebKitWebProcess": "web",
                libdir / "webkit2gtk-4.1/WebKitNetworkProcess": "network",
                libdir / "webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so": "injected",
                libdir / "gio/modules/libgiognutls.so": "tls",
                datadir / "webkitgtk-4.1/resources/inspector.gresource": "inspector",
            }
            for path, content in files.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            (bundle / "lib/libonnxruntime.so").symlink_to("libonnxruntime.so.1")
            desktop = build.stage_appdir(repo, bundle, appdir, libdir, datadir)

            self.assertEqual((appdir / "usr/bin/data/flutter_assets/asset.txt").read_text(), "asset")
            self.assertEqual((appdir / "usr/bin/lib/libonnxruntime.so").read_text(), "onnx")
            self.assertTrue((appdir / "usr/lib/libonnxruntime.so").is_symlink())
            self.assertEqual((appdir / libdir.relative_to("/") / "webkit2gtk-4.1/WebKitWebProcess").read_text(), "web")
            self.assertEqual((appdir / "usr/lib/gio/modules/libgiognutls.so").read_text(), "tls")
            self.assertIn("Exec=venera\n", desktop.read_text())
            self.assertNotIn("Exec=", (repo / "debian/gui/venera.desktop").read_text())
            self.assertEqual((bundle / "lib/libonnxruntime.so").read_text(), "onnx")

            (bundle / "lib/libonnxruntime.so.1").unlink()
            with self.assertRaisesRegex(FileNotFoundError, "ONNX Runtime"):
                build.stage_appdir(repo, bundle, root / "missing-runtime", libdir, datadir)

    def test_webkit_paths_relocate_without_changing_binary_size_or_system_paths(self):
        for triplet in ("x86_64-linux-gnu", "aarch64-linux-gnu"):
            with self.subTest(triplet=triplet), tempfile.TemporaryDirectory() as tmp:
                appdir = Path(tmp)
                libdir, datadir = Path("/usr/lib") / triplet, Path("/usr/share")
                library = appdir / "usr/lib/libwebkit2gtk-4.1.so.0.0.0"
                library.parent.mkdir(parents=True)
                original = (
                    b"\x7fELF\0" + str(libdir / "webkit2gtk-4.1").encode()
                    + b"/WebKitWebProcess\0/usr/share/webkitgtk-4.1/resources\0"
                    + b"/usr/bin/bwrap\0/usr/bin/xdg-dbus-proxy\0/usr/lib\0"
                )
                library.write_bytes(original)
                build.relocate_webkit(appdir, libdir, datadir)
                updated = library.read_bytes()
                self.assertEqual(len(updated), len(original))
                self.assertIn(f"././/lib/{triplet}/webkit2gtk-4.1/WebKitWebProcess".encode(), updated)
                self.assertIn(b"././/share/webkitgtk-4.1/resources", updated)
                self.assertIn(b"/usr/bin/bwrap\0/usr/bin/xdg-dbus-proxy\0/usr/lib\0", updated)
                library.write_bytes(b"unknown WebKit layout")
                with self.assertRaisesRegex(RuntimeError, "process path not found"):
                    build.relocate_webkit(appdir, libdir, datadir)

    def test_apprun_preserves_arguments_and_launches_from_the_bundle(self):
        with tempfile.TemporaryDirectory(prefix="appimage with spaces ") as tmp:
            appdir = Path(tmp)
            (appdir / "usr/bin").mkdir(parents=True)
            apprun = appdir / "AppRun.wrapped"
            shutil.copyfile(Path(__file__).with_name("AppRun"), apprun)
            executable = appdir / "usr/bin/venera"
            executable.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$APPDIR" "$PWD" '
                '"$LD_LIBRARY_PATH" "$GIO_MODULE_DIR" "$@"\n'
            )
            executable.chmod(0o755)
            for inherited in (None, "/existing/lib"):
                env = os.environ.copy()
                env.pop("LD_LIBRARY_PATH", None)
                if inherited:
                    env["LD_LIBRARY_PATH"] = inherited
                result = subprocess.run(
                    ["bash", str(apprun), "argument with spaces", "venera://test?x=1&y=2"],
                    env=env, cwd="/", text=True, capture_output=True, check=True,
                )
                self.assertEqual(result.stdout.splitlines(), [
                    str(appdir), str(appdir / "usr"),
                    str(appdir / "usr/lib") + (f":{inherited}" if inherited else ""),
                    str(appdir / "usr/lib/gio/modules"),
                    "argument with spaces", "venera://test?x=1&y=2",
                ])


if __name__ == "__main__":
    unittest.main()

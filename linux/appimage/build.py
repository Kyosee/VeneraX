#!/usr/bin/env python3
"""Package an existing Flutter Linux release bundle with linuxdeploy."""

import argparse
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import urllib.request


ARCHITECTURES = {"x64": "x86_64", "arm64": "aarch64"}


def stage_appdir(repo, bundle, appdir, system_libdir, system_datadir):
    webkit = system_libdir / "webkit2gtk-4.1"
    gio = system_libdir / "gio/modules"
    for required in (
        bundle / "venera",
        bundle / "data/icudtl.dat",
        bundle / "lib/libapp.so",
        bundle / "lib/libflutter_linux_gtk.so",
        webkit / "WebKitWebProcess",
        webkit / "WebKitNetworkProcess",
        webkit / "injected-bundle/libwebkit2gtkinjectedbundle.so",
        gio / "libgiognutls.so",
    ):
        if not required.is_file():
            raise FileNotFoundError(f"Missing runtime file: {required}")
    if not any(path.is_file() for path in (bundle / "lib").glob("libonnxruntime.so*")):
        raise FileNotFoundError(f"Missing ONNX Runtime in {bundle / 'lib'}")

    # Flutter resolves data/ and lib/ relative to its executable.
    bindir = appdir / "usr/bin"
    shutil.copytree(bundle, bindir, symlinks=True)
    shutil.move(bindir / "lib", appdir / "usr/lib")
    (bindir / "lib").symlink_to("../lib", target_is_directory=True)
    shutil.copytree(webkit, appdir / webkit.relative_to("/"), symlinks=True)
    shutil.copytree(gio, appdir / "usr/lib/gio/modules", symlinks=True)
    webkit_data = system_datadir / "webkitgtk-4.1"
    if webkit_data.is_dir():
        shutil.copytree(webkit_data, appdir / webkit_data.relative_to("/"))

    desktop = appdir / "usr/share/applications/venera.desktop"
    desktop.parent.mkdir(parents=True)
    desktop.write_text(
        (repo / "debian/gui/venera.desktop").read_text(encoding="utf-8").rstrip()
        + "\nExec=venera\n",
        encoding="utf-8",
    )
    license_dir = appdir / "usr/share/doc/venerax"
    license_dir.mkdir(parents=True)
    shutil.copy2(repo / "LICENSE", license_dir / "copyright")
    return desktop


def relocate_webkit(appdir, system_libdir, system_datadir):
    # Release WebKit ignores WEBKIT_EXEC_PATH. Relocate only its own paths;
    # leave system paths and sandbox settings untouched.
    paths = (
        system_libdir / "webkit2gtk-4.1",
        system_datadir / "webkitgtk-4.1",
    )
    replacements = []
    for path in paths:
        relative = path.relative_to("/usr")
        replacements.append((str(path).encode(), f"././/{relative}".encode()))
    libraries = [
        path for path in (appdir / "usr/lib").glob("libwebkit2gtk-4.1.so*")
        if not path.is_symlink()
    ]
    if not libraries:
        raise FileNotFoundError("linuxdeploy did not bundle WebKitGTK 4.1")
    for library in libraries:
        content = library.read_bytes()
        if replacements[0][0] not in content:
            raise RuntimeError(f"WebKit process path not found in {library}")
        for original, relative in replacements:
            content = content.replace(original, relative)
        library.write_bytes(content)


def download_tool(url, destination):
    with urllib.request.urlopen(url, timeout=60) as response:
        with destination.open("wb") as target:
            shutil.copyfileobj(response, target)
    destination.chmod(0o755)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arch", choices=ARCHITECTURES)
    args = parser.parse_args()
    arch = ARCHITECTURES[args.arch]
    if platform.system() != "Linux" or platform.machine() != arch:
        parser.error(f"Build {args.arch} on a native {arch} Linux runner")

    repo = Path(__file__).resolve().parents[2]
    release = repo / f"build/linux/{args.arch}/release"
    bundle = release / "bundle"
    version = re.search(
        r"^version:\s*([^+\s]+)",
        (repo / "pubspec.yaml").read_text(encoding="utf-8"),
        re.M,
    )
    if version is None:
        raise ValueError("Missing version in pubspec.yaml")
    output_dir = release / "appimage"
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / f"VeneraX-{version[1]}-{arch}.AppImage"
    system_libdir = Path(subprocess.check_output(
        ["pkg-config", "--variable=libdir", "webkit2gtk-4.1"], text=True,
    ).strip())
    system_datadir = Path("/usr/share")

    with tempfile.TemporaryDirectory(prefix="appimage-", dir=release) as work:
        work = Path(work)
        appdir = work / "VeneraX.AppDir"
        desktop = stage_appdir(repo, bundle, appdir, system_libdir, system_datadir)
        subprocess.run(["gio-querymodules", str(appdir / "usr/lib/gio/modules")], check=True)

        linuxdeploy = work / f"linuxdeploy-{arch}.AppImage"
        download_tool(
            f"https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-{arch}.AppImage",
            linuxdeploy,
        )
        download_tool(
            "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh",
            work / "linuxdeploy-plugin-gtk.sh",
        )
        env = dict(os.environ, APPIMAGE_EXTRACT_AND_RUN="1", ARCH=arch,
                   DEPLOY_GTK_VERSION="3", NO_STRIP="1", OUTPUT=str(output))
        env["LD_LIBRARY_PATH"] = str(appdir / "usr/lib") + (
            ":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else ""
        )
        subprocess.run([
            str(linuxdeploy), "--appdir", str(appdir),
            "--desktop-file", str(desktop),
            "--icon-file", str(repo / "debian/gui/venera.png"),
            "--custom-apprun", str(repo / "linux/appimage/AppRun"),
            "--plugin", "gtk",
        ], env=env, check=True)
        # path_provider dlopens the unversioned name. It must share GIO's
        # GApplication state with GTK, not load the GTK plugin's second copy.
        gio_alias = appdir / "usr/lib/libgio-2.0.so"
        gio_alias.unlink(missing_ok=True)
        gio_alias.symlink_to("libgio-2.0.so.0")
        relocate_webkit(appdir, system_libdir, system_datadir)
        subprocess.run([
            str(linuxdeploy), "--appdir", str(appdir), "--output", "appimage",
        ], env=env, check=True)
    if not output.is_file() or output.stat().st_size == 0:
        raise RuntimeError(f"AppImage was not created: {output}")
    print(output)


if __name__ == "__main__":
    main()

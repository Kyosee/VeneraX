"""Prepare the prebuilt runtime used by the locked Flutter plugin on each platform."""

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


def download(url, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3",
         "--output", str(destination), url],
        check=True,
    )


def field(pattern, source):
    match = re.search(pattern, source, flags=re.MULTILINE)
    if not match:
        raise ValueError(f"Could not read locked dependency field: {pattern}")
    return match.group(1)


def github_raw(repository, revision, path):
    owner_repo = repository.removeprefix("https://github.com/").removesuffix(".git")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", owner_repo):
        raise ValueError(f"Unsupported ONNX dependency URL: {repository}")
    return f"https://raw.githubusercontent.com/{owner_repo}/{revision}/{path}"


def android_version():
    return field(r'ext\.onnxRuntimeAndroidVersion\s*=\s*"([\d.]+)"',
                 Path("android/build.gradle").read_text(encoding="utf-8"))


def plugin_pin():
    lock = Path("pubspec.lock").read_text(encoding="utf-8")
    package = field(r"^  flutter_onnxruntime:\n((?:    [^\n]*\n)+)", lock)
    return (field(r'^\s*url: "(https://github.com/[^"]+)"$', package),
            field(r'^\s*resolved-ref: "([0-9a-f]{40})"$', package))


def download_android(output):
    version = android_version()
    module = Path("com/microsoft/onnxruntime/onnxruntime-android") / version
    artifact = module / f"onnxruntime-android-{version}"
    for extension in (".pom", ".aar"):
        path = f"{artifact.as_posix()}{extension}"
        download(f"https://repo.maven.apache.org/maven2/{path}", output / path)
    with zipfile.ZipFile(output / f"{artifact.as_posix()}.aar") as aar:
        for abi in ("armeabi-v7a", "arm64-v8a", "x86_64"):
            if not aar.getinfo(f"jni/{abi}/libonnxruntime.so").file_size:
                raise ValueError(f"Missing Android ONNX runtime for {abi}")


def download_desktop(target, output, temp):
    repository, revision = plugin_pin()
    platform, arch = target.split("-")
    cmake = temp / "CMakeLists.txt"
    download(github_raw(repository, revision, f"{platform}/CMakeLists.txt"), cmake)
    version = field(r'set\(ONNXRUNTIME_VERSION\s+"([\d.]+)"', cmake.read_text(encoding="utf-8"))
    package = temp / "onnxruntime.nupkg"
    download(f"https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/{version}/"
             f"microsoft.ml.onnxruntime.{version}.nupkg", package)
    rid = ("win" if platform == "windows" else "linux") + "-" + arch
    dist = rid.replace("linux-arm64", "linux-aarch64")
    root = output / f"onnxruntime-{dist}-{version}"
    # Match the plugin's NuGet extraction, including companion DLLs and the ELF SONAME.
    with zipfile.ZipFile(package) as archive:
        for name in archive.namelist():
            if name.startswith("build/native/include/") and not name.endswith("/"):
                relative = name.removeprefix("build/native/")
            elif name.startswith(f"runtimes/{rid}/native/") and not name.endswith("/"):
                if platform == "windows":
                    relative = "lib/" + Path(name).name
                elif name.endswith("/libonnxruntime.so"):
                    relative = "lib/libonnxruntime.so.1"
                else:
                    continue
            else:
                continue
            file = root / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(name) as source, file.open("wb") as dest:
                shutil.copyfileobj(source, dest)
    required = ["lib/onnxruntime.dll", "lib/onnxruntime.lib"] if platform == "windows" else ["lib/libonnxruntime.so.1"]
    for name in ["include/onnxruntime_cxx_api.h", *required]:
        if not (root / name).stat().st_size:
            raise ValueError(f"Missing {name} in {rid} package")


def download_apple(output, temp):
    repository, revision = plugin_pin()
    # SwiftPM resolves both binary targets even when the app only links the runtime.
    pins = []
    manifest = temp / "Package.swift"
    for platform in ("ios", "macos"):
        download(github_raw(repository, revision, f"{platform}/flutter_onnxruntime/Package.swift"), manifest)
        pins.append(re.search(r'\.package\(url:\s*"(https://github.com/[^"]+onnxruntime-swift-package-manager)",\s*exact:\s*"([\d.]+)"',
                              manifest.read_text(encoding="utf-8")).groups())
    if pins[0] != pins[1]:
        raise ValueError("The iOS and macOS ONNX package pins differ.")
    download(github_raw(*pins[0], "Package.swift"), manifest)
    source = manifest.read_text(encoding="utf-8")
    for name in ("onnxruntime", "onnxruntime_extensions"):
        binary = field(rf'(?s)Target\.binaryTarget\(name:\s*"{name}",\s*(url:.*?checksum:\s*"[a-f0-9]{{64}}")',
                       source)
        url = field(r'url:\s*"(https://[^"]+)"', binary)
        checksum = field(r'checksum:\s*"([a-f0-9]{64})"', binary)
        # Keep the manifest URL as the SwiftPM cache key for mirrored archives too.
        origin = url.replace("https://download.onnxruntime.ai/", "https://onnxruntimepackages.z14.web.core.windows.net/", 1)
        file = output / re.sub(r"[^A-Za-z0-9_]", "_", url)
        archive_name = url.rsplit("/", 1)[-1]
        if archive_name in {"onnxruntime-libs-1.23.0.zip",
                            "pod-archive-onnxruntime-extensions-c-0.13.0.zip"}:
            mirror = ("https://github.com/Kyosee/flutter_onnxruntime/releases/download/"
                      "apple-onnxruntime-1.23.0-extensions-0.13.0-r1/")
            try:
                download(mirror + archive_name, file)
            except subprocess.CalledProcessError:
                download(origin, file)
        else:
            download(origin, file)
        digest = hashlib.sha256()
        with file.open("rb") as archive:
            for chunk in iter(lambda: archive.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != checksum:
            raise ValueError(f"{name} failed its SwiftPM checksum.")


def install(target, cache):
    if target == "android":
        gradle_home = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle"))
        init = gradle_home / "init.d"
        init.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(__file__).with_name("android.gradle"), init / "venerax-onnx.gradle")
        with Path(os.environ["GITHUB_ENV"]).open("a", encoding="utf-8") as env:
            print(f"VENERAX_ONNX_MAVEN={cache.resolve()}", file=env)
            print(f"VENERAX_ONNX_ANDROID_VERSION={android_version()}", file=env)
    elif target == "apple":
        destination = Path.home() / "Library/Caches/org.swift.swiftpm/artifacts"
        shutil.copytree(cache, destination, dirs_exist_ok=True)
    else:
        platform, arch = target.split("-")
        build = Path("build") / platform / arch
        if platform == "linux":
            build /= "release"
        shutil.copytree(cache, build / "plugins/flutter_onnxruntime/onnxruntime", dirs_exist_ok=True)


def main(command, target):
    if target not in {"android", "apple", "linux-x64", "linux-arm64", "windows-x64"}:
        raise ValueError(f"Unknown ONNX platform: {target}")
    cache = Path("build/ci-onnx") / target
    if command == "key":
        pin = android_version() if target == "android" else plugin_pin()[1]
        if target == "apple":
            pin += "-with-extensions"
        print(f"key=onnx-prebuilt-{target}-{pin}")
    elif command == "install":
        install(target, cache)
    elif command == "download":
        with tempfile.TemporaryDirectory() as directory:
            if target == "android":
                download_android(cache)
            elif target == "apple":
                download_apple(cache, Path(directory))
            else:
                download_desktop(target, cache, Path(directory))
    else:
        raise ValueError(f"Unknown ONNX cache operation: {command}")


if __name__ == "__main__":
    main(*sys.argv[1:])

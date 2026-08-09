import subprocess
import os
import time
import httpx

file = open('pubspec.yaml', 'r')
content = file.read()
file.close()

subprocess.run(["flutter", "build", "windows"], shell=True, check=True)

release_dir = "build/windows/x64/runner/Release"
subprocess.run([
    "dart",
    "compile",
    "exe",
    "tool/windows_updater.dart",
    "-o",
    os.path.join(release_dir, "venera_updater.exe"),
], shell=True, check=True)

if os.path.exists("build/app-windows.zip"):
    os.remove("build/app-windows.zip")

version = str.split(str.split(content, 'version: ')[1], '+')[0]

subprocess.run(["tar", "-a", "-c", "-f", f"build/windows/VeneraX-{version}-windows.zip", "-C", release_dir, "*"]
               , shell=True, check=True)

issContent = ""
file = open('windows/build.iss', 'r')
issContent = file.read()
newContent = issContent
newContent = newContent.replace("{{version}}", version)
newContent = newContent.replace("{{root_path}}", os.getcwd())
file.close()
try:
    file = open('windows/build.iss', 'w')
    file.write(newContent)
    file.close()

    if not os.path.exists("windows/ChineseSimplified.isl"):
        # Download the Inno Setup Simplified Chinese translation (a release-only
        # asset). The jsDelivr CDN occasionally times out (httpx.ReadTimeout),
        # which would fail the whole Windows release build even though the app
        # itself already built. Retry with an explicit timeout and fall back to
        # GitHub raw before giving up, instead of a single bare httpx.get.
        urls = [
            "https://cdn.jsdelivr.net/gh/kira-96/Inno-Setup-Chinese-Simplified-Translation@latest/ChineseSimplified.isl",
            "https://raw.githubusercontent.com/kira-96/Inno-Setup-Chinese-Simplified-Translation/main/ChineseSimplified.isl",
        ]
        isl_content = None
        last_error = None
        for attempt in range(6):
            target = urls[attempt % len(urls)]
            try:
                response = httpx.get(target, timeout=30.0, follow_redirects=True)
                response.raise_for_status()
                isl_content = response.content
                break
            except Exception as error:
                last_error = error
                print(f"ChineseSimplified.isl download attempt {attempt + 1} "
                      f"from {target} failed: {error}")
                time.sleep(3)
        if isl_content is None:
            raise RuntimeError(
                "Failed to download ChineseSimplified.isl after retries: "
                f"{last_error}")
        with open('windows/ChineseSimplified.isl', 'wb') as out_file:
            out_file.write(isl_content)

    subprocess.run(["iscc", "windows/build.iss"], shell=True, check=True)
finally:
    with open('windows/build.iss', 'w') as file:
        file.write(issContent)

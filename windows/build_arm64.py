import subprocess
import os
import httpx

file = open('pubspec.yaml', 'r')
content = file.read()
file.close()

subprocess.run(["flutter", "build", "windows", "--target-platform", "windows-arm64"], shell=True, check=True)

release_dir = "build/windows/arm64/runner/Release"
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

subprocess.run(["tar", "-a", "-c", "-f", f"build/windows/Venera-{version}-windows-arm64.zip", "-C", release_dir, "*"]
               , shell=True, check=True)

issPath = "windows/build_arm64.iss"

issContent = ""
file = open(issPath, 'r')
issContent = file.read()
newContent = issContent
newContent = newContent.replace("{{version}}", version)
newContent = newContent.replace("{{root_path}}", os.getcwd())
file.close()
try:
    file = open(issPath, 'w')
    file.write(newContent)
    file.close()

    if not os.path.exists("windows/ChineseSimplified.isl"):
        # download ChineseSimplified.isl
        url = "https://cdn.jsdelivr.net/gh/kira-96/Inno-Setup-Chinese-Simplified-Translation@latest/ChineseSimplified.isl"
        response = httpx.get(url)
        response.raise_for_status()
        with open('windows/ChineseSimplified.isl', 'wb') as file:
            file.write(response.content)

    subprocess.run(["iscc", issPath], shell=True, check=True)
finally:
    with open(issPath, 'w') as file:
        file.write(issContent)

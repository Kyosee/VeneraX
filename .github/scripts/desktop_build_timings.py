"""Report native target timings from the Flutter release build on GitHub Actions."""
import argparse
import os
from pathlib import Path, PureWindowsPath
import re
import sqlite3
import sys


def windows_log():
    return Path(os.environ["RUNNER_TEMP"]) / "venerax-msbuild-timings.log"


def prepare_windows():
    # CMake invokes MSBuild in several directories while configuring and building.
    root = Path("build/windows")
    root.mkdir(parents=True, exist_ok=True)
    response = root / "Directory.Build.rsp"
    response.write_text(
        f'/fl9\n/flp9:"LogFile={windows_log()};PerformanceSummary;Verbosity=quiet;'
        'Encoding=UTF-8;Append"\n',
        encoding="utf-8",
    )


def windows_targets():
    # FileLogger's project summary excludes the similarly formatted evaluation rows.
    row = re.compile(r"^\s*(\d+)\s+ms\s+(.+?\.vcxproj)\s+\d+\s+calls?\s*$", re.I)
    timings = {}
    reading = False
    with windows_log().open(encoding="utf-8-sig", errors="replace") as log:
        for line in log:
            if line.strip().endswith("Performance Summary:"):
                reading = line.strip() == "Project Performance Summary:"
            match = row.match(line) if reading else None
            if match:
                path = PureWindowsPath(match[2])
                # Keep CMake's release projects and omit the toolchain probes.
                if "cmakefiles" not in (part.lower() for part in path.parts):
                    timings[path.stem] = timings.get(path.stem, 0) + int(match[1]) / 1000
    return timings


def xcode_targets():
    database = Path("build/macos/Build/Intermediates.noindex/XCBuildData/build.db")
    # XCBuild names llbuild commands CP<priority>:target-<name>-<GUID>-...
    target = re.compile(
        r"^CP\d+:target-(.+?)-(?:[0-9a-f]{8,}|PACKAGE-(?:TARGET|PRODUCT|RESOURCE)[:-])",
        re.I,
    )
    timings = {}
    with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True) as db:
        query = """
            SELECT CAST(key AS TEXT), end - start
            FROM rule_results JOIN key_names ON rule_results.key_id = key_names.id
            WHERE CAST(key AS TEXT) GLOB 'CP*:target-*' AND end > start AND start > 0
        """
        for name, seconds in db.execute(query):
            match = target.match(name)
            if match:
                label = match[1]
                timings[label] = timings.get(label, 0) + seconds
    return timings


def report():
    if sys.platform == "darwin":
        title = "macOS Xcode target timings"
        metric = "Cumulative command time"
        detail = "Parallel commands overlap, including builds for different architectures."
        timings = xcode_targets()
    else:
        title = "Windows MSBuild project timings"
        metric = "Elapsed project time"
        detail = "Project times can include referenced projects and overlap during parallel builds."
        timings = windows_targets()
    if not timings:
        raise ValueError("The native build produced no readable target timings.")
    lines = [f"### {title}", "", detail, "", f"| Target | {metric} |", "| --- | ---: |"]
    for name, seconds in sorted(timings.items(), key=lambda row: -row[1]):
        name = name.replace("|", r"\|")
        lines.append(f"| {name} | {seconds:.1f} s |")
    markdown = "\n".join(lines) + "\n"
    print(markdown, end="")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as summary:
        summary.write(markdown)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-windows", action="store_true")
    if parser.parse_args().prepare_windows:
        prepare_windows()
    else:
        report()

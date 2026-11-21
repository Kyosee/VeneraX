#!/usr/bin/env bash
set -euo pipefail

# Match the same published source and native toolchain used by the fork.
read -r version source_sha < <(ruby -ryaml -e 'p = YAML.load_file("pubspec.lock").fetch("packages").fetch("rhttp"); puts [p["version"], p.dig("description", "sha256")].join(" ")')
rust=$(sed -n 's/^channel = "\([^"]*\)"/\1/p' rust-toolchain.toml)
tag="android-rhttp-0.16.0-rust1.95-ndk28.0.13004108-api24-r1"
if [[ "$version" != 0.16.0 || "$rust" != 1.95 || "$source_sha" != 32482042b007474f287f843c298d46a5589aaf8db9603ff78527b5e0bcbee40a ]]; then
  echo "No published Android rhttp for the locked source and Rust version. Using CargoKit."
  exit 0
fi

base="$RUNNER_TEMP/venerax-rhttp"
libs="$base/28.0.13004108-api24"
mkdir -p "$libs"
if ! curl -fsSL --retry 3 "https://github.com/Kyosee/rhttp/releases/download/$tag/rhttp-android.tar.gz" -o "$base/rhttp.tar.gz"; then
  echo "::warning::Published rhttp unavailable. Using CargoKit."
  exit 0
fi
printf '%s  %s\n' 7fc5569681ef2501bf7c90a754d2a391ad85cdbbd6b28679b5bb93a59c22155c "$base/rhttp.tar.gz" | sha256sum --check --strict
tar -xzf "$base/rhttp.tar.gz" -C "$libs" {armeabi-v7a,arm64-v8a,x86_64}/librhttp.so
echo "VENERAX_ANDROID_RHTTP=$base" >> "$GITHUB_ENV"
echo "Prepared Kyosee/rhttp $tag"

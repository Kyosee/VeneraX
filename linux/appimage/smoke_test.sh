#!/usr/bin/env bash
set -euo pipefail

image="$(realpath "$1")"
test_dir="$(cd "$(dirname "$0")" && pwd)"
results="$(dirname "$image")/smoke-test"
mkdir -p "$results"

# Only the desktop graphics stack is installed; GTK and WebKit must come from the AppImage.
docker run --rm \
  -v "$test_dir:/tests:ro" \
  -v "$(dirname "$image"):/artifacts:ro" \
  -v "$results:/results" \
  ubuntu:22.04 bash -euc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y --no-install-recommends \
      python3 xvfb xauth xdotool openbox scrot dbus-x11 \
      libgl1 libegl1 libgles2 libgl1-mesa-dri libxkbcommon0 libasound2 \
      ca-certificates fonts-dejavu-core procps
    test -z "$(find /usr/lib -name "libwebkit2gtk*" -o -name "libgtk-3.so*")"
    mkdir -p /run/dbus
    dbus-daemon --system --fork
    useradd --create-home --uid "$2" smoke
    runuser -u smoke -- xvfb-run -a -s "-screen 0 1280x900x24" \
      dbus-run-session -- python3 /tests/smoke_test.py "/artifacts/$1" /results
  ' -- "$(basename "$image")" "$(id -u)"

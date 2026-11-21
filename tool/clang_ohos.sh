#!/usr/bin/env bash
set -euo pipefail
exec "$RHTTP_OHOS_NATIVE/llvm/bin/clang" \
  --target="$RHTTP_OHOS_CLANG_TARGET" \
  --sysroot="$RHTTP_OHOS_NATIVE/sysroot" -D__MUSL__ "$@"

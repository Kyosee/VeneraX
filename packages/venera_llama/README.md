# venera_llama

A deliberately thin FFI shim over [llama.cpp](https://github.com/ggml-org/llama.cpp)
for on-device comic-translation inference. It exposes a tiny, stable C surface
(`load` / `generate` / `free` / `last_error`) so the Dart binding never has to
track llama.cpp's large, frequently-changing header — the heavy work (tokenize,
decode loop, sampling) lives in `src/venera_llama.cpp`.

The Dart binding is at
`lib/foundation/image_translation/local_llm/llama_ffi.dart` in the main app.

## Why a submodule, not a prebuilt binary

llama.cpp is pinned as a git submodule and compiled from source. This is a
supply-chain choice: every line we ship can be diffed against the pinned commit,
so a compromised upstream release can't slip in unnoticed. The cost is a slow
first clean build; incremental builds are cached and fast.

## One-time setup (before `pod install` / building)

The submodule is **not** cloned automatically by `flutter pub get`. From the
repo root:

```bash
# First time only — register and fetch the pinned llama.cpp:
git submodule add https://github.com/ggml-org/llama.cpp \
    packages/venera_llama/src/llama.cpp
cd packages/venera_llama/src/llama.cpp
git checkout <PINNED_COMMIT>   # pin a known-good commit; see below
cd -
git submodule update --init --recursive
```

After the submodule exists, subsequent checkouts only need:

```bash
git submodule update --init --recursive
```

### Pinning a commit

Pick a recent llama.cpp release tag/commit, check it out inside the submodule,
and commit the resulting gitlink. Record the commit here:

```
llama.cpp pinned commit: <fill in when adding the submodule>
```

Bump it deliberately (read the diff), never float on `master`.

## Platforms

Preview scope is **iOS + macOS** (Metal GPU offload). The podspecs in `ios/`
and `macos/` compile the shim + submodule with `GGML_USE_METAL`. Android
(`android/` CMake), Windows and Linux are stubbed for later — the shim itself
is platform-agnostic C++; only the build glue differs.

## Files

- `src/venera_llama.h` — the stable C surface (all the Dart binding sees).
- `src/venera_llama.cpp` — shim implementation over llama.cpp.
- `src/llama.cpp/` — the pinned submodule (not checked in as files).
- `ios/`, `macos/` — CocoaPods podspecs (source-compile + Metal).
- `android/` — CMake build (stub for preview).

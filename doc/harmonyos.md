# VeneraX HarmonyOS development

Experimental HarmonyOS port of VeneraX. The complete application builds for
ARM64 and x64; runtime validation currently uses the official x64 phone emulator.
Directory access, credential authentication, native PDF rendering and signed
phone installation still need a suitable device. The preview ships an unsigned
ARM64 release HAP that requires device-specific signing before phone installation.
See [preview installation and limitations](harmonyos-testing.md). Debug probes
are only for local development and are not release assets.

## Isolated workspace

Use a separate checkout for HarmonyOS. Both Flutter SDKs write
`.dart_tool/package_config.json` and generated plugin files, so changing only
the Flutter executable is insufficient when another platform builds concurrently.
Keep standard Flutter 3.44.3 for existing platforms.

The tested OH SDK is CPF-Flutter `3.44.9+ohos-1.0.0-beta`, commit
`744cbb4f08e577787774c04033cc19a9d318d0d2` (Dart 3.12.2). This is the adaptation
project linked by [Huawei's documentation](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784651007/),
not an upstream Google Flutter release. Obtain it from
[CPF-Flutter/flutter_flutter](https://gitcode.com/CPF-Flutter/flutter_flutter).
The current version is a development candidate, not a stable release commitment.

Install DevEco Studio from Huawei. Tested with DevEco 26.0.0.865, API 26 SDK,
and a HarmonyOS 7 x86_64 phone emulator. Run in the isolated checkout:

Install Rust 1.85.1 and its OHOS targets through official rustup first:

```powershell
rustup toolchain install 1.85.1
rustup target add x86_64-unknown-linux-ohos aarch64-unknown-linux-ohos --toolchain 1.85.1
```

```powershell
./tool/build_ohos.ps1 -FlutterSdk D:/dev/tools/flutter_ohos `
  -DevEcoStudio 'D:/Program Files/Huawei/DevEco Studio'
```

This builds the complete `lib/main.dart` application in debug mode for x64.
Add `-Target tool/ohos_smoke.dart` for the isolated bootstrap probe. Install
`build/ohos/hap/entry-default-unsigned.hap` with the SDK's `hdc`, then start
`com.github.kyosee.venera` / `EntryAbility`. The probe checks sandbox directories,
package information, file read/write, SQLite WAL, QuickJS values/Promises on
separate isolates, Unicode ZIP entries, 7z extraction and PNG pixel round trips.
Restart it: the launch counter must increase. Persistent probe data uses only
a dedicated `ohos_smoke.db` inside the app sandbox.

For a phone preview, use `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release`.
Native compilation and packaging follow the selected ABI.
Builds are unsigned unless `-CodeSign` is explicitly supplied after configuring
your own valid signing identity in DevEco Studio. A probe is a separate entrypoint:
rebuild and reinstall the complete application after probe validation.

Use `-Target tool/ohos_network_smoke.dart` for the HTTP probe. It runs local
servers on the device and verifies DNS, redirects, cookies, streams, a worker
isolate, the app's Dio adapter, cancellation, timeout and an HTTP proxy. Its
test-only certificate verifies rejection by default, explicit local trust and
hostname rejection without changing any system or application trust settings.

Use `-Target tool/ohos_onnx_smoke.dart` for ONNX CPU inference through the
application's FFI binding. It covers a worker isolate, a Unicode model filename,
output shapes, repeated runs/sessions, invalid inputs and greedy decoding.
This verifies the runtime; OCR models and the complete translation workflow
still need separate application-level validation.

Use `-Target tool/ohos_reader_smoke.dart` for the real source and download
pipeline, using a self-contained loopback comic source and generated images.
It verifies source import/reload, QuickJS network search/details/chapters,
image headers and decoded pixels, background history writes, a queued chapter
download, and offline reads after closing the server. Force-stop and start
the app a second time to verify source, progress and downloads persist across
processes. All probe data stays in a separate `ohos_reader_probe` directory.
This does not verify reader gestures, background recovery or synchronization.

Use `-Target tool/ohos_reader_ui_smoke.dart` for the production Reader with
generated pages, six reading modes, volume navigation, saved progress and the
image enhancement shader. It uses the reader probe's isolated data directory.
Interactive results must be checked separately from compilation.

Use `-Target tool/ohos_backup_smoke.dart` for a complete `.venera` backup
round trip in a fresh temporary directory. It uploads and downloads through a
local authenticated WebDAV server and the production RHttpAdapter, modifies
the fixture, then restores scripts, settings, history, favorites and cookies.
It never configures a remote sync account or restores into the normal app data.

Use `-Target tool/ohos_webview_smoke.dart` for the WebView probe. It verifies
initial custom headers and redirects, JavaScript results, native and HttpOnly
cookies (including deletion), local/session storage, malicious storage keys,
origin isolation, reloads, custom/direct/system proxy switching and rejection
of an untrusted TLS certificate. It uses local servers and no user account.
Passing it does not verify every source's login or anti-bot flow.

Use `-Target tool/ohos_system_smoke.dart` for battery, power-saving state,
connectivity methods/events, screen wake requests, system proxy and available
authentication types. The authentication bridge cancels on backgrounding and
only accepts the official success result. The current emulator has no enrolled
credential; real PIN/biometric success still needs a suitable device.

Use `-Target tool/ohos_file_smoke.dart` for an interactive file export/import
round trip and picker cancellation. The share check opens the system panel;
cancel it without choosing a recipient. Persistent directory authorization and
incoming text/link shares are implemented separately; neither the file round trip
nor mocked bridge tests prove that every device supports directory selection.

The official API 26 phone emulator currently advertises folder selection but
does not expose a completion action inside a directory. A standalone native
UIAbility using the documented FILE/FOLDER options reproduces this behavior.
Directory imports and custom storage paths still need a working picker and an
authorized-directory round trip on a suitable device.
HarmonyOS comic exports use the system save dialog for each generated CBZ, PDF,
EPUB or `.venera_comics` file. Cancellation stops the task; an unsuccessful save
does not count as a completed export. Merged comic archives use one save dialog.

Scan Kit provides the system QR scanner; opening and cancelling its UI is verified.
Cold and warm notification Wants route the complete app to downloading and tasks.
The background bridge shares one official data-transfer task across active
downloads and WebDAV requests, uses actual progress, and releases it when the
last request ends. `tool/ohos_background_smoke.dart` verifies real concurrent HTTP
transfers after backgrounding, truncation/recovery, and notification removal.
Local compression and OCR never claim a network background task. Data Saver
settles pending changes on resume and during active use; it does not promise
unlimited background packaging or uploading.

API 26 alternate launcher icons use the system bundle manager. Startup checks
actual API availability and all configured presets before showing the setting.
`prepare_ohos.dart` generates only OHOS icon resources from the existing project
PNGs; after editing icon assets, `dart tool/prepare_ohos_icons.dart` refreshes them
without re-preparing dependencies. Earlier systems keep their default icon.

`-Target tool/ohos_pdf_smoke.dart` exercises PDF conversion through the official
PDF Kit. Huawei does not support this kit on the x86 emulator; an ARM emulator
or real device is required for native rendering verification. Lifecycle checks
can run locally with `node --test test/ohos/pdf_bridge_test.cjs`; Dart import
cleanup is covered by `test/ohos_pdf_import_test.dart` under the OH Flutter SDK.
Those tests do not substitute for native PDF rendering.

ARM64 compilation does not verify a real phone. Device signing and end-user
sideloading remain unverified. Never distribute a developer's private signing key
or a device-bound profile as a universal installation solution.

## Validation coverage

The following workflows have run on the API 26 x64 emulator. Generated fixtures
are used by the checked-in probes; private acceptance data must stay outside the
repository, build inputs, logs and screenshots. Never upload a user's backup to
cloud devices or external analysis services.

| Workflow | Observed result |
|---|---|
| Source and network | QuickJS import, search, details, chapters, image headers/pixels, TLS rejection, cookies, proxy, cancellation and restart persistence passed |
| Reader | Six reading modes, gesture and volume navigation, double-tap zoom, portrait/landscape rotation and saved progress passed |
| Downloads | Queued complete chapters, restart persistence, offline image decoding and background transfer/recovery passed |
| Backup and WebDAV | Export/restore and authenticated loopback PUT/GET passed, including settings, source data, history, favorites and cookies |
| Comic export | CBZ, PDF, EPUB and single/merged `.venera_comics` system saves passed; cancellation did not count as completion |
| Images and OCR | Native PNG, image enhancement shader, real OCR models, local translation script and stored translated-image redraw passed |
| System integration | File picker round trip/cancellation, share-panel cancellation, WebView storage, notification routes, volume and icon switching passed |

Remaining device checks include directory authorization, enrolled PIN/biometric
success, ARM PDF Kit import/rendering, real QR recognition, source-specific login
and online translation services. Existing bridge/unit tests cover error handling
but do not replace those device checks. Signing and public sideloading must be
validated separately before publishing a test release.

## Dependencies

WebView uses the official CPF-Flutter/flutter_inappwebview OH adapter at commit
`389cf40dbb647f1df7272de5ea6b3401efe27a75`. Supply an existing clean checkout with
`-WebViewSource`, or let preparation fetch that commit from GitCode. Only tracked
source is copied into `.dart_tool/ohos`; the public Flutter wrapper and interface
keep their existing locked versions. Local patches cover interface compatibility,
initial request ordering, HttpOnly deletion, storage isolation and key escaping,
SSL error reporting, and preservation of browser TLS/origin/network boundaries.
The SDK's plugin generator runs after preparation to register the native adapter.
The source checkout and shared Pub cache are never patched.

SQLite is built only by the OHOS CMake project, from the official 3.54.1
amalgamation and [published SHA3-256 digest](https://www.sqlite.org/download.html).
The archive is not a Git dependency or covered by pub's lockfile; checking its
published digest detects replacement/corruption of that downloaded source.
No SQLite binary is added to shared Flutter assets or other platform builds.
The older 3.52.0 source referenced by the existing platform plugin was withdrawn
upstream and is not reused for this new target.

QuickJS, ZIP, 7z and PNG use the source already included in the locked packages.
`prepare_ohos.dart` copies their Dart libraries and licenses into `.dart_tool/ohos`
and adds only the OHOS dynamic-library loader branch. It updates the isolated
checkout's generated package config; it does not modify the shared Pub cache.
CMake compiles the original locked C/C++ sources for both ARM64 and x86_64.

`build_ohos_rhttp.ps1` builds the locked rhttp package's Rust source for both
OHOS targets using Cargo's `--locked` flag and the official SDK's Clang.
HTTP/3 remains enabled. Generated libraries are copied only into `ohos/entry/libs`;
the shared Pub cache and Cargo.lock are not changed. The OHOS loader explicitly
opens this library, while other platforms retain their existing initialization.

`build_ohos_onnx.ps1` builds ONNX Runtime 1.22.0 from Microsoft's commit
`f217402897f40ebba457e2421bc0a4702771968e`, with Eigen's pinned commit
`1d8b82b0740839c0de7f1242a3585e3390ff5f33` from its official GitLab repository.
The initial build fetches these Git sources into `.dart_tool/ohos/sources`.
Existing checkouts can be supplied using `-OnnxSource` and `-EigenSource` on the
main build script. Modified sources other than `tool/ohos/onnxruntime.patch` are
rejected. The patch handles missing pthread affinity and compiler feature
declarations; CPUINFO is disabled, and the complete CPU operator set is retained.
Upstream dependency download checks and TLS verification remain enabled.
Both libraries and their license notices are packaged only in the OHOS target.

The script enforces `pubspec.lock`, uses only process environment variables and
restores them afterwards. Always run preparation after `pub get`; the build script
does both. Upstream Dart native hooks currently identify OHOS as Linux; the
experimental build disables those code assets and builds the supported libraries
with the HarmonyOS toolchain. PDF uses the official system kit on supported
devices instead of a Linux PDFium binary. Do not disable TLS validation, app-lock checks or signature
requirements to work around missing platform implementations.

# VeneraX HarmonyOS development

[中文](harmonyos.md) | English

This guide builds and validates the VeneraX HarmonyOS port from source on **Windows x64**. To install a published test package, use the [developer preview installation guide](harmonyos-testing.en.md). This page covers VeneraX's own HarmonyOS build, signing, probes and device validation.

This is an experimental adaptation. The complete app can be built as x64 and ARM64 HAPs, while runtime records come from the official x64 phone emulator. ARM64 phone signing, installation and runtime, persistent directory authorization, successful authentication and native PDF rendering still need device validation. The records below are historical validation; editing this guide does not rerun them.

## Contents

- [Environment and versions](#environment-and-versions)
- [Quick start: x64 emulator](#quick-start-x64-emulator)
- [Build stages and parameters](#build-stages-and-parameters)
- [ARM64 build, signing and installation](#arm64-build-signing-and-installation)
- [Probes and functional validation](#probes-and-functional-validation)
- [Troubleshooting](#troubleshooting)
- [Validation record and remaining work](#validation-record-and-remaining-work)
- [Appendix: dependency implementation details](#appendix-dependency-implementation-details)

## Environment and versions

### Validated tool combination

| Item | Requirement or record |
|---|---|
| Host | Windows x64, PowerShell and Git; the project scripts use `.bat` / `.exe`, and the ONNX script checks for an x64 host |
| OH Flutter | CPF-Flutter `3.44.9+ohos-1.0.0-beta`, commit `744cbb4f08e577787774c04033cc19a9d318d0d2`, Dart 3.12.2 |
| DevEco | DevEco Studio 26.0.0.865, API 26 SDK |
| SDK components | JBR, Node, ohpm, hvigor, `hdc`, and native SDK Clang, CMake and Ninja |
| Rust | Rust 1.85.1 with `x86_64-unknown-linux-ohos` and `aarch64-unknown-linux-ohos` targets |
| Runtime | Official HarmonyOS 7 / API 26 x86_64 phone emulator; ARM64 phone runtime unverified |
| App declaration | Minimum HarmonyOS 5.0.5 / API 17, target API 26; a minimum declaration is not acceptance testing |
| Other platforms | Existing standard Flutter environment uses 3.44.3 and stays separate from the OH SDK and project directory |

CPF-Flutter is the OpenHarmony adaptation linked by [Huawei's documentation](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784651007/), not a Google upstream Flutter release. These versions are a development-candidate combination that has been used; other versions are not assumed to be interchangeable.

### Obtain and initialize the SDK

Install DevEco Studio from Huawei first, use its SDK manager to install the required components and complete the applicable license steps. The [CPF-Flutter repository README](https://gitcode.com/CPF-Flutter/flutter_flutter) links its environment, application-build and plugin-adaptation documentation.

If the OH SDK is not installed yet, fetch it into a new directory and check out the revision above:

```powershell
git clone https://gitcode.com/CPF-Flutter/flutter_flutter.git D:/dev/tools/flutter_ohos
git -C D:/dev/tools/flutter_ohos checkout --detach 744cbb4f08e577787774c04033cc19a9d318d0d2
```

If you already have a usable SDK, keep it. Do not switch revisions in an SDK directory containing local changes. The paths below are examples; replace them with your installation paths. Open a PowerShell window dedicated to HarmonyOS and run:

```powershell
$flutterOhSdk = 'D:/dev/tools/flutter_ohos'
$devEcoStudio = 'D:/Program Files/Huawei/DevEco Studio'
$ohFlutter = Join-Path $flutterOhSdk 'bin/flutter.bat'
$ohDart = Join-Path $flutterOhSdk 'bin/dart.bat'
$hdc = Join-Path $devEcoStudio 'sdk/default/openharmony/toolchains/hdc.exe'
$env:DEVECO_SDK_HOME = Join-Path $devEcoStudio 'sdk'
$env:JAVA_HOME = Join-Path $devEcoStudio 'jbr'
$env:NODE_HOME = Join-Path $devEcoStudio 'tools/node'
$env:Path = @((Join-Path $flutterOhSdk 'bin'), $env:NODE_HOME, (Join-Path $devEcoStudio 'tools/ohpm/bin'), (Join-Path $devEcoStudio 'tools/hvigor/bin'), (Join-Path $devEcoStudio 'sdk/default/openharmony/toolchains'), $env:Path) -join [IO.Path]::PathSeparator
$env:FLUTTER_STORAGE_BASE_URL = 'https://flutter-ohos.obs.cn-south-1.myhuaweicloud.com'
& $ohFlutter --version
& $ohFlutter doctor -v
git --version
rustup toolchain install 1.85.1
rustup target add x86_64-unknown-linux-ohos aarch64-unknown-linux-ohos --toolchain 1.85.1
rustup run 1.85.1 rustc --version
rustup target list --installed --toolchain 1.85.1
```

These environment variables affect only the current terminal and child processes. Do not copy the OH download source or SDK paths into a standard Flutter development terminal. Recheck the upstream SDK instructions when upgrading.

`--version` should match the OH SDK / Dart version in the table. Fix OHOS toolchain errors reported by `doctor -v` before building. The Rust target list must contain both targets above. The build script also checks native components and pinned source revisions.

## Quick start: x64 emulator

Complete the environment setup first. The following commands reuse `$flutterOhSdk`, `$devEcoStudio`, `$ohFlutter` and `$hdc` from that section.

### 1. Use an isolated project directory

```powershell
git clone https://github.com/Kyosee/VeneraX.git D:/dev/project/venera-harmonyos
Set-Location D:/dev/project/venera-harmonyos
```

Enter an existing isolated checkout instead if you have one. Run all later commands from its project root. Both Flutter SDKs write `.dart_tool/package_config.json`, the package graph and generated plugin files, so standard Flutter and OH Flutter need separate project directories; switching only the executable is insufficient.

VeneraX already contains its `ohos/` project. Do not run `flutter create` for this repository. Do not copy `.dart_tool`, `build` or generated plugin configuration from a standard checkout.

### 2. Build the complete application

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio
Get-ChildItem build/ohos/hap/*.hap
```

The default entrypoint is `lib/main.dart`, the platform is `ohos-x64`, the mode is `debug` and signing is disabled. The first build downloads some sources and compiles native libraries; duration depends on network and host. The stages are listed under [Build stages and parameters](#build-stages-and-parameters).

A successful build prints the actual HAP path. The validated toolchain copies the HAP into `build/ohos/hap/`; an unsigned package is commonly `entry-default-unsigned.hap`. After changing the ABI or mode, the filename may still be the same, and the directory can contain an older artifact. Use the output from the current successful build.

### 3. Connect and check the emulator

Start the official HarmonyOS 7 / API 26 x86_64 phone emulator. Run the first command, replace `REPLACE_WITH_DEVICE_ADDRESS` with an address from its output, then run the remaining command:

```powershell
& $hdc list targets
$device = 'REPLACE_WITH_DEVICE_ADDRESS'
& $hdc -t $device shell uname -m
```

`uname -m` should be `x86_64`. The phone model shown by the emulator does not determine its CPU architecture; an ARM64 HAP cannot be installed on this emulator.

### 4. Install, launch and check

Confirm that `$hap` points to the artifact from this build, then run:

```powershell
$hap = 'build/ohos/hap/entry-default-unsigned.hap'
& $hdc -t $device install $hap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

The tested official x64 emulator accepts this unsigned package; ordinary phones need signing. Check the install output and the actual main screen, then inspect the Settings version and `bm dump`; an install exit code alone is insufficient.

The source-build version comes from the current `pubspec.yaml`; the OH SDK updates the OHOS app version during the build. Do not treat the initial placeholder in `ohos/AppScope/app.json5` or a previous preview version as the current artifact version. A debug build also should not be judged by the preview release package's `debug: false` value.

Back up existing device data before exercising the features you changed. To validate an x64 release, rebuild and repeat the installation checks:

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -TargetPlatform ohos-x64 -BuildMode release
```

## Build stages and parameters

### Actual script order

| Order | Stage and entrypoint | Purpose and failure boundary |
|---|---|---|
| 1 | OH Flutter `pub get --enforce-lockfile` | Resolves locked dependencies; fix dependency, SDK and network problems here first |
| 2 | [prepare_ohos.dart](../tool/prepare_ohos.dart) | Prepares icons, local OHOS dependency copies, WebView patches, package configuration and native source mappings |
| 3 | `refresh_plugins.dart` | Registers adapters with the current OH SDK plugin generator; template is [tool/ohos](../tool/ohos/refresh_plugins.dart.template) |
| 4 | [build_ohos_rhttp.ps1](../tool/build_ohos_rhttp.ps1) | Builds locked Rust sources for both OHOS ABIs |
| 5 | [build_ohos_onnx.ps1](../tool/build_ohos_onnx.ps1) | Fetches pinned ONNX/Eigen sources, applies the project patch and builds both OHOS ABIs |
| 6 | OH Flutter `build hap --no-pub` | Packages by mode, entrypoint and HAP ABI; native CMake also builds SQLite, QuickJS, ZIP, 7z and PNG |

Network access may be required for Pub/Cargo dependencies, the GitCode WebView source, GitHub ONNX, GitLab Eigen, SQLite official source and CMake downloads. `-WebViewSource`, `-OnnxSource` and `-EigenSource` can reuse source checkouts, but the full build is not offline by default.

After manually running `pub get`, OHOS adaptation files must be prepared again. The main script performs resolution, preparation and registration in order. Do not run a later dependency resolution that overwrites generated configuration. The script restores the process variables it changes.

### Parameter table

These parameters belong to [build_ohos.ps1](../tool/build_ohos.ps1).

| Parameter | Default | Purpose |
|---|---|---|
| `-FlutterSdk` | required | OH Flutter SDK root |
| `-DevEcoStudio` | required | DevEco Studio root |
| `-TargetPlatform` | `ohos-x64` | `ohos-x64` or `ohos-arm64`, selecting the final HAP ABI |
| `-Target` | `lib/main.dart` | Complete app or a probe Dart entrypoint |
| `-BuildMode` | `debug` | `debug`, `profile` or `release` |
| `-CodeSign` | off | Enable only after configuring a valid signing identity in DevEco |
| `-WebViewSource` | automatic | Clean checkout at the fixed WebView revision |
| `-OnnxSource` | automatic | ONNX checkout at the fixed revision; only the project compatibility patch is allowed |
| `-EigenSource` | automatic | Clean Eigen checkout at the fixed revision |

`-TargetPlatform` selects the final HAP ABI. The rhttp and ONNX build scripts still compile both `x86_64` and `arm64-v8a` libraries on every run, including probe builds.

## ARM64 build, signing and installation

Build an unsigned ARM64 release HAP:

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -TargetPlatform ohos-arm64 -BuildMode release
```

This only compiles and packages; an ordinary phone cannot install an unsigned HAP. Open the isolated checkout's `ohos` project in DevEco and use Huawei's [automatic signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) or [manual signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) flow to configure your developer identity, certificate and device debug profile.

The bundle name must match `com.github.kyosee.venera`, and permissions must match the project request, including `ohos.permission.FILE_ACCESS_PERSIST`. Keep local signing configuration, certificates, passwords, private keys and profiles out of Git and third-party signing sites. Then build the signed package:

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -TargetPlatform ohos-arm64 -BuildMode release -CodeSign
Get-ChildItem build/ohos/hap/*.hap
```

Confirm that the latest successful output is the signed ARM64 HAP, replace the package path and phone address below, check `uname -m` for the ARM64 device (usually `aarch64`), then install and launch:

```powershell
$signedHap = 'REPLACE_WITH_SIGNED_HAP_PATH'
& $hdc list targets
$device = 'REPLACE_WITH_PHONE_ADDRESS'
& $hdc -t $device shell uname -m
& $hdc -t $device install $signedHap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

Compatible signing is required for upgrades. Do not uninstall an existing app merely to bypass an error, because that can lose data. ARM64 compilation does not establish signing, installation or runtime acceptance; those phone checks remain open. A device-bound debug profile is not a universal distribution package.

## Probes and functional validation

### How to run and judge results

Probes are independent Dart entrypoints for local capability checks. The following builds the basic probe, which is then installed and launched using the Quick Start steps:

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -Target tool/ohos_smoke.dart
```

Replace `-Target` with the entrypoint in the table. Basic and network probes print `PASS` / `FAIL`; OCR uses its own result prefix; the background probe emits structured output and requires manual system checks; the reader UI probe has a separate shader result. Read the complete output and interaction prompts. `Ready`, cancellation or one passing sub-check is not completion.

Probes are local development assets, not release artifacts. Rebuild with `lib/main.dart` and reinstall the complete application afterward. The basic probe uses a dedicated `ohos_smoke.db`; the reader and UI probes use `ohos_reader_probe`; the backup probe uses a fresh temporary directory. Never use a real backup as a fixture.

### Entrypoints, coverage and prerequisites

| Entrypoint in `tool/` | Coverage | Extra checks and limits |
|---|---|---|
| `ohos_smoke.dart` | Sandbox, package information, file I/O, SQLite WAL, QuickJS values/Promises on isolates, Unicode ZIP, 7z and PNG round trips | Restart and check the launch counter |
| `ohos_network_smoke.dart` | Device-local DNS, redirects, cookies, streams, worker isolate, Dio, cancellation, timeout, proxy and TLS | Test certificates cover default rejection, explicit local trust and hostname rejection without changing trust settings |
| `ohos_onnx_smoke.dart` | FFI CPU inference, worker isolate, Unicode model name, output shapes, repeated sessions, invalid input and greedy decoding | Runtime coverage does not replace OCR model or complete translation validation |
| `ohos_reader_smoke.dart` | Loopback source import/reload, QuickJS search/details/chapters, image headers/pixels, history writes, queued download and offline reads | Force-stop and restart to check persistence; gestures, background recovery and sync are separate |
| `ohos_reader_ui_smoke.dart` | Production reader, generated pages, six modes, volume keys, progress and image-enhancement shader | Check gestures, interaction and actual pixels separately |
| `ohos_backup_smoke.dart` | Authenticated local WebDAV and production RHttpAdapter `.venera` round trip; restore scripts, settings, history, favorites and cookies after changing a fixture | No remote sync account and no normal app-data restore |
| `ohos_webview_smoke.dart` | Initial headers/redirects, JS results, native and HttpOnly cookies, storage, malicious keys, origin isolation, reloads, proxy switching and TLS rejection | Local servers and no user account; site-specific login and anti-bot flows still need testing |
| `ohos_system_smoke.dart` | Battery, power saving, connectivity methods/events, screen wake, system proxy and auth types | Background cancellation and official success result; an emulator without credentials cannot prove successful PIN/biometric auth |
| `ohos_file_smoke.dart` | System file export/import round trip and cancellation, share panel opening | Cancel sharing; does not prove persistent directory access or incoming text/link shares |
| `ohos_directory_smoke.dart` | Manually selected directory, read/write, rename, SQLite WAL, ZIP and authorization restore | Requires a usable picker and persistent authorization; restart after first completion; cancellation is not a pass |
| `ohos_background_smoke.dart` | Local concurrent HTTP transfer, ordering, truncation/recovery and notification removal after backgrounding | Grant notifications and manually inspect lifecycle markers, system task state and release |
| `ohos_ocr_smoke.dart` | English OCR, blank comparison, model release/reload, local translation and persistence | Start the model service below; run once completely before restart; no online translation-quality claim |
| `ohos_pdf_smoke.dart` | PDF Kit page conversion, dimensions/pixels and failed-import cleanup | The x64 emulator lacks this Kit; use an ARM emulator or phone with PDF Kit |

### OCR model service

Prepare a local model directory containing `text_detector/det.onnx`, `ocr_en/rec.onnx` and `ocr_en/dict.txt`. The files must be non-empty and no larger than 8 MiB, 16 MiB and 64 KiB. In a second terminal from the project root, replace the model path:

```powershell
& $ohDart tool/serve_ohos_ocr_models.dart 'D:/models/translation_models' 18767
```

The service binds to loopback, uses port `18767` by default, serves only the three allowlisted files and returns Content-Length; stop it with Ctrl+C. The probe reaches the host through `http://10.0.2.2:18767`, which requires the emulator host mapping. It accepts only HTTP roots at `127.0.0.1`, `::1` or `10.0.2.2`, and requires complete downloads within the size limits.

The main build script does not pass `--dart-define`; custom model URLs and restore-only mode are advanced source-level entrypoints, not extra flags to append to the main script. Complete the normal run before checking restart persistence; restore-only cannot replace the first successful run.

### System behavior that needs manual checks

The API 26 official x64 emulator's directory picker currently lacks a completion action after entering a directory; a standalone native UIAbility with the documented FILE/FOLDER options reproduces it. File round trips and mocked bridges do not prove directory authorization. Comic exports open a system save dialog for each CBZ, PDF, EPUB or `.venera_comics`; merged archives use one dialog. Cancellation stops the task and a failed save is not completion.

Scan Kit open/cancel is recorded as passing, while real recognition still needs device testing. Cold and warm notification Wants should be checked for download/task routing. Downloads and WebDAV share one official data-transfer task with real progress and release after the last request. Local compression and OCR do not claim network background work. Data Saver settles pending changes on resume and active use; it does not promise unlimited background packaging or upload.

API 26 alternate icon switching checks availability and all presets at startup. Older systems keep the default icon. `prepare_ohos.dart` generates OHOS resources from project PNGs; after editing assets, use the OH SDK's `dart tool/prepare_ohos_icons.dart` without preparing all dependencies again.

### Focused checks without packaging

For example, when changing PDF lifecycle or import cleanup, run the existing checks below. Node must support the type-stripping API used by the tests. Run the Dart test from a prepared OH checkout with the same OH SDK; `--no-pub` avoids replacing adapted configuration.

```powershell
node --test test/ohos/pdf_bridge_test.cjs
& $ohFlutter test --no-pub test/ohos_pdf_import_test.dart
```

These checks cover bridge lifecycle and Dart import cleanup. They do not replace native PDF Kit rendering or device interaction acceptance.

## Troubleshooting

Find the earliest failed stage and the concrete error in the full log; the final line from the main script is usually only a stage summary.

| Symptom | Next step |
|---|---|
| Missing `flutter.bat`, JBR, Node, Clang, CMake or Ninja | Check the SDK roots and DevEco components; the main script is a Windows build entrypoint |
| `Flutter dependency resolution failed.` | Check the same OH SDK, network and lockfile; do not bypass it by casually updating the lockfile |
| `Run flutter pub get --enforce-lockfile before preparing OHOS again.` | Preparation detected rewritten package configuration; restart through the main script so resolution, preparation and registration happen in order |
| `WebView requires official commit` or `Cannot apply the OHOS loader patch` | Check the pinned source revision and locked dependency shape; do not edit the shared cache to bypass it |
| `Missing OHOS Rust targets` | Install both targets and confirm `rustup run 1.85.1 rustc --version` succeeds |
| `The OHOS ONNX build requires an x64 Windows host.` | Build on Windows x64; selecting an ARM64 HAP does not make the host build ARM64-compatible |
| ONNX/Eigen fetch, revision or source-modification failure | Check access to the official repositories and required revisions; keep only the project patch in reused checkouts |
| `HarmonyOS plugin registration failed.` / `HarmonyOS HAP build failed.` | Inspect earlier Dart, hvigor or CMake errors and check whether a later `pub get` overwrote generated configuration |
| `00801017`, missing `x86_64` ABI or `install parse native so failed` | Compare `uname -m`, target parameters and the actual HAP; exclude an older artifact of another ABI |
| `Hello World` or an old UI remains | A failed install may leave the previous sample app; check command output, bundle name and `bm dump` |
| Phone signing error | Configure your certificate, device profile, bundle name and permissions using Huawei's flow; keep signature checks enabled |
| Directory picker has no completion action or PDF returns `PDF_UNAVAILABLE` | Check the known device limits and use a device with the required capability; do not mark this as passing |
| OCR download failure or a partially passing background probe | Check the local model service, URL/size limits, or manually inspect notifications and system tasks |

Report tool versions, host/device architecture, command, earliest failed stage and redacted errors. Do not attach accounts, cookies, tokens, private backups or signing material.

## Validation record and remaining work

| Level | Current record |
|---|---|
| Build and package | Complete app built for x64 / ARM64; this is not device runtime acceptance |
| x64 emulator | Official HarmonyOS 7 / API 26; the following is the existing record |
| ARM64 phone | Signing, installation, launch and features still need device validation |
| Device-specific capabilities | Directory authorization, successful PIN/biometric auth, ARM PDF Kit, real scanning, site login and online translation each need separate validation |

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

## Appendix: dependency implementation details

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

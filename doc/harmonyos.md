# HarmonyOS development

Experimental platform bootstrap. The native probe runs on a HarmonyOS x64
emulator; the complete reader is not ready. HTTP, files, WebView,
biometric authentication and PDF/native asset support still need adaptation.
Do not distribute this debug HAP as a working Venera release.

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

```powershell
./tool/build_ohos.ps1 -FlutterSdk D:/dev/tools/flutter_ohos `
  -DevEcoStudio 'D:/Program Files/Huawei/DevEco Studio'
```

This builds `tool/ohos_smoke.dart`. Install
`build/ohos/hap/entry-default-unsigned.hap` with the SDK's `hdc`, then start
`com.github.kyosee.venera` / `EntryAbility`. The probe checks sandbox directories,
package information, file read/write, SQLite WAL, QuickJS values/Promises on
separate isolates, Unicode ZIP entries, 7z extraction and PNG pixel round trips.
Restart it: the launch counter must increase. Persistent probe data uses only
a dedicated `ohos_smoke.db` inside the app sandbox.

The unsigned package is for the local emulator. ARM64 compilation does not
verify a real phone. Device signing and end-user sideloading remain unverified.

## Dependencies

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

The script enforces `pubspec.lock`, uses only process environment variables and
restores them afterwards. Always run preparation after `pub get`; the build script
does both. Upstream Dart native hooks currently identify OHOS as Linux; the
experimental build disables those code assets and builds the supported libraries
with the HarmonyOS toolchain. PDF and other missing native libraries are not
supported by this bootstrap. Do not disable TLS validation, app-lock checks or signature
requirements to work around missing platform implementations.

# VeneraX HarmonyOS developer preview

[中文](harmonyos-testing.md) | English

This page covers **`harmonyos-2.3.12-test.1` / app version `2.3.12+257`**. It does not describe later source builds or stable releases for other platforms.

**This is an unsigned developer preview. The x64 package has been installed and launched on an emulator; the ARM64 phone package needs your own signing, and signed phone installation and runtime remain unverified.**

## Contents

- [Download and architecture](#download-and-architecture)
- [Install on an x64 emulator](#install-on-an-x64-emulator)
- [Sign and install on an ARM64 phone](#sign-and-install-on-an-arm64-phone)
- [Verification and limits](#verification-and-limits)
- [Report a problem](#report-a-problem)

## Download and architecture

Open [this preview release](https://github.com/Kyosee/VeneraX/releases/tag/harmonyos-2.3.12-test.1) and select the matching HAP from its assets. Both packages contain the complete app built in release mode.

| File | Target and verification status |
|---|---|
| `VeneraX-2.3.12+257-harmonyos-x64-emulator-test.1-unsigned.hap` | Official x86_64 emulator on Windows; installed and launched on the HarmonyOS 7 / API 26 emulator |
| `VeneraX-2.3.12+257-harmonyos-arm64-test.1-unsigned.hap` | ARM64 phone testing; requires your own signing, with phone installation and runtime unverified |

The phone model shown by an emulator does not determine its CPU architecture. An ARM64 HAP cannot be installed on the tested x86_64 emulator; changing its appearance does not fix an architecture mismatch.

Back up before testing. Updating an existing installation requires compatible signing; do not immediately uninstall it to bypass an error, because that can lose data. For source builds, see the [HarmonyOS development guide](harmonyos.en.md).

## Install on an x64 emulator

### 1. Identify the device

Start the official emulator. In PowerShell, set the path to `hdc` from your DevEco SDK and list the devices. Adjust the example path to your installation.

```powershell
$hdc = 'D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe'
& $hdc list targets
```

Replace `REPLACE_WITH_DEVICE_ADDRESS` below with an address from that list and set the HAP path to your downloaded file, then run:

```powershell
$device = 'REPLACE_WITH_DEVICE_ADDRESS'
$previewHap = 'D:/Downloads/VeneraX-2.3.12+257-harmonyos-x64-emulator-test.1-unsigned.hap'
& $hdc -t $device shell uname -m
```

The architecture should be `x86_64`. After checking it, install and launch:

```powershell
& $hdc -t $device install $previewHap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

### 2. Check the installation

- The VeneraX main screen should open, with version `2.3.12` in Settings.
- For this exact preview package, `bm dump` should show `versionName: 2.3.12`, `versionCode: 257` and `debug: false`.
- Check both the install command output and the actual app. An exit code alone is insufficient.

| Symptom | What to check |
|---|---|
| `00801017`, missing `x86_64` ABI or `install parse native so failed` | Use `uname -m` to check the device, then check whether you selected the ARM64 package |
| The app still shows `Hello World` | A failed install may leave an older sample app in place; check install output, bundle name and version |
| Signature error | Only the tested official emulator is known to allow this unsigned package; ordinary phones need the signing process below |

## Sign and install on an ARM64 phone

The package declares a minimum of **HarmonyOS 5.0.5 / API 17**. That declaration does not establish compatibility testing on the minimum version.

1. Use your own developer identity and Huawei's [debug signing](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing), [automatic signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) or [manual signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) instructions to prepare a certificate and a debug profile containing the target device.
2. The profile must match `com.github.kyosee.venera` and the requested permissions, including `ohos.permission.FILE_ACCESS_PERSIST`. Sign the ARM64 HAP with the signing tool bundled in the DevEco SDK.
3. Connect a phone authorized for debugging. Set `$hdc` and `$device` as above, check the device architecture, and install your signed package.

```powershell
$signedHap = 'D:/Downloads/VeneraX-signed.hap'
& $hdc -t $device shell uname -m
& $hdc -t $device install $signedHap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

Replace the example path. Check the installed version and startup, then exercise the features you need. These are instructions for device testing, not a claim that phone acceptance testing has passed.

For a signed source build, use an isolated checkout, open its `ohos` project in DevEco to configure signing, and follow the [build guide](harmonyos.en.md). Run `tool/build_ohos.ps1` with `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release -CodeSign`.

Keep certificates, private keys, passwords, profiles and local signing configuration on your machine, out of Git and third-party signing websites. Retain your signing material for compatible updates. A device-bound debug profile is not a universal installation solution.

## Verification and limits

The following records belong to this preview. Updating the documentation does not constitute another device test.

| Scope | Recorded result |
|---|---|
| Core local workflows | The official HarmonyOS 7 / API 26 x64 emulator passed backup restore, source/network access, online and offline reading, downloads, history/favorites, six reading modes, WebDAV round trips, system saves and comic archive re-import |
| Network and WebView | Local checks cover cookies, proxies, certificate rejection and storage isolation; this preview fixes manually reconstructed navigation referrers, while individual website logins still need testing |
| Native and release builds | x64 release installed and launched; ARM64 release compiled and its packaged version was inspected, while signed phone installation and runtime remain unverified |
| Pending device checks | PDF import/rendering, successful PIN/biometric authentication, persistent directory authorization, real QR recognition, site-specific login and online translation |
| Known emulator limits | The x64 emulator does not support PDF Kit; its directory picker lacks a completion action; the emulator host has exited unexpectedly without evidence attributing that to VeneraX |

## Report a problem

Include the package filename, device architecture, OS/API version, minimal reproduction steps and redacted errors. Say whether you used this preview or built from source. Do not attach accounts, cookies, tokens, source configurations, real backups or signing material.

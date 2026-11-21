# VeneraX HarmonyOS installation and signing

[中文](harmonyos-testing.md) | English

From `3.0.2-beta.2` onward, HarmonyOS releases include one unsigned ARM64 HAP for phones and tablets. Sign it before installing it on a device.

## Contents

- [Download and architecture](#download-and-architecture)
- [Sign and install on an ARM64 phone](#sign-and-install-on-an-arm64-phone)
- [Verification and limits](#verification-and-limits)
- [Report a problem](#report-a-problem)

## Download and architecture

Open [Releases](https://github.com/Kyosee/VeneraX/releases), choose the version you want and download the file ending in `-harmonyos-unsigned.hap`. Its native libraries are for ARM64 devices. Older releases such as [v3.0.0](https://github.com/Kyosee/VeneraX/releases/tag/v3.0.0) also offered a separate x64 emulator HAP.

Back up before installing. Updating an existing installation requires compatible signing. Uninstalling it can erase your data.

## Sign and install on an ARM64 phone

The package declares a minimum of **HarmonyOS 5.0.5 / API 17**. That declaration does not establish compatibility testing on the minimum version.

1. Use your own developer identity and Huawei's [debug signing](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing), [automatic signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) or [manual signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) instructions to prepare a certificate and a debug profile containing the target device.
2. The profile must match `com.github.kyosee.venera` and the requested permissions, including `ohos.permission.FILE_ACCESS_PERSIST`. Sign the ARM64 HAP with the signing tool bundled in the DevEco SDK.
3. Connect a phone authorized for debugging. Set `$hdc` to your DevEco SDK tool, use `list targets` to find the device address, then check the architecture and install your signed package.

```powershell
$hdc = 'D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe'
& $hdc list targets
$device = 'REPLACE_WITH_DEVICE_ADDRESS'
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

The following distinguishes device checks recorded during the port's development from release-build checks. Earlier device checks do not establish coverage of every OS version, phone or website.

| Scope | Recorded result |
|---|---|
| Core local workflows | The official HarmonyOS 7 / API 26 x64 emulator passed backup restore, source/network access, online and offline reading, downloads, history/favorites, six reading modes, WebDAV round trips, system saves and comic archive re-import |
| Network and WebView | Development checks covered cookies, proxies, certificate rejection and storage isolation, including a fix for manually reconstructed navigation referrers; individual website logins still need testing |
| Release-build checks | The release workflow checks the ARM64 HAP version, release mode, architecture and required native libraries. Signed installation and runtime still need a physical device |
| Pending device checks | PDF import/rendering, successful PIN/biometric authentication, persistent directory authorization, real QR recognition, site-specific login and online translation |
| Known emulator limits | The x64 emulator does not support PDF Kit; its directory picker lacks a completion action; the emulator host has exited unexpectedly without evidence attributing that to VeneraX |

## Report a problem

Include the package filename, device architecture, OS/API version, minimal reproduction steps and redacted errors. Say whether you used this release package or built from source. Do not attach accounts, cookies, tokens, source configurations, real backups or signing material.

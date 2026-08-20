<div align="center">
  <img src="assets/new_logo.png" width="180" alt="VeneraX" />
  <h1>VeneraX</h1>

[![Flutter](https://img.shields.io/badge/flutter-3.44.3-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/Kyosee/VeneraX?style=flat)](https://github.com/Kyosee/VeneraX/stargazers)
[![Release](https://img.shields.io/github/v/release/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/releases)

  <h3><a href="README.md">中文</a> | English</h3>
</div>

VeneraX is a free and open-source, multi-platform comic reader forked from Venera and maintained with enhancements over the original.

> **Original Project:** This project is forked from [venera-app/venera](https://github.com/venera-app/venera).

> [!IMPORTANT]
> **Before downloading, installing, or using this software, please read and fully understand the [User Agreement & Disclaimer](#user-agreement--disclaimer).** By downloading, installing, copying, modifying, or using this software, you are deemed to have read, understood, and accepted it in its entirety; if you do not agree, do not use the software and delete it immediately.

## New Features & Improvements

- [x] Improved WebDAV backup & sync
- [x] Automatic update checks on Windows and Android APK
- [x] Seamless continuous-chapter reading
- [x] Improved local library, follow-updates & favorites
- [x] Task system with background execution and related views
- [x] Chapter read-status changes
- [x] Reading background color (per-comic)
- [x] Night-view mode (warm/black/dim-red overlay, adjustable intensity)
- [x] Android background downloads, follow-update checks, comic import/export
- [x] Windows tray minimize
- [x] Simple image-quality enhancement
- [x] Various UI & UX refinements
- [x] Read-later
- [x] Customizable automatic history cleanup
- [x] Quick WebDAV config sync across devices via QR code
- [x] Long-press to reorder the home screen's function modules
- [x] Multiple library management
- [x] WebDAV comic library (experimental)
- [x] App lock adds PIN, password and pattern unlock
- [x] AI page translation while reading (experimental): images and OCR stay on-device, and only recognized text is sent to an LLM you configure; beginner provider templates/model fetching plus advanced custom settings, resource-saving/balanced/fast presets, whole-chapter pre-translation, smart erase and bounded text layout
- [x] Custom collections: read comics published as separate volumes or parts as one, across sources

## Guide

Setup steps and interactions for each feature are documented in the **[guide](doc/guide.en.md)**. It is also available in the app under Settings → About → Guide.

## Building

<details>
<summary><b>Local build</b></summary>

1. Install [Flutter](https://flutter.dev/docs/get-started/install)
2. Clone the repository and run `flutter pub get`
3. Build for your platform:

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build linux      # Linux
flutter build macos      # macOS
```

Android needs a signing key first — see "Android signing" in the next section.

</details>

<details>
<summary><b>Building on your own GitHub</b></summary>

After forking, you can produce installers with GitHub Actions without setting up a local toolchain.

**1. Enable Actions**

Workflows are disabled in a fresh fork. Open the Actions tab and enable them.

**2. Build a single platform**

Actions → **Build ALL** → Run workflow → pick `windows` / `linux` / `macos` / `ios` / `android` under platform. Download the result from that run's Artifacts.

Windows, Linux, macOS and iOS build with no configuration, but the output is unsigned:

- iOS produces an unsigned ipa; sign it yourself before sideloading.
- macOS produces an unsigned, un-notarized dmg; right-click → Open the first time.

**3. Android signing**

Android requires your own signing key, otherwise the build fails outright. Generate one:

```bash
keytool -genkey -v -keystore venera.jks -keyalg RSA -keysize 2048 -validity 10000 -alias venera
base64 -w0 venera.jks    # use base64 -i venera.jks on macOS
```

Add four secrets under Settings → Secrets and variables → Actions:

| Name | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | output of the base64 command above |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | alias, `venera` in the example |
| `ANDROID_KEY_PASSWORD` | key password |

For local builds, put the same values in `android/key.properties` (the file is never committed):

```properties
storeFile=/absolute/path/venera.jks
storePassword=your keystore password
keyAlias=venera
keyPassword=your key password
```

**Note:** an APK you sign yourself has a different certificate from the released build, so it cannot be installed over it — you must uninstall first. Uninstalling erases app data, so export a backup from inside the app beforehand.

**4. Repoint the update check**

If you intend to distribute your builds, you must first edit the two constants at the top of [`lib/pages/settings/about.dart`](lib/pages/settings/about.dart):

```dart
const kUpdateRepoOwner = 'Kyosee';
const kUpdateRepoName = 'VeneraX';
```

Change them to your own username and repository name. The update check, update-package download, changelog fetch, and the repository link on the About page all resolve through these.

Leaving them unchanged has two consequences: on startup ("Check for updates on startup" is on by default) the app queries this repository's latest release, so your own releases are never detected; and on Windows, clicking "Update Now" installs this repository's build over yours, replacing your version with ours.

**5. Tag-triggered releases (optional)**

Pushing a `v*` tag builds every platform and creates a Release. Three things need attention in a fork:

- `release-notes/<tag>.en.md` and `release-notes/<tag>.zh-CN.md` must exist and be non-empty.
- The tag must equal `v` plus the version in `pubspec.yaml` (excluding anything after `+`).
- The `Verify Android signature continuity` step compares the APK certificate against the previous Release. A fork has no previous Release, so this step always fails — and since Release depends on every platform build, one failure means no assets at all. Remove that step before your first release.

Also: the two `Update_AltStore_*` jobs commit an AltStore manifest back to master and can be deleted if unused; private repos may never get an `ubuntu-22.04-arm` runner and queue forever, so `Build_Linux_ARM64` can be dropped there.

</details>

## Migration

If migrating from [venera-app/venera](https://github.com/venera-app/venera), use a separate WebDAV sync directory. Back up your old data before migrating.

## User Agreement & Disclaimer

> [!NOTE]
> **Special Notice:** Please read and fully understand this statement before downloading, installing, or using this software. By downloading, installing, copying, modifying, or using this software, you are deemed to have read, understood, and accepted all of its terms.

**1. Nature of the Software**

1. This software is a user-configurable, local content reading tool that only provides technical capabilities such as network access, content parsing, reading layout, and local data management. The code is provided "AS IS", without warranty of any kind, express or implied; the maintainers do not guarantee its accuracy, completeness, or fitness for any particular purpose, and you use it at your own risk.
2. By default, this software does not pre-configure, bundle, or provide any third-party website content, data resources, or parsing extensions; the maintainers do not provide any content operation, storage, publishing, or distribution services, nor do they recommend or endorse any third-party content.
3. This project is for personal learning and research only, and its feature development and maintenance are AI-driven. It is a non-profit open-source project: the maintainers conduct no commercial operations and have not authorized any individual or organization to carry out paid distribution, resale, paid installation, traffic diversion, paid communities, or any other commercial activity in this project's name; any third-party commercial activity is unrelated to this project and undertaken at that party's own risk. The project may be suspended, changed, or discontinued at any time without notice.

**2. Extensions and User Conduct**

1. The software's online reading capability is implemented as a JavaScript-extension-compatible API. Users may create and edit extension scripts themselves, or import extension scripts shared by third parties; whether and which extensions are loaded is entirely up to the user to configure lawfully, and the user shall independently judge and bear full responsibility for their origin, legality, accuracy, and applicability.
2. When a user accesses third-party websites through extensions, the network requests are initiated directly from the user's device to the target websites. This software only provides local parsing, layout, and display capabilities, and does not publicly disseminate or redistribute any third-party content. Search results, chapter loading, image availability, and content copyright all depend on the respective websites and extensions, and are unrelated to this project.
3. Users must comply with the laws and regulations of their jurisdiction, network security requirements, and the terms of service and copyright policies of the relevant websites. Users must not use this software to infringe intellectual property rights, obtain data without authorization, distribute unlawful content or malware, disrupt any network service, or harm the lawful rights and interests of any company or individual.

**3. Third-Party Platforms and Communities**

Any extension-sharing platform, website, forum, or chat group established or maintained by third parties is an independently operated third party with no affiliation to this project. This project does not participate in the creation, publication, operation, maintenance, or distribution of such third-party extensions or communities, and assumes no obligation of proactive review; all risks and liabilities arising from using third-party extensions or accessing third-party websites shall be borne by the responsible parties in accordance with the law.

This project has not established and does not operate any official community, group, or public account, nor has it authorized any third party to advertise, promote, or publish in its name.

**4. Privacy and Data**

1. All features of this software run on the user's local device. This project operates no server, does not collect or upload any user data (including reading content, extension lists, or browsing history) to the maintainers, and integrates no analytics, crash-reporting, or telemetry components. Optional features that the user explicitly enables (such as AI translation) may send data to third-party services the user configures; see item 3 below.
2. Network and storage permissions are used only to implement the software's features such as online reading, local backup import/export, WebDAV sync, app update checks, AI translation, and translation model downloads, and for no other purpose; WebDAV sync transmits data only to a server configured by the user, and the maintainers cannot access, obtain, or control that server or any data stored on it.
3. AI translation is an optional feature that is disabled by default and ships with no preset provider, endpoint, or key. When the user enables it, recognized text is sent only to the third-party model service the user configures themselves; whether to use it, and which provider to use, is the user's own decision, and the user shall comply with that provider's terms — the maintainers neither access nor control such requests or data. The optional offline translation engine downloads publicly released, permissively licensed model files from a user-configurable public repository (such as HuggingFace or a mirror).

**5. Intellectual Property**

1. This project respects intellectual property rights. If a rights holder believes that the code or files directly contained in this repository infringe their lawful rights, they may submit a valid notice with identity proof, ownership proof, and specific details to the maintainers, who will handle it within their reasonable technical capabilities.
2. This project neither hosts nor controls any third-party extension or the third-party content parsed or presented by extensions, and is therefore unable to take removal, blocking, or other measures against them; rights holders should assert their rights against the publisher of the relevant extension or the party actually hosting the content.
3. This project does not accept issues or technical-support requests concerning third-party website content, extension configuration, the availability of specific works, or copyright ownership.

**6. Limitation of Liability**

1. To the maximum extent permitted by applicable law, this project and its maintainers shall not be liable for any direct, indirect, incidental, special, punitive, or consequential losses arising from the use of or inability to use this software, or from third-party extensions, third-party websites, network conditions, data loss, device failure, account issues, copyright disputes, or similar causes. Users shall evaluate and bear all risks of using this software.
2. This project does not guarantee compatibility with any third-party website, extension, or service, nor the continued availability of any feature.

**7. Derivative Work and Redistribution**

1. This project is a modified version of Venera, independently developed and published by this project's maintainers; the upstream project and its maintainers bear no responsibility for this project's code, builds, or conduct. The allocation of responsibility in this section runs both ways and applies equally to any version derived from this project.
2. Any version modified, built, or distributed from this project's source code (including forks, private builds, and self-signed installers) is the sole responsibility of whoever publishes that version. This project's maintainers do not review, endorse, or support such versions, and bear no responsibility for their code, builds, conduct, or any consequences thereof.
3. A modified version should be published under a distinguishable name and state prominently that it is a modified version of this project; it must not claim authorization or endorsement from this project, or any affiliation with it.
4. Only the builds provided on this repository's Release page are published by this project. Installers obtained through other channels, and any build that ships preset extension scripts, extension repository addresses, or content-source lists, are unrelated to this project; their integrity, security, and compliance are the responsibility of whoever provides them.
5. Whoever publishes a modified version shall fulfill the obligations in the LICENSE themselves and comply with the laws and regulations of their own jurisdiction, bearing the resulting responsibility.

**8. Miscellaneous**

1. Do not promote or advertise this project on any public or official platforms or official account areas (including but not limited to Weibo, WeChat Official Accounts, X, etc.).
2. This software is licensed and distributed under the license set out in the LICENSE file at the root of the repository; this disclaimer does not modify or limit the rights granted by that license, and the license prevails in case of conflict.
3. By downloading, copying, modifying, or using this project, you are deemed to have read and accepted this disclaimer in its entirety. The maintainers reserve the right to modify or supplement this disclaimer at any time, effective upon publication.

## Star History

<a href="https://www.star-history.com/?type=date&repos=Kyosee%2FVeneraX">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&theme=dark&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
    <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
  </picture>
</a>

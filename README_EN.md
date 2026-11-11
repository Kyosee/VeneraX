<div align="center">
  <img src="assets/new_logo.png" width="180" alt="VeneraX" />
  <h1>VeneraX</h1>

[![Flutter](https://img.shields.io/badge/flutter-3.44.3-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/Kyosee/VeneraX?style=flat)](https://github.com/Kyosee/VeneraX/stargazers)
[![Release](https://img.shields.io/github/v/release/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/releases)

  <p><a href="README.md">中文</a> | English</p>
</div>

VeneraX is a free, open-source comic reader for multiple platforms, maintained and enhanced from Venera.

**[Download](#download--installation) · [Features](#new-features--improvements) · [Guide](doc/guide.en.md) · [Changelog](CHANGELOG_EN.md) · [Feedback](#feedback--contributions)**

> **Original Project:** This project is forked from [venera-app/venera](https://github.com/venera-app/venera).

> [!IMPORTANT]
> **Read the [VeneraX User Agreement and Disclaimer](#venerax-user-agreement-and-disclaimer) before use** for information about the Software’s features, third-party service risks and data processing. This Notice adds no license restrictions beyond the GNU GPLv3; any separate consent to data processing required by law must still be obtained.

## Download & Installation

**[Download the latest release](https://github.com/Kyosee/VeneraX/releases/latest)** · [All releases](https://github.com/Kyosee/VeneraX/releases)

Choose a package for your operating system and processor architecture, and read the installation notes for that release.

HarmonyOS is a developer preview: [test package installation](doc/harmonyos-testing.en.md) · [source builds and adaptation](doc/harmonyos.en.md).

<details>
<summary><b>Linux AppImage installation</b></summary>

Download `VeneraX-<version>-x86_64.AppImage` (64-bit Intel / AMD) or `VeneraX-<version>-aarch64.AppImage` (ARM64) from [Releases](https://github.com/Kyosee/VeneraX/releases). Make it executable and run it directly:

```bash
chmod +x VeneraX-<version>-x86_64.AppImage
./VeneraX-<version>-x86_64.AppImage
```

Replace the version and architecture in these examples. AppImages bundle GTK, WebKitGTK, ONNX Runtime and tray libraries, and are built on Ubuntu 22.04. They require glibc 2.35 or newer, desktop graphics drivers and X11 / XWayland; older glibc and musl-based systems such as Alpine are not supported. If FUSE is unavailable, extract and run:

```bash
./VeneraX-<version>-x86_64.AppImage --appimage-extract
./squashfs-root/AppRun
```

To update, download the new AppImage and replace the old file. Application data stays in the existing user data directory.

</details>

## New Features & Improvements

<details open>
<summary><b>View all features</b></summary>

### Reading

- [x] Seamless continuous-chapter reading
- [x] Chapter read-status changes
- [x] Custom chapter order: sort chapters in bulk by name, in reverse or by folder modified time, hide duplicate chapters; the order syncs
- [x] Auto page turning adds a steady scroll mode, plus an option to keep the screen on while reading
- [x] Night-view mode (warm/black/dim-red overlay, adjustable intensity)
- [x] Reading background color (per-comic)
- [x] E-ink screen support (experimental): full refresh on page turn to clear ghosting, and the system ripple page turn on iReader devices

### Library management

- [x] Improved local library, follow-updates & favorites; follow updates across several favorite folders, with a check interval, a check on startup and a daily scheduled check
- [x] Read-later
- [x] Multiple library management
- [x] Custom collections: read comics published as separate volumes or parts as one, across sources
- [x] Reading statistics: tracks reading time, with sorting and swipe-to-delete
- [x] Draw a comic: pick a random comic from your favorites, with a selectable scope
- [x] Import local PDF comics
- [x] Custom comic cache directory
- [x] Customizable automatic history cleanup

### Sync & privacy

- [x] Improved WebDAV backup & sync, with a per-item choice of settings to skip
- [x] Quick WebDAV config sync across devices via QR code
- [x] WebDAV comic library (experimental)
- [x] App lock adds PIN, password and pattern unlock

### Translation & image quality

- [x] AI page translation while reading (experimental): images and OCR stay on-device, and only recognized text is sent to an LLM you configure; beginner provider templates/model fetching plus advanced custom settings, resource-saving/balanced/fast presets, whole-chapter pre-translation, smart erase and bounded text layout; Traditional Chinese (including vertical text), custom target languages, custom translation API scripts, and a "Translated Comics" section on the home page
- [x] Simple image-quality enhancement, with a live before/after preview

### Platform & interface

- [x] Task system with background execution and related views
- [x] Android background downloads, follow-update checks, comic import/export
- [x] Windows tray minimize
- [x] Customizable desktop keyboard shortcuts: fullscreen, page turning, chapter switching, reading menu and more; Windows global shortcuts can hide the app to the tray or bring its window back
- [x] Automatic update checks on Windows and Android APK
- [x] Long-press to reorder the home screen's function modules
- [x] Various UI & UX refinements

</details>

## Guide

Setup steps and interactions for each feature are documented in the **[guide](doc/guide.en.md)**. It is also available in the app under Settings → About → Guide.

### First Launch and Upgrade Notice

The current development version shows onboarding once only for a fresh installation with no local application data: first read the agreement in a selectable language, then choose the interface language and review basic permissions, and finally choose whether to import a backup or configure WebDAV. Optional setup can be skipped. Users with existing data receive a one-time notice for this agreement version after upgrading and do not repeat new-user onboarding.

The accepted agreement version, acceptance time, and reading language are stored on this device. Routine app updates do not repeat the prompt. Material agreement changes show a summary and the full new text for renewed acceptance. Importing a backup or restoring from WebDAV cannot accept the agreement on this device. Declining or leaving it unconfirmed does not delete existing data; when app lock is enabled, unlock comes first. Maintainers changing material terms must update the agreement version, date, change summary, and all supported translations together.

System permissions, WebDAV, translation and any other data processing that legally requires separate consent are chosen or authorized separately. Accepting the agreement does not replace those authorizations. This flow is a current development change; release notes determine its availability in a published version.

On desktop, step three shows “Features and access” without inactive permission controls. It explains network and system restrictions, in-app task progress, and file selection during import and export; protected folders may still require system confirmation. Android and HarmonyOS retain the supported notification permission action.

### Changelog

See the **[Changelog](CHANGELOG_EN.md)** for what each version added, changed and fixed. It updates automatically after every stable release. When the app finds a new version, the update dialog also shows what changed.

### Migration

If migrating from [venera-app/venera](https://github.com/venera-app/venera), use a separate WebDAV sync directory. Back up your old data before migrating.

## Feedback & Contributions

Report app bugs and suggest features in [Issues](https://github.com/Kyosee/VeneraX/issues). Include the app version, operating system and device information, and steps to reproduce the problem.

Submit code improvements through [Pull requests](https://github.com/Kyosee/VeneraX/pulls).

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

Build Linux AppImages on Ubuntu 22.04 for the matching architecture. In addition to Flutter's Linux build dependencies, install `webkit2gtk-4.1 libayatana-appindicator3-dev librsvg2-dev libglib2.0-bin glib-networking`. After `flutter build linux --release`, run `python3 linux/appimage/build.py x64` (`arm64` for ARM64). Output is in `build/linux/<architecture>/release/appimage/`. Packaging downloads linuxdeploy and its GTK plugin and requires internet access.

</details>

<details>
<summary><b>Building on your own GitHub</b></summary>

After forking, you can produce installers with GitHub Actions without setting up a local toolchain.

**1. Enable Actions**

Workflows are disabled in a fresh fork. Open the Actions tab and enable them.

**2. Build a single platform**

Actions → **Build ALL** → Run workflow → pick `windows` / `linux` / `macos` / `ios` / `android` under platform. Download the result from that run's Artifacts.

Linux builds produce deb and Arch packages plus AppImages. The AppImages are in `appimage_build` (x86_64) and `appimage_arm64_build` (ARM64); version-tag builds attach them to the Release automatically.

CI also launches both AppImages in Ubuntu 22.04 containers without system GTK or WebKit, then exercises the real web login flow to verify page JavaScript and native callbacks. Screenshots and logs are in `appimage_smoke_x64` and `appimage_smoke_arm64`. To retest existing packages, select `linux` and set `appimage_run_id` to the original build run ID; leave it empty to build and test normally.

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

## VeneraX User Agreement and Disclaimer

Agreement version: 1 · Updated: 2026-11-10

<details open>
<summary><b>Read the full agreement</b></summary>

**Important Information Before Reading**

In this Notice, “the Software” means VeneraX; “the Project” means the open-source project that releases the Software; “the Maintainers” means the individuals or organizations that actually maintain or release the relevant version of the Project; and “Users” means individuals or organizations that install or use the Software. Contributing code, documentation or other work does not, by itself, make a contributor responsible for the entire Project, the actions of other parties or third-party services.

This Notice provides information about the Software’s features, risks associated with third-party services and related data processing. It does not replace applicable law or the GNU GPLv3 in the repository’s LICENSE file. The rights to run, copy, modify and distribute the Software that Users have under applicable law and the license are not subject to additional restrictions under this Notice. Acknowledging this Notice does not replace any separate consent to personal information processing that is required by law, nor does it exclude or limit any rights or liabilities that the law prohibits from being excluded or limited.

**1. Nature and Purpose of the Software and the Project**

1. The Software is a content-reading tool that runs locally on Users’ devices and can be configured by Users. It provides technical features such as network access, content parsing, reading layouts and local data management. To the extent permitted by applicable law, the Software is provided as is; warranties and limitations of liability are governed by Section 6 of this Notice, the GNU GPLv3 and applicable law.
2. By default, the Software released by the Project does not include third-party comic content, comic source extensions, source repository URLs or content source lists. The Maintainers do not operate, host or distribute third-party comic content to the public through the Software. Technical compatibility with a third-party resource does not constitute a recommendation, certification or endorsement of that resource by the Project. For third-party services such as optional translation, update checks and model downloads, see Section 4.
3. The Project is currently maintained on a non-profit basis, and AI-assisted tools are used during development and maintenance. The Maintainers have not authorized any third party to act officially on behalf of the Project in paid distribution, sales, installation services, traffic promotion or paid communities; authorization or endorsement by the Project must not be fabricated. This description of the Project does not restrict lawful uses or paid distribution permitted by the GNU GPLv3. The Maintainers may adjust, suspend or discontinue further development, maintenance and releases according to actual circumstances, without committing to ongoing updates or a fixed support period. The exceptions for applicable law and valid written undertakings described in Section 6 of this Notice continue to apply.

**2. Extensions and User Conduct**

1. The Software’s online reading features are implemented through a compatible JavaScript extension API. Users may create, edit or import third-party extension scripts and decide whether to load extensions and which extensions to use. Users should verify the source, features and suitability of extensions and are responsible for their own configuration, authorization and use. Untrusted scripts may make unexpected network requests or access related data. The Project provides no warranty as to the security, legality, accuracy or continued availability of third-party extensions imported by Users. For limitations of liability and their exceptions, see Section 6.
2. When Users access third-party websites through extensions, the relevant network requests are sent from Users’ devices to the target services according to the extension and network configuration. The Software provides local parsing, layout and display capabilities; this does not mean that the Project hosts, publicly disseminates or redistributes third-party content. Search results, chapter loading and image availability depend on the relevant services and extension implementations. Access conditions and availability of third-party services are managed by their providers, while rights in content and the scope of authorization depend on lawful authorization from the actual rights holders. Statements made by third-party websites or extensions do not, by themselves, establish that they hold the relevant rights.
3. Users must comply with the laws and regulations of their jurisdiction, network security requirements, and the terms of service and copyright rules of the relevant websites. Users must not use the Software for unlawful or prohibited activities such as infringing intellectual property rights, obtaining data without authorization, distributing illegal content or malware, or interfering with or disrupting network services, and must not harm the lawful rights and interests of any company or individual.

**3. Third-Party Platforms and Communities**

1. Extension-sharing platforms, websites, forums and discussion groups established or maintained by independent third parties are operated by those third parties. The Project does not participate in their creation, publication, operation or maintenance. Technical compatibility or a reference to a name does not, by itself, create an agency, partnership, affiliation or endorsement relationship. The Project does not provide content review, certification or quality assurance services for those platforms, extensions or services. Their content, operating arrangements and service commitments are managed by their respective providers; responsibility for them is not transferred to the Maintainers merely because Users access them through the Software.
2. The Project does not currently establish or operate any official user community or discussion group. The Project’s identity and release information are determined by the repositories and release channels publicly identified by the Project. Third-party communities, accounts or paid services do not acquire authorization merely by using the Project’s name. Without actual authorization, no party may advertise, promote or publish in an official capacity on behalf of the Project or claim approval by the Maintainers.

**4. Privacy, Permissions and Data**

1. The Software runs as a client on Users’ devices, where local reading and management data is stored. Network features send requests to the corresponding target services for their stated purposes. The Project does not operate content or synchronization servers for collecting Users’ reading data, does not automatically upload reading content, installed comic source lists or browsing history to the Maintainers, and does not integrate analytics, crash analysis or telemetry components. Issues, logs and other feedback voluntarily submitted by Users are processed by the relevant platforms and actual recipients under applicable law and their respective rules. Passwords, tokens and unnecessary private information should be removed before submission. This section describes the behavior of versions released by the Project and provides no assurance about data processing by third-party modified versions or scripts imported by Users.
2. The Software’s own network and file access supports features such as online reading, backup import and export, WebDAV synchronization, update checks, translation and model downloads. Online content requests are sent to the configured comic sources or target services, while updates and model downloads access the corresponding release or download services. Recipients may receive the IP address needed to establish a connection, request contents, and account credentials or cookies required by the service. Request routing is also affected by system network and proxy settings. WebDAV transfers the selected data to the server configured by Users; providing this feature does not give the Maintainers administrative privileges or data access rights on that server. Other access performed by third-party extensions or scripts should be verified separately.
3. Translation is optional and is not automatically enabled in the initial configuration. Users may choose a translation service or custom script and decide whether to enable it. Once enabled, recognized text is sent to the selected translation service. Model-based translation may also send prompts and necessary context, while the destinations and scope of data sent by custom scripts depend on their implementation. These requests originate from Users’ devices according to the selected service and network configuration; the Project does not provide a relay service for translation requests. Users should check the recipient, the content sent, billing and data processing rules, and may stop further use. Stopping use does not automatically delete data already sent to third parties. Rights such as deletion should be exercised under applicable law and through the relevant service’s procedures.
4. Notifications provide alerts for completed downloads, background tasks and similar events; availability and authorization methods vary by operating system. File access is used as needed for imports, exports and local content operations. Users may decline optional permissions, which may limit the related features while leaving basic features unrelated to those permissions unaffected. WebDAV synchronization and translation are configured and enabled separately by Users. Acknowledging this Notice does not replace system authorization or a choice to use a particular feature. Where the law requires separate notice, consent or other data processing obligations, the responsible processing party must fulfill those requirements under applicable law.
5. Importing, restoring or synchronizing data may overwrite or change data on the local device or the selected server. Users should check the destination, transfer direction and on-screen instructions, and keep necessary backups. An application data backup is not a backup of downloaded images. Depending on the backup method and selected scope, files may contain favorites, history, comic sources, application settings, cookies, login information and service configurations. Some service keys may be stored or synchronized in plain text as part of the configuration. Comic images should be handled separately through the relevant export or synchronization features. Users should safeguard backups and server credentials and avoid publicly sharing files containing private information.
6. Disabling synchronization or removing a server configuration does not automatically delete copies previously uploaded to a third-party server. Users who need to delete remote data should use the management methods provided by the relevant service. Uninstalling the Software or clearing local data may cause unbacked-up content to be lost. Before doing so, Users should confirm that data to be retained has been properly backed up.

**5. Intellectual Property and Feedback**

1. The Project respects intellectual property rights. Rights holders who believe that code or files directly contained in this repository infringe their lawful rights and interests may use the feedback channels publicly identified by the Project to provide the location of the relevant files, a specific explanation of the issue and reasonably necessary evidence of their rights. The handling of a notice depends on the materials provided, the Project’s actual scope of control and applicable law. It does not constitute a determination of ownership or a guarantee of a particular outcome. Before submitting sensitive materials such as proof of identity, an appropriate non-public submission method should be confirmed; such materials should not be posted directly in public issues or comments.
2. The Project has no authority to directly delete, modify or manage content, extensions or services controlled by independent third parties that the Project does not host or manage. Requests for action concerning them should be directed to the actual host, publisher or other relevant party. The Software’s ability to access, parse or display third-party resources does not, by itself, make the Maintainers responsible for their content, operation or services. Specific responsibilities are determined by the actual conduct of the relevant parties and applicable law.
3. Third-party website content, account issues, extension configuration and the availability of particular works are outside the Project’s routine technical support scope. The Maintainers do not determine copyright ownership of third-party content. Software defects and rights notices concerning code or files in this repository may be reported through the channels publicly identified by the Project. Providing feedback channels does not constitute a commitment to offer free support for every issue, guarantee a resolution or provide a fix within a fixed period. The exceptions for applicable law and valid written undertakings described in Section 6 continue to apply.

**6. Quality Information and Limitations of Liability**

1. To the extent permitted by applicable law, unless the relevant responsible party has made a valid written undertaking or agreement to the contrary, the Software is provided “as is” under Section 15 of the GNU GPLv3, without express or implied warranties, including warranties of merchantability or fitness for a particular purpose. To the extent permitted by Section 16 of the GNU GPLv3 and applicable law, except as required by law or otherwise agreed in a valid written agreement by the relevant parties, copyright holders and parties that modify or distribute the Software under the license are not liable to Users for damages arising from the use of or inability to use the Software. These include general, special, incidental or consequential damages, as well as losses caused by loss of data, inaccurate data or failure to operate with other software. Neither this provision nor any other limitation of liability in this Notice excludes or limits liabilities or statutory rights of Users that the law prohibits from being excluded or limited. Where Chinese law applies, these include liability for personal injury to the other party and liability for property damage to the other party caused intentionally or through gross negligence.
2. Subject to the limitations of liability and exceptions in the preceding paragraph, the Maintainers do not guarantee that the Software will always be accurate, secure, complete or free of defects, that it will operate without interruption or data loss, or that it will meet any particular purpose. Nor do they guarantee continued compatibility with third-party websites, extensions, models or services. The Project makes no warranty concerning the continued availability, charging rules or performance of commitments of third-party services. Users should assess the risks of use in light of their own needs and keep necessary backups in accordance with the instructions for the relevant features.

**7. Open-Source License, Modified Versions and Distribution**

1. The Project is a modified version of Venera, independently developed and released by the Project’s Maintainers. Derivation does not, by itself, create an agency, partnership or endorsement relationship between VeneraX and the upstream project or its maintainers, nor does it automatically make either party responsible for the other’s modifications, releases or operations. The same principle applies to versions derived from VeneraX. Actual authorization is determined by the applicable license and any other valid authorization.
2. Modifications, builds or distribution carried out by third parties using the Project’s source code, including forks, private builds and independently signed installation packages, are not automatically releases or maintenance activities of the Project. The Project’s Maintainers do not provide routine review, technical support or quality warranties for third-party versions. Responsibility for modifications, bundled content and service commitments added by third parties does not automatically transfer to the Project’s Maintainers because the Project’s source code is used. The relevant limitations of liability and their exceptions are governed by Section 6.
3. When releasing modified versions, the applicable copyright, license and no-warranty notices must be retained in accordance with the GNU GPLv3, prominent notices of modifications and relevant dates must be provided, and the corresponding source code provision obligations must be fulfilled. External branding and promotion must not mislead Users into believing that the version is an official release of the Project. Approval or endorsement by the Project must not be claimed without actual authorization. Use of the name and Project identifiers must comply with applicable law and lawful requirements permitted by the license. This Notice does not thereby add distribution restrictions beyond those permitted by the license.
4. This repository’s Release page is the channel through which the Project publishes its own builds. Official default installation packages do not include comic source extensions, source repository URLs or content source lists. Third-party modified builds that include such configurations do not become official releases merely by using the same name or icon. When obtaining installation packages through other channels, the actual publisher and any modifications should be checked. Redistributing an original package does not confer official agency, partnership or endorsement status or create an additional quality warranty. Distribution permissions and limitations of liability are governed by the GNU GPLv3 and Section 6 of this Notice, respectively.
5. The Software is licensed under the GNU GPLv3 contained in the LICENSE file at the repository root. The rights to run, copy, modify and distribute the Software that Users have under applicable law and the license, including paid distribution permitted by the license, are not subject to additional restrictions under this Notice. Modification or distribution of the Software requires compliance with the corresponding license obligations and applicable law. Running the Software is not conditional on accepting additional restrictions on use or waiving statutory rights.

**8. Public Information About the Project and Changes to This Notice**

1. The Project is developed with limited maintenance resources and discourages large-scale publicity, marketing or traffic promotion on public platforms. Posting promotional material on unrelated platforms, in comment sections or in communities should be avoided. This communication preference is not an additional license condition for running, copying, modifying or distributing the Software and does not restrict lawful, truthful descriptions, reasonable commentary or distribution permitted by the GNU GPLv3. No party may fabricate Project authorization, a commercial partnership or endorsement by the Maintainers, impersonate an official representative to provide paid services, or mislead Users.
2. This Notice does not modify or restrict the rights granted by the GNU GPLv3. If it conflicts with the license, the applicable license prevails. Where statutory rights, liabilities or obligations cannot be excluded or limited by agreement, the mandatory provisions of applicable law prevail.
3. Selecting “Agree and continue” indicates that Users have read and agree to the legally valid and applicable terms of this Notice and acknowledge awareness of its risk notices and limitations of liability. This acknowledgment does not replace any separate consent to personal information processing that is required by law, nor does it exclude or limit any rights or liabilities that the law prohibits from being excluded or limited. The Maintainers may revise this Notice according to the version and actual circumstances and publish the changes. Where changes to data processing actually carried out by the Maintainers legally require separate notice or consent, the relevant procedures must be followed under applicable law. Merely publishing a new version of this Notice does not automatically make new authorizations or additional restrictions effective for Users, nor does it retroactively change rights already acquired under the GNU GPLv3. The Maintainers do not guarantee advance notice of changes to third-party services, extensions or user configurations.

</details>

## Star History

<a href="https://www.star-history.com/?type=date&repos=Kyosee%2FVeneraX">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&theme=dark&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
    <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
  </picture>
</a>

## Acknowledgements

- [Venera](https://github.com/venera-app/venera): The upstream project of VeneraX. Thanks to its developers and contributors.
- [EhTagTranslation](https://github.com/EhTagTranslation/Database): Chinese translations of comic tags.
- Thanks to everyone who reports issues, tests, or contributes code to VeneraX.

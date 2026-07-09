# Venera

[![Flutter](https://img.shields.io/badge/flutter-3.44.3-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/kyosee/venera)](https://github.com/kyosee/venera/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/kyosee/venera?style=flat)](https://github.com/kyosee/venera/stargazers)
[![Release](https://img.shields.io/github/v/release/kyosee/venera)](https://github.com/kyosee/venera/releases)

**[中文](README.md) | English**

A cross-platform manga/comic reader.

> **Original Project:** This project is forked from [venera-app/venera](https://github.com/venera-app/venera).

> **Disclaimer:** The software in this repository is provided "AS IS", without warranty of any kind, express or implied. The maintainers do not guarantee its accuracy, completeness, or fitness for any particular purpose; use it at your own risk.
>
> This project is for personal learning and research only, and its feature development and maintenance are AI-driven. This repository does **not** contain, provide, host, or distribute any content. For any third-party content that users access, obtain, or process through or by modifying this software, the project makes no guarantee as to its legality, accuracy, or completeness and assumes no liability for it. Users are solely responsible for their own use and must comply with all applicable laws and regulations in their jurisdiction.
>
> You must not use this project for any illegal activity, to distribute malware or viruses, or to interfere with the normal operation or lawful rights and interests of any company or individual. This is a non-profit, open-source project; using it for profit is prohibited, and any third-party profiteering is unrelated to this project.
>
> Do not promote or advertise this project on any public or official platforms or official account areas (including but not limited to Weibo, WeChat Official Accounts, X, etc.).
>
> By downloading, copying, modifying, or using this project, you are deemed to have read and accepted this disclaimer. The maintainers reserve the right to modify or supplement this disclaimer at any time.

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

## Quick Start

### Native App

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build linux      # Linux
flutter build macos      # macOS
```

## Build from Source

1. Clone the repository
2. Install [Flutter](https://flutter.dev/docs/get-started/install)

## Migration

If migrating from [venera-app/venera](https://github.com/venera-app/venera), use a separate WebDAV sync directory. Back up your old data before migrating.

## Star History

<a href="https://www.star-history.com/?type=date&repos=Kyosee%2Fvenera">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Kyosee/venera&type=date&theme=dark&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Kyosee/venera&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
    <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Kyosee/venera&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
  </picture>
</a>

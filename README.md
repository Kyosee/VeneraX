# Venera

[![Flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/kyosee/venera)](https://github.com/kyosee/venera/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/kyosee/venera?style=flat)](https://github.com/kyosee/venera/stargazers)
[![Release](https://img.shields.io/github/v/release/kyosee/venera)](https://github.com/kyosee/venera/releases)

**[中文](README_CN.md) | English**

A cross-platform manga/comic reader with self-hosted Web frontend support.

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

## Warning

**Do NOT deploy the Web frontend on the public internet.** It is designed for personal use on a trusted LAN only. Exposing it publicly may lead to attacks, traffic abuse, and data leaks (cookies, WebDAV config, personal data). All legal and security risks are your own.

## Features

- [x] Self-hosted Web frontend with Docker support (experimental)
- [x] Improved WebDAV backup & sync
- [x] Windows auto-updater (with fallback scripts) & Android APK auto-update
- [x] Seamless continuous-chapter reading
- [x] Improved local library, follow-updates & favorites
- [x] Task system with background execution and related views
- [x] Chapter read-status changes
- [x] Reading background color (per-comic)
- [x] Night-view mode (warm/black/dim-red overlay, adjustable intensity)
- [x] Android background downloads, follow-update checks, comic import/export
- [x] Windows tray minimize
- [x] Simple image-quality enhancement
- [x] Various UI refinements
- [x] Read-later

## Quick Start

### Native App

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build linux      # Linux
flutter build macos      # macOS
```

### Web PWA

Vue 3 PWA powered by a Node.js server + Rust image proxy sidecar. Primarily for iOS users who cannot sideload native apps — host on a local server and access via Safari.

> **Experimental:** The Web PWA is still under active development. Expect bugs and incomplete features — many native-app capabilities are not yet fully ported. Use it for personal testing only.

**Docker (Recommended)**

```bash
cd web
docker compose up -d --build
# http://localhost:60098
```

**Manual**

Requires Node.js 20+ and Rust.

```bash
cd web/client && npm ci && npm run build   # build frontend
cd ../server && npm install --omit=dev      # install deps
VENERA_STATIC_DIR=../client/dist node server.js
# http://localhost:8080
```

**Development**

```bash
# Terminal 1: server (port 3000)
cd web/server
VENERA_STATIC_DIR=../client/dist node server.js

# Terminal 2: Vite hot-reload (port 5173)
cd web/client
npm ci && npm run dev
```

## Build from Source

1. Clone the repository
2. Install [Flutter](https://flutter.dev/docs/get-started/install) (for native app)
3. Install [Rust](https://rustup.rs/) (for server sidecar)
4. Node.js 20+ (for Web frontend & server runtime)

## Migration

If migrating from [venera-app/venera](https://github.com/venera-app/venera), use a separate WebDAV sync directory. Back up your old data before migrating.

# Venera

[![Flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)](https://claude.ai)
[![License](https://img.shields.io/github/license/kyosee/venera)](https://github.com/kyosee/venera/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/kyosee/venera?style=flat)](https://github.com/kyosee/venera/stargazers)
[![Release](https://img.shields.io/github/v/release/kyosee/venera)](https://github.com/kyosee/venera/releases)

**[中文](README_CN.md) | English**

A cross-platform manga/comic reader with self-hosted Web frontend support.

> **Disclaimer:** This repository is for personal learning and use only. Feature development and maintenance are AI-driven.

## Warning

**Do NOT deploy the Web frontend on the public internet.** It is designed for personal use on a trusted LAN only. Exposing it publicly may lead to attacks, traffic abuse, and data leaks (cookies, WebDAV config, personal data). All legal and security risks are your own.

## Features

- Multi-platform: Windows, Linux, macOS, Android, iOS
- JavaScript-based comic source plugins (QuickJS on native, Node.js on server)
- Self-hosted Web frontend with Docker support
- WebDAV backup & sync
- Windows auto-updater

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

## Documentation

| Document | Link |
|----------|------|
| Local Comic Import | [doc/import_comic.md](doc/import_comic.md) |
| Headless Mode | [doc/headless_doc.md](doc/headless_doc.md) |

## Acknowledgments

- [EhTagTranslation](https://github.com/EhTagTranslation/Database) — Chinese tag translations

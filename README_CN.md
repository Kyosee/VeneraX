# Venera

[![Flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/kyosee/venera)](https://github.com/kyosee/venera/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/kyosee/venera?style=flat)](https://github.com/kyosee/venera/stargazers)
[![Release](https://img.shields.io/github/v/release/kyosee/venera)](https://github.com/kyosee/venera/releases)

**中文 | [English](README.md)**

跨平台漫画阅读器，支持自托管 Web 前端。

> **原始项目：** 本项目 fork 自 [venera-app/venera](https://github.com/venera-app/venera)，感谢原作者的优秀工作。

> **声明：** 此仓库仅用于个人学习。功能开发和维护由 AI 驱动。

## 警告

**禁止将 Web 前端部署在公网！** 仅适用于可信内网环境下的个人自用。暴露到公网可能导致攻击、流量滥用及数据泄露（Cookie、WebDAV 配置、个人数据）。由此产生的法律和安全风险自行承担。

## 功能

- 多平台：Windows、Linux、macOS、Android、iOS
- 基于 JavaScript 的漫画源插件（原生端 QuickJS，服务端 Node.js）
- 自托管 Web 前端，支持 Docker 部署
- WebDAV 备份与同步
- Windows 自动更新（含回退脚本）
- Android APK 自动更新
- 可配置 GitHub 更新源（支持私有仓库）

## 快速开始

### 原生应用

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build linux      # Linux
flutter build macos      # macOS
```

### Web PWA端

Vue 3 PWA，由 Node.js 服务端 + Rust 图片代理侧车驱动。主要用于 iOS 用户（无法侧载原生应用），部署在本地服务器后通过 Safari 访问。

**Docker（推荐）**

```bash
cd web
docker compose up -d --build
# 访问 http://localhost:60098
```

**手动部署**

需要 Node.js 20+ 和 Rust。

```bash
cd web/client && npm ci && npm run build   # 构建前端
cd ../server && npm install --omit=dev      # 安装依赖
VENERA_STATIC_DIR=../client/dist node server.js
# 访问 http://localhost:8080
```

**开发模式**

```bash
# 终端1: 启动服务端（端口 3000）
cd web/server
VENERA_STATIC_DIR=../client/dist node server.js

# 终端2: 启动 Vite 热更新（端口 5173）
cd web/client
npm ci && npm run dev
```

## 从源码构建

1. 克隆仓库
2. 安装 [Flutter](https://flutter.dev/docs/get-started/install)
3. 安装 [Rust](https://rustup.rs/)（服务端需要）
4. Web 前端需要 Node.js 20+、Rust 和 Docker

## 迁移提示

从 [venera-app/venera](https://github.com/venera-app/venera) 迁移时，请为 WebDAV 同步指定独立目录，不要与原项目共用。迁移前建议备份旧数据。

## 文档

| 文档 | 链接 |
|------|------|
| 本地漫画导入 | [doc/import_comic.md](doc/import_comic.md) |
| Headless 模式 | [doc/headless_doc.md](doc/headless_doc.md) |

## 致谢

- [EhTagTranslation](https://github.com/EhTagTranslation/Database) — 漫画标签中文翻译

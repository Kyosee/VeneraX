# Venera

[![Flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/kyosee/venera)](https://github.com/kyosee/venera/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/kyosee/venera?style=flat)](https://github.com/kyosee/venera/stargazers)
[![Release](https://img.shields.io/github/v/release/kyosee/venera)](https://github.com/kyosee/venera/releases)

**中文 | [English](README.md)**

跨平台漫画阅读器，支持自托管 Web 前端。

> **原始项目：** 本项目 fork 自 [venera-app/venera](https://github.com/venera-app/venera)。

> **声明：** 本项目的软件代码以"原样"提供，不附带任何明示或暗示的担保；本项目维护者不保证其准确性、完整性或适用于任何特定用途，使用风险由使用者自行承担。
>
> 本项目仅用于个人学习与研究，功能开发和维护由 AI 驱动。本项目**不**包含、不提供、不托管、也不分发任何内容；对于使用者通过或改造本软件访问、获取或处理的任何第三方内容，本项目不保证其合法性、准确性或完整性，亦不对其承担任何责任。使用者须自行判断、对自身使用行为负责，并遵守所在司法管辖区的全部适用法律法规。
>
> 使用者不得利用本项目从事任何非法活动、传播恶意软件或病毒，或干扰任何公司或个人的正常运营及合法权益。本项目为非营利开源项目，禁止用于牟利，任何第三方的盈利行为均与本项目无关。
>
> 禁止在各类公开/官方平台及官方账号区域（包括但不限于微博、微信公众号、X 等）宣传或推广本项目
>
> 一旦下载、复制、修改或使用本项目，即视为已阅读并接受本声明。本项目维护者保留随时修改或补充本声明的权利。

## 警告

**禁止将 Web 前端部署在公网！** 仅适用于可信内网环境下的个人自用。暴露到公网可能导致攻击、流量滥用及数据泄露（Cookie、WebDAV 配置、个人数据）。由此产生的法律和安全风险自行承担。

## 功能

- [x] 自托管 Web 前端，支持 Docker 部署（实验性）
- [x] WebDAV 备份与同步优化
- [x] Windows 自动更新（含回退脚本）与 Android APK 自动更新
- [x] 连续章节无缝阅读
- [x] 本地、追更、收藏优化
- [x] 新增任务功能，支持后台执行任务及相关视图界面
- [x] 章节阅读状态变更
- [x] 夜览模式
- [x] 支持 Android 端后台下载、追更检查、导入/导出漫画
- [x] 支持 Windows 端托盘最小化
- [x] 简易画质增强功能
- [x] 部分 UI 调整优化
- [x] 稍后阅读功能

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

> **实验性：** Web PWA 仍在积极开发中，可能存在诸多 bug 和未完成功能——大量原生端能力尚未完全移植。建议仅用于个人测试。

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

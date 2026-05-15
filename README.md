# Venera - 漫画阅读器 / Manga & Comic Reader

[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/kyosee/venera)](https://github.com/kyosee/venera/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/kyosee/venera?style=flat)](https://github.com/kyosee/venera/stargazers)
[![Download](https://img.shields.io/github/v/release/kyosee/venera)](https://github.com/kyosee/venera/releases)

Venera 是一款基于 Flutter 的漫画阅读器，支持本地和网络阅读场景。

This is a personally maintained Venera fork for manga and comic reading. It keeps the original app base and adds a self-hosted Web/PWA deployment path, WebDAV backup import/sync improvements, continuous reading, progress tracking, and Windows self-updating builds.

> 这是一个仅个人使用维护的版本，后续可能会出现比较大的改动，使用前请先确认是否适合你的场景。

## README 说明

| 项目 | 说明 |
|------|------|
| 功能概览 | “当前核心功能”描述的是当前版本具备的能力，不代表这些能力都是最近加入的 |
| 差异基准 | “相比原版 v1.6.3 的主要变化”以 `venera-app/venera` 的 `v1.6.3` tag 为基准 |
| 内容范围 | 变化说明只保留通用功能、部署、同步、阅读体验、平台构建与维护性内容 |

## 当前核心功能

| 功能 | 说明 |
|------|------|
| 本地阅读 | 支持目录导入，以及 `.cbz`、`.cb7`、`.zip`、`.7z` 等漫画归档格式 |
| 网络阅读 | 支持搜索、分类浏览、详情读取、登录态页面交互和在线阅读 |
| 收藏与下载 | 支持漫画收藏、下载、历史记录、追更和本地书库管理 |
| 数据同步 | 支持 WebDAV 数据同步；从原项目迁移时请使用独立同步目录 |
| 多平台 | 支持 Android、iOS、Windows、macOS、Linux，并提供 Web/PWA 自托管形态 |
| Headless | 支持无界面模式，适合自动化和服务端场景 |

## 相比原版 v1.6.3 的主要变化

| 模块 | 功能或优化 |
|------|------------|
| Web/PWA 自托管 | 提供 Flutter Web 入口、PWA 静态资源、同源 Node `web_helper`、Rust `venera-fetch` sidecar 和 Docker Compose 部署方式，可在 NAS、服务器或本机 Docker 环境运行 |
| Web 数据持久化 | Web 端增加 IndexedDB/localStorage 与 helper 服务端数据库协作，支持历史、收藏、WebDAV 配置和备份数据在自托管环境中持久保存 |
| WebDAV 同步 | 增强 Web 端备份导入、上传、远端清理和同步安全性，并放宽 helper 上传体积限制，降低大备份同步失败概率 |
| 登录与网络兼容 | 增加 helper browser 登录辅助、Cookie jar 持久化/同步、Cloudflare 验证回退和同源代理流程，改善 Web/PWA 场景下的登录态与请求稳定性 |
| 阅读体验 | 增加轻量 Web 阅读器、阅读模式适配、无缝连续章节阅读、漫画卡片章节进度显示，并修复多处阅读手势与设置布局问题 |
| 收藏、历史与追更 | 增强本地书库历史/收藏、收藏夹增删改、追更任务、追更文件夹选择、历史排序和任务时间显示 |
| UI 与交互稳定性 | Web/PWA 引入 Material 3 风格基础组件、响应式导航、首页/搜索/详情/设置页面体验对齐，并优化动画、弹窗、筛选和异步生命周期处理 |
| Windows 与构建 | 增加 Windows 自更新工具，完善 x64/arm64 打包流程，构建脚本改为失败即停并自动恢复安装脚本，同时移除不再维护的 AltStore/Fastlane 发布配置 |
| 维护与测试 | 拆分多处 Native/Web 平台实现，补充状态仓库、Web 数据导入、数据库、Cookie 和 helper 适配相关测试，提升跨平台维护性 |

## Web PWA 自托管

本仓库提供 Web/PWA 版本，适合在 NAS、服务器或本机 Docker 环境中运行。Web/PWA 使用 Flutter Web 静态前端，同源 `web_helper` 负责代理、Cookie、WebDAV、登录辅助和图片请求，容器内 `venera-fetch` sidecar 处理更稳定的后端网络请求。

```bash
flutter build web --target lib/main_web.dart --release --base-href / --no-wasm-dry-run --no-tree-shake-icons
docker compose -f docker-compose.webpwa.yml up -d --build
```

| 项目 | 默认值 |
|------|--------|
| 访问地址 | `http://localhost:60098` |
| 浏览器数据 | IndexedDB/localStorage |
| Docker 浏览器数据卷 | `webpwa-browser-data` |
| Docker 服务端数据卷 | `webpwa-server-data` |

## 从原项目迁移

如果你是从 [venera-app/venera](https://github.com/venera-app/venera) 迁移过来的，请给 WebDAV 同步重新指定一个独立目录，不要继续和原项目共用同一目录，以免造成数据混乱。

迁移前建议先备份旧的同步目录和本地数据，确认无误后再切换。

## Build from source

1. Clone the repository
2. Install Flutter: [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install Rust: [rustup.rs](https://rustup.rs/)
4. For Web/PWA, install Node.js 20+ and Docker Desktop, then build Flutter Web before starting compose.
5. Build for your platform, for example:

```bash
flutter build apk
```

## 文档

| 文档 | 链接 |
|------|------|
| 本地漫画导入 | [doc/import_comic.md](doc/import_comic.md) |
| Headless Mode | [doc/headless_doc.md](doc/headless_doc.md) |

## Keywords

Flutter comic reader, manga reader, Venera fork, self-hosted manga PWA, WebDAV sync, CBZ reader, ZIP comic reader, Windows comic reader, Android comic reader.

## Thanks

### Tags Translation

[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

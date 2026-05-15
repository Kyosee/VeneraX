# Venera - 漫画阅读器 / Manga & Comic Reader

[![flutter](https://img.shields.io/badge/flutter-3.41.4-blue)](https://flutter.dev/)
[![License](https://img.shields.io/github/license/kyosee/venera)](https://github.com/kyosee/venera/blob/master/LICENSE)
[![stars](https://img.shields.io/github/stars/kyosee/venera?style=flat)](https://github.com/kyosee/venera/stargazers)
[![Download](https://img.shields.io/github/v/release/kyosee/venera)](https://github.com/kyosee/venera/releases)

Venera 是一款基于 Flutter 的漫画阅读器，支持本地阅读、网络阅读、收藏、下载、历史记录、追更、WebDAV 同步和 Headless 模式。

这是个人维护版本。下面只列当前分支相对原版 `v1.6.3` 的主要变化，基础阅读能力不重复展开。

## 相比原版 v1.6.3

| 类型 | 变化 |
|------|------|
| 新增 | Web/PWA 自托管：可在 NAS、服务器或本机 Docker 跑网页端，内置代理、登录辅助、WebDAV 和数据持久化 |
| 新增 | Windows 自更新：打包产物包含 `venera_updater.exe` |
| 改进 | 阅读体验：无缝连续章节、卡片章节进度、手势和设置布局修复 |
| 改进 | 收藏/历史/追更：收藏夹管理、本地书库状态、追更任务、历史排序和任务时间显示更完整 |
| 改进 | 同步和登录：WebDAV 备份导入/上传/清理更稳，Cookie 同步和 Cloudflare 验证回退更可靠 |
| 改进 | 构建维护：完善 Windows x64/arm64 打包，拆分 Native/Web 实现，补充 Web 数据和 helper 测试 |

## Web/PWA 快速启动

```bash
flutter build web --target lib/main_web.dart --release --base-href / --no-wasm-dry-run --no-tree-shake-icons
docker compose -f docker-compose.webpwa.yml up -d --build
```

| 项目 | 默认值 |
|------|--------|
| 访问地址 | `http://localhost:60098` |

## 迁移提示

如果你是从 [venera-app/venera](https://github.com/venera-app/venera) 迁移过来的，请给 WebDAV 同步重新指定一个独立目录，不要继续和原项目共用同一目录。迁移前建议先备份旧同步目录和本地数据。

## Build from source

1. Clone the repository
2. Install Flutter: [flutter.dev](https://flutter.dev/docs/get-started/install)
3. Install Rust: [rustup.rs](https://rustup.rs/)
4. For Web/PWA, install Node.js 20+ and Docker Desktop
5. Build for your platform, for example:

```bash
flutter build apk
```

## 文档

| 文档 | 链接 |
|------|------|
| 本地漫画导入 | [doc/import_comic.md](doc/import_comic.md) |
| Headless Mode | [doc/headless_doc.md](doc/headless_doc.md) |

## Thanks

### Tags Translation

[EhTagTranslation](https://github.com/EhTagTranslation/Database)

The Chinese translation of the manga tags is from this project.

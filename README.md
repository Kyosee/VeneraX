<div align="center">
  <img src="assets/new_logo.png" width="180" alt="VeneraX" />
  <h1>VeneraX</h1>

[![Flutter](https://img.shields.io/badge/flutter-3.44.3-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/Kyosee/VeneraX?style=flat)](https://github.com/Kyosee/VeneraX/stargazers)
[![Release](https://img.shields.io/github/v/release/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/releases)

  <p>中文 | <a href="README_EN.md">English</a></p>
</div>

VeneraX 是一款免费开源的多平台漫画阅读应用，基于 Venera 持续维护与增强。

**[下载](#下载与安装) · [功能](#新功能优化) · [使用说明](doc/guide.zh.md) · [更新日志](CHANGELOG.md) · [反馈](#反馈与贡献)**

> **原始项目：** 本项目 fork 自 [venera-app/venera](https://github.com/venera-app/venera)。

> [!IMPORTANT]
> **使用前请阅读[《VeneraX 用户协议与免责声明》](#venerax-用户协议与免责声明)**，了解软件功能、第三方服务风险及数据处理情况。本说明不增加 GNU GPLv3 之外的许可限制；依法需要另行取得的数据处理同意仍须单独办理。

## 下载与安装

**[下载最新版本](https://github.com/Kyosee/VeneraX/releases/latest)** · [全部版本](https://github.com/Kyosee/VeneraX/releases)

请按系统和处理器架构选择安装包，并查看对应版本的安装说明。

<details>
<summary><b>Linux AppImage 安装说明</b></summary>

在 [Releases](https://github.com/Kyosee/VeneraX/releases) 下载 `VeneraX-<版本>-x86_64.AppImage`（Intel / AMD 64 位）或 `VeneraX-<版本>-aarch64.AppImage`（ARM64）。赋予执行权限后直接运行，无需安装 deb 包：

```bash
chmod +x VeneraX-<版本>-x86_64.AppImage
./VeneraX-<版本>-x86_64.AppImage
```

请替换示例中的版本号和架构。AppImage 包含 GTK、WebKitGTK、ONNX Runtime 及托盘运行库，基于 Ubuntu 22.04 构建；需要 glibc 2.35 或更新版本、桌面图形驱动及 X11／XWayland，不支持旧版 glibc 或 Alpine 等 musl 系统。系统缺少 FUSE 时可解包运行：

```bash
./VeneraX-<版本>-x86_64.AppImage --appimage-extract
./squashfs-root/AppRun
```

更新时下载新版 AppImage 并替换旧文件；应用数据仍保存在原有用户数据目录。

</details>

## 新功能&优化

<details open>
<summary><b>查看完整功能列表</b></summary>

### 阅读体验

- [x] 连续章节无缝阅读
- [x] 章节阅读状态变更
- [x] 自定义章节顺序：可按名称、倒序或目录修改时间批量排序，可隐藏重复章节，设置随同步
- [x] 自动翻页新增匀速滚动模式，可设置阅读时屏幕常亮
- [x] 夜览模式
- [x] 阅读背景色（可按漫画设置）
- [x] 墨水屏适配（实验性）：翻页时全屏刷新清残影，掌阅设备支持系统水波纹翻页

### 漫画管理

- [x] 本地、追更、收藏优化；追更可同时追多个收藏夹，可设检查间隔、启动时检查与每日定时检查
- [x] 稍后阅读功能
- [x] 支持多库管理
- [x] 自定义合集：把分卷、分部发布的多本漫画合成一本阅读，可跨来源
- [x] 阅读统计：记录阅读时长，支持排序与滑动删除
- [x] 抽一本：从收藏中随机抽取一本，可选抽取范围
- [x] 导入本地 PDF 漫画
- [x] 自定义漫画缓存目录
- [x] 支持自定义自动清理历史记录

### 同步与隐私

- [x] WebDAV 备份与同步优化，可逐项选择不参与同步的设置
- [x] 支持多设备通过扫码方式快速同步webdav配置信息
- [x] WebDAV 漫画库（实验性）
- [x] 应用锁新增 PIN 码、密码、手势解锁

### 翻译与画质

- [x] 阅读时 AI 翻译（实验性）：图片与 OCR 均在本机处理，仅将识别文字发送到用户自行配置的 LLM；服务商支持新手模板/模型拉取与高级自定义，提供省资源、均衡、快速档位，支持整章预翻译、智能消字与受限区域嵌字；支持繁体中文（含竖排）、自定义目标语言与自定义翻译接口脚本，主页可查看已翻译漫画
- [x] 简易画质增强功能，支持原图与增强效果实时对比预览

### 平台与交互

- [x] 新增任务功能，支持后台执行任务及相关视图界面
- [x] 支持 Android 端后台下载、追更检查、导入/导出漫画
- [x] 支持 Windows 端托盘最小化
- [x] 桌面端自定义快捷键：全屏、翻页、切换章节、阅读菜单等均可自由设置；Windows 可用全局快捷键隐藏到托盘或唤回窗口
- [x] Windows 与 Android APK 自动检查更新
- [x] 支持主界面长按自定义功能区排序
- [x] 部分 UI 及使用体验调整优化

</details>

## 使用说明

各功能的配置步骤与操作方式详见 **[使用说明](doc/guide.zh.md)**。应用内亦可查阅：设置 → 关于 → 使用说明。

### 首次启动与升级提示

当前开发版本仅在新安装且本机没有应用数据时展示一次引导：先阅读可切换语言的协议，再设置界面语言、查看基础权限说明，最后选择导入备份或配置 WebDAV；可选设置可跳过。已有数据的用户升级后仅显示一次本版协议更新提示，不重新进入新用户引导。

系统权限、WebDAV、翻译及其他依法需要单独同意的数据处理分别选择或授权，确认协议不替代这些授权。该流程属于当前开发变更，正式版本是否包含以发布说明为准。

### 更新日志

各版本的新增、变更与修复详见 **[更新日志](CHANGELOG.md)**，每次正式版发布后自动更新。应用内检查到新版本时，更新弹窗也会显示本次的更新内容。

### 迁移提示

从 [venera-app/venera](https://github.com/venera-app/venera) 迁移时，请为 WebDAV 同步指定独立目录，不要与原项目共用。迁移前建议备份旧数据。

## 反馈与贡献

应用问题与功能建议请提交至 [Issues](https://github.com/Kyosee/VeneraX/issues)。报告问题时，请附上应用版本、系统与设备信息，以及复现步骤。

代码改进可通过 [Pull requests](https://github.com/Kyosee/VeneraX/pulls) 提交。

## 构建

<details>
<summary><b>本地构建</b></summary>

1. 安装 [Flutter](https://flutter.dev/docs/get-started/install)
2. 克隆仓库，执行 `flutter pub get`
3. 按平台构建：

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build linux      # Linux
flutter build macos      # macOS
```

Android 需要先准备签名密钥，见下一节的「Android 签名」。

Linux AppImage 在对应架构的 Ubuntu 22.04 上构建。除 Flutter Linux 编译依赖外，需安装 `webkit2gtk-4.1 libayatana-appindicator3-dev librsvg2-dev libglib2.0-bin glib-networking`。执行 `flutter build linux --release` 后运行 `python3 linux/appimage/build.py x64`（ARM64 用 `arm64`），产物位于 `build/linux/<架构>/release/appimage/`。打包脚本会下载 linuxdeploy 和 GTK 插件，需要联网。

</details>

<details>
<summary><b>在自己的 GitHub 上构建</b></summary>

fork 本仓库后可以直接用 GitHub Actions 出安装包，不必配置本地环境。

**1. 启用 Actions**

fork 出来的仓库默认停用工作流，进 Actions 页点一下按钮启用。

**2. 构建单个平台**

Actions → **Build ALL** → Run workflow → 在 platform 里选 `windows` / `linux` / `macos` / `ios` / `android`，跑完在这次 run 的 Artifacts 里下载。

Linux 同时生成 deb、Arch 包及 AppImage；AppImage 分别在 `appimage_build`（x86_64）和 `appimage_arm64_build`（ARM64）中，版本标签构建会自动附加到 Release。

CI 还会在未安装 GTK／WebKit 的 Ubuntu 22.04 容器中启动两个 AppImage，通过真实网页登录验证页面脚本及原生回调；截图和日志保存在 `appimage_smoke_x64`、`appimage_smoke_arm64`。仅重测已有安装包时，选择 `linux`，在 `appimage_run_id` 填入原构建运行 ID；留空则正常构建并验证。

Windows、Linux、macOS、iOS 不需要任何配置就能构建，但产物没有签名：

- iOS 是未签名 ipa，需要自行签名后侧载。
- macOS 是未签名、未公证的 dmg，首次打开要右键 → 打开。

**3. Android 签名**

Android 必须自己准备签名密钥，否则构建会直接失败。生成密钥：

```bash
keytool -genkey -v -keystore venera.jks -keyalg RSA -keysize 2048 -validity 10000 -alias venera
base64 -w0 venera.jks    # macOS 用 base64 -i venera.jks
```

在仓库 Settings → Secrets and variables → Actions 添加 4 个 secret：

| 名称 | 内容 |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | 上一步 base64 的输出 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 别名，上例为 `venera` |
| `ANDROID_KEY_PASSWORD` | key 密码 |

本地构建则把同样的信息写进 `android/key.properties`（该文件不会被提交）：

```properties
storeFile=/绝对路径/venera.jks
storePassword=你的 keystore 密码
keyAlias=venera
keyPassword=你的 key 密码
```

**注意：** 自己签名的 APK 与本仓库发布版签名不同，无法覆盖安装，需要先卸载。卸载会清除应用数据，请先在应用内导出备份。

**4. 改掉检查更新指向的仓库**

如果要把构建产物分发出去，必须先改 [`lib/pages/settings/about.dart`](lib/pages/settings/about.dart) 开头的两个常量：

```dart
const kUpdateRepoOwner = 'Kyosee';
const kUpdateRepoName = 'VeneraX';
```

改成自己的用户名和仓库名。检查更新、下载更新包、更新日志、关于页的仓库链接都由这两个常量决定。

不改会有两个后果：应用启动时（「启动时检查更新」默认开启）会去查本仓库的最新版本，自己发的版本永远不会被检测到；Windows 上用户点「立即更新」会直接把本仓库的产物覆盖安装上去，等于把自己的版本换成了本仓库的版本。

**5. 打 tag 自动发布（可选）**

推送 `v*` tag 会触发全平台构建并创建 Release，fork 后需要先处理三处：

- `release-notes/<tag>.en.md` 和 `release-notes/<tag>.zh-CN.md` 必须存在且非空。
- tag 必须等于 `v` 加 `pubspec.yaml` 里的版本号（不含 `+` 之后的部分）。
- Android 构建里的 `Verify Android signature continuity` 会比对上一个 Release 的 APK 签名。fork 仓库没有历史 Release，这一步必然失败，而 Release 依赖全部平台构建成功，一个失败就不会产出任何文件——首次发布前请删掉这一步。

另外，两个 `Update_AltStore_*` 任务会把 AltStore 清单自动提交回 master，不需要可以删除；私有仓库可能拿不到 `ubuntu-22.04-arm` runner 而一直排队，可删除 `Build_Linux_ARM64`。

</details>

## VeneraX 用户协议与免责声明

协议版本：1 · 更新日期：2026-11-10

<details open>
<summary><b>展开完整协议</b></summary>

**阅读前的重要说明**

本说明所称“本软件”，指 VeneraX；“本项目”，指发布本软件的开源项目；“维护者”，指实际承担本项目相应版本维护或发布工作的个人或组织；“用户”，指安装或使用本软件的个人或组织。贡献者不因提交代码、文档或其他贡献而当然对整个项目、其他主体的行为或第三方服务承担责任。

本说明用于告知软件功能、第三方服务风险及相关数据处理情况，不替代适用法律或仓库 LICENSE 文件中的 GNU GPLv3。用户依法及依许可证享有的运行、复制、修改和分发权利，不因本说明受到额外限制。对本说明的确认不替代依法需要另行取得的个人信息处理同意，亦不排除或限制法律规定不得排除或限制的权利与责任。

**一、软件性质与项目定位**

1. 本软件是一款运行于用户本地设备、可由用户自行配置的内容阅读工具，提供网络访问、内容解析、阅读排版与本地数据管理等技术功能。在适用法律允许的范围内，软件按现状提供；质量担保和责任限制依本说明第六节、GNU GPLv3 及适用法律处理。
2. 本项目发布的软件默认不预置第三方漫画内容、漫画源扩展、来源库地址或内容源清单。维护者不通过本软件运营、托管或向公众分发第三方漫画内容；软件与第三方资源的技术兼容，不表示本项目对该资源作推荐、认证或背书。可选翻译、更新检查及模型下载等第三方服务，另见第四节。
3. 本项目目前以非营利方式维护，开发与维护过程中使用 AI 辅助工具。维护者未授权任何第三方以本项目官方身份开展收费分发、售卖、代装、引流或收费社群等活动；不得虚构项目授权或背书。上述项目定位不限制 GNU GPLv3 允许的合法用途及有偿分发。维护者可根据实际条件调整、暂停或停止后续开发、维护与发布，不承诺持续更新或固定支持期限；本说明第六节所列法律及有效书面承诺的例外仍适用。

**二、扩展与用户行为**

1. 本软件的网络阅读能力通过兼容 JavaScript 扩展 API 实现。用户可自行创建、编辑或导入第三方扩展脚本，并自行决定是否加载及使用哪些扩展。用户应核实扩展来源、功能及适用性，并对自身配置、授权和使用行为负责；不受信任的脚本可能发起非预期网络请求或访问相关数据。本项目不对用户自行导入的第三方扩展提供安全性、合法性、准确性或持续可用性的担保；责任限制及其例外见第六节。
2. 用户通过扩展访问第三方网站时，相关网络请求由用户设备按照扩展及网络配置向目标服务发起。本软件提供本地解析、排版和展示能力，本项目不因此托管、公开传播或再分发第三方内容。搜索结果、章节加载和图片可用性取决于相应服务及扩展实现；第三方服务的访问条件和可用性由其提供方管理，内容权利及授权范围以实际权利人的合法授权为准。第三方网站或扩展的声明不当然证明其拥有相关权利。
3. 用户应遵守所在司法管辖区的法律法规、网络安全要求及相关网站的服务协议与版权规范，不得利用本软件从事侵犯知识产权、未经授权获取数据、传播非法内容或恶意软件、干扰或破坏网络服务等违法违规行为，亦不得损害任何公司或个人的合法权益。

**三、第三方平台与社区**

1. 独立第三方建立或维护的扩展分享平台、网站、论坛或交流群组，由相应第三方运营；本项目不参与其制作、发布、运营或维护。技术兼容或名称引用不当然形成代理、合作、隶属或背书关系。本项目不提供针对上述平台、扩展及服务的内容审核、认证或质量保证服务；其内容、运营安排和服务承诺由相应提供方管理，不因用户通过本软件访问而转由维护者承担。
2. 本项目目前未设立或运营官方用户社群、交流群组。项目身份和发布信息以项目公开列明的仓库及发布渠道为准；第三方建立的社群、账号或收费服务不因使用项目名称而获得授权。未经实际授权，不得以本项目官方身份进行宣传、推广或发布，也不得声称获得维护者认可。

**四、隐私、权限与数据**

1. 本软件作为客户端运行于用户设备，本地阅读与管理数据保存在设备上；联网功能会按其用途向相应目标服务发起请求。本项目不运营用于收集用户阅读数据的内容或同步服务器，不自动向维护者上传阅读内容、已安装漫画源列表或浏览历史，亦不集成统计、崩溃分析或遥测组件。用户主动提交的 issue、日志或其他反馈，由相应平台及实际接收方依适用法律和各自规则处理；提交前应移除密码、令牌和不必要的私人信息。本节描述本项目发布版本的行为，不替第三方修改版本或用户导入的脚本作数据处理保证。
2. 本软件自身的网络与文件访问用于在线阅读、备份导入导出、WebDAV 同步、更新检查、翻译及模型下载等相关功能。在线内容请求发送至所配置的漫画源或目标服务，更新与模型下载访问相应发布或下载服务。接收方可能获得建立连接所需的 IP 地址、请求内容及该服务所需的账号凭据或 Cookie；请求路径还受系统网络及代理配置影响。WebDAV 将所选数据传输至用户配置的服务器，维护者不因提供该功能而获得该服务器的管理权限或数据访问权。第三方扩展或脚本的其他访问行为应另行核实。
3. 翻译为可选功能，初始配置不自动启用。用户可自行选择翻译服务或自定义脚本，并决定是否启用。启用后，识别文本发送至所选翻译服务；模型翻译还可能发送提示词及所需上下文，自定义脚本的数据去向和范围取决于其实现。这些请求由用户设备按所选服务及网络配置发起，本项目不提供翻译请求中转服务。用户应核对接收方、发送内容、计费及数据处理规则，并可停止后续使用。停止使用本身不会自动删除已发送至第三方的数据，删除等权利应依适用法律及相应服务的处理机制行使。
4. 通知用于下载完成和后台任务等提醒，是否可用及授权方式因操作系统而异；文件访问按导入、导出及本地内容操作需要进行。用户可拒绝可选权限，相关功能可能受限，与该权限无关的基础功能不受影响。WebDAV 同步和翻译由用户分别配置与启用，对本说明的阅读确认不替代系统授权或具体功能选择。涉及依法须另行告知、取得同意或履行其他数据处理义务的，由相应处理主体依适用法律办理。
5. 导入、恢复或同步可能覆盖或改变本机及所选服务器上的数据，用户应核对目标位置、传输方向和界面说明，并保留必要备份。应用数据备份不等于下载图片备份；根据备份方式和所选范围，文件可能包含收藏、历史、漫画源、应用设置、Cookie、登录信息及服务配置，部分服务密钥可能以明文形式随配置保存或同步。漫画图片应通过相应导出或同步功能另行处理。用户应妥善保管备份和服务器凭据，避免公开分享含私人信息的文件。
6. 关闭同步或移除服务器配置，不会自动删除此前已经上传至第三方服务器的副本。用户需要删除远端数据时，应通过相应服务提供的管理方式操作。卸载软件或清理本地数据可能导致未备份内容丢失；用户应在操作前确认需要保留的数据已妥善备份。

**五、知识产权与问题反馈**

1. 本项目尊重知识产权。权利人认为本仓库直接包含的代码或文件侵犯其合法权益的，可通过项目公开列明的反馈渠道，提供相关文件位置、具体问题说明及合理必要的权利依据。通知的处理根据具体材料、本项目的实际控制范围及适用法律确定，不构成对权属的裁定或对特定处理结果的保证。涉及身份证明等敏感材料时，应先确认适当的非公开提交方式，避免直接发布于公开 issue 或评论。
2. 对于由独立第三方控制、且本项目未托管或管理的内容、扩展及服务，本项目不具有对其直接删除、修改或管理的权限。有关处置请求应向实际托管方、发布者或其他相应主体提出。维护者不因本软件具备访问、解析或展示能力，就当然承担第三方资源的内容、运营或服务责任；具体责任依据相关主体的实际行为及适用法律确定。
3. 第三方网站内容、账号问题、扩展配置及具体作品可用性不在本项目常规技术支持范围内；维护者不裁定第三方内容的版权归属。软件自身缺陷及涉及本仓库代码、文件的权利通知，可通过项目公开列明的渠道反馈。提供反馈渠道不构成对所有问题提供免费支持、保证解决或在固定期限内修复的承诺；第六节所列法律及有效书面承诺的例外仍适用。

**六、质量说明与责任限制**

1. 在适用法律允许的范围内，除相关责任主体另有有效书面承诺或约定外，本软件依 GNU GPLv3 第 15 节按现状提供，不附带明示或默示担保，包括适销性或特定用途适用性的担保。在 GNU GPLv3 第 16 节及适用法律允许的范围内，除法律要求或相关主体另有有效书面约定外，版权人及依据许可证修改或分发本软件的主体，不对用户因使用或无法使用本软件造成的损害承担赔偿责任，包括一般性、特殊性、附带性或后果性损失，以及数据丢失、数据失准或与其他软件无法协同运行造成的损失。本条及本说明其他责任限制，不排除或限制法律禁止排除或限制的责任及用户法定权利；适用中国法律时，包括造成对方人身损害的责任，以及因故意或者重大过失造成对方财产损失的责任。
2. 在前款责任限制及其例外范围内，维护者不保证软件始终准确、安全、完整、无缺陷，不保证不中断、不丢失数据或满足特定用途，亦不保证与第三方网站、扩展、模型或服务持续兼容。本项目不担保第三方服务的持续可用性、收费规则或履约情况。用户应结合自身需求评估使用风险，并按照相关功能说明保留必要备份。

**七、开源许可、修改版本与分发**

1. 本项目是 Venera 的修改版本，由本项目维护者独立开发与发布。派生关系不当然形成 VeneraX 与上游项目及其维护者之间的代理、合作或背书关系，也不使一方当然对另一方的修改、发布或运营行为承担责任。相同原则适用于基于 VeneraX 派生的版本；实际授权以适用许可证及其他有效授权为准。
2. 第三方基于本项目源码实施的修改、构建或分发行为，包括提供 fork、私有构建及自行签名安装包，不当然属于本项目的发布或维护行为。本项目维护者不提供对第三方版本的常规审核、技术支持或质量担保；第三方自行加入的修改、捆绑内容及其服务承诺，不因使用本项目源码而当然转由本项目维护者负责。相关责任限制及其例外依第六节处理。
3. 发布修改版本时，应依 GNU GPLv3 保留适用的版权、许可及无担保声明，提供显著的修改说明和相关日期，并履行相应源代码提供义务。对外标识和宣传不得使用户误认为该版本由本项目官方发布；未经实际授权，不得声称获得本项目认可或背书。名称及项目标识的使用应遵守适用法律和许可证允许的合法要求，本说明不据此增加超出许可证允许范围的分发限制。
4. 本仓库 Release 页面是本项目自行发布构建产物的渠道。官方默认安装包不预置漫画源扩展、来源库地址或内容源清单；附带这些配置的第三方修改构建，不因使用相同名称或图标而成为官方发布版本。通过其他渠道取得安装包时，应核对实际发布者及修改情况。原包转发不等于获得官方代理、合作或背书身份，也不产生额外质量保证；分发许可及责任限制分别依 GNU GPLv3 和本说明第六节处理。
5. 本软件依仓库根目录 LICENSE 文件所载 GNU GPLv3 授权。用户依法及依许可证享有的运行、复制、修改和分发权利，包括许可证允许的有偿分发，不因本说明受到额外限制。修改或分发软件时，应履行相应许可证义务并遵守适用法律；运行本软件不以接受新增用途限制或放弃法定权利为条件。

**八、项目介绍与说明变更**

1. 本项目以有限维护资源开展开发，不鼓励在公开平台大规模宣传、营销或引流，请避免在无关平台、评论区或社群发布推广信息。这一传播偏好不作为运行、复制、修改或分发软件的附加许可条件，不限制依法作出的真实介绍、合理评论或 GNU GPLv3 允许的分发。任何主体不得虚构项目授权、商业合作或维护者背书，不得冒充官方身份提供收费服务或误导用户。
2. 本说明不修改、不限制 GNU GPLv3 授予的权利。与许可证发生冲突时，以适用许可证为准；涉及不得由约定排除或限制的法定权利、责任及义务时，以适用法律的强制性规定为准。
3. 用户选择“同意并继续”，表示其已阅读并同意本说明中依法有效且适用的条款，并确认知悉其中的风险提示与责任限制。本确认不替代依法需要另行取得的个人信息处理同意，亦不排除或限制法律规定不得排除或限制的权利与责任。维护者可根据版本及实际情况修订本说明并公开更新内容；对于由维护者实际实施、依法需要另行告知或取得同意的数据处理变更，应依适用法律履行相应程序。单纯发布新版说明不使新增授权或附加限制自动对用户生效，也不追溯改变用户已依 GNU GPLv3 获得的权利；第三方服务、扩展或用户配置发生的变化，不由维护者保证预先通知。

</details>

## Star History

<a href="https://www.star-history.com/?type=date&repos=Kyosee%2FVeneraX">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&theme=dark&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
 </picture>
</a>

## 致谢

- [Venera](https://github.com/venera-app/venera)：VeneraX 的上游项目，感谢其开发者与贡献者。
- [EhTagTranslation](https://github.com/EhTagTranslation/Database)：漫画标签中文翻译数据。
- 感谢为 VeneraX 提交 Issue、参与测试及贡献代码的用户。

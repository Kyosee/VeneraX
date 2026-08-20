<div align="center">
  <img src="assets/new_logo.png" width="180" alt="VeneraX" />
  <h1>VeneraX</h1>

[![Flutter](https://img.shields.io/badge/flutter-3.44.3-blue)](https://flutter.dev/)
![AI-Driven](https://img.shields.io/badge/AI--Driven-Claude%20|%20Codex%20|%20DeepSeek-6e47ff)
[![License](https://img.shields.io/github/license/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/blob/master/LICENSE)
[![Stars](https://img.shields.io/github/stars/Kyosee/VeneraX?style=flat)](https://github.com/Kyosee/VeneraX/stargazers)
[![Release](https://img.shields.io/github/v/release/Kyosee/VeneraX)](https://github.com/Kyosee/VeneraX/releases)

  <h3>中文 | <a href="README_EN.md">English</a></h3>
</div>

VeneraX 是一个 Fork 自 Venera 并在原版基础上进行维护与增强，免费开源的多平台漫画阅读应用。

> **原始项目：** 本项目 fork 自 [venera-app/venera](https://github.com/venera-app/venera)。

> [!IMPORTANT]
> **在下载、安装或使用本软件前，请务必仔细阅读并充分理解[《用户协议与免责声明》](#用户协议与免责声明)的全部内容。** 您一旦下载、安装、复制、修改或使用本软件，即视为已阅读、理解并同意接受该声明的全部内容；如不同意，请勿使用并立即删除本软件。

## 新功能&优化

- [x] WebDAV 备份与同步优化
- [x] Windows 与 Android APK 自动检查更新
- [x] 连续章节无缝阅读
- [x] 本地、追更、收藏优化
- [x] 新增任务功能，支持后台执行任务及相关视图界面
- [x] 章节阅读状态变更
- [x] 夜览模式
- [x] 支持 Android 端后台下载、追更检查、导入/导出漫画
- [x] 支持 Windows 端托盘最小化
- [x] 简易画质增强功能
- [x] 部分 UI 及使用体验调整优化
- [x] 稍后阅读功能
- [x] 支持自定义自动清理历史记录
- [x] 支持多设备通过扫码方式快速同步webdav配置信息
- [x] 支持主界面长按自定义功能区排序
- [x] 支持多库管理
- [x] WebDAV 漫画库（实验性）
- [x] 应用锁新增 PIN 码、密码、手势解锁
- [x] 阅读时 AI 翻译（实验性）：图片与 OCR 均在本机处理，仅将识别文字发送到用户自行配置的 LLM；服务商支持新手模板/模型拉取与高级自定义，提供省资源、均衡、快速档位，支持整章预翻译、智能消字与受限区域嵌字
- [x] 自定义合集：把分卷、分部发布的多本漫画合成一本阅读，可跨来源

## 使用说明

各功能的配置步骤与操作方式详见 **[使用说明](doc/guide.zh.md)**。应用内亦可查阅：设置 → 关于 → 使用说明。

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

</details>

<details>
<summary><b>在自己的 GitHub 上构建</b></summary>

fork 本仓库后可以直接用 GitHub Actions 出安装包，不必配置本地环境。

**1. 启用 Actions**

fork 出来的仓库默认停用工作流，进 Actions 页点一下按钮启用。

**2. 构建单个平台**

Actions → **Build ALL** → Run workflow → 在 platform 里选 `windows` / `linux` / `macos` / `ios` / `android`，跑完在这次 run 的 Artifacts 里下载。

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

## 迁移提示

从 [venera-app/venera](https://github.com/venera-app/venera) 迁移时，请为 WebDAV 同步指定独立目录，不要与原项目共用。迁移前建议备份旧数据。

## 用户协议与免责声明

> [!NOTE]
> **特别提示：** 在下载、安装或使用本软件前，请您务必仔细阅读并充分理解本声明的全部内容。您一旦下载、安装、复制、修改或使用本软件，即视为已阅读、理解并同意接受本声明的全部内容。

**一、软件性质**

1. 本软件是一款运行于用户本地设备、可由用户自行配置的内容阅读工具，仅提供网络访问、内容解析、阅读排版与本地数据管理等技术功能。软件代码以"原样"提供，不附带任何明示或暗示的担保；本项目维护者不保证其准确性、完整性或适用于任何特定用途，使用风险由使用者自行承担。
2. 本软件默认状态下不预置、不内置、不提供任何第三方网站内容、数据资源或解析扩展；本项目维护者不提供任何内容运营、内容存储、内容发布或内容传播服务，亦不对任何第三方内容作推荐或背书。
3. 本项目仅用于个人学习与研究，功能开发和维护由 AI 驱动。本项目为非营利开源项目：维护者不从事任何商业运营，亦未授权任何个人或组织以本项目名义开展收费分发、售卖、代装、引流、收费社群等商业活动；任何第三方商业行为均与本项目无关，其风险由行为主体自行承担。本项目可能随时暂停、变更或终止开发与发布，恕不另行通知。

**二、扩展与用户行为**

1. 本软件的网络阅读能力以兼容 JavaScript 扩展 API 的形式实现。使用者可自行创建、编辑扩展脚本，亦可导入第三方分享的扩展脚本；是否加载及加载何种扩展，概由使用者自行合法配置，其来源、合法性、准确性与适用性由使用者自行判断并承担全部责任。
2. 使用者通过扩展访问第三方网站时，相关网络请求均由使用者设备直接向目标网站发起并接收数据；本软件仅在本地提供解析、排版与展示能力，不对任何第三方内容进行公开传播或再分发。搜索结果、章节加载、图片可用性及内容版权，均取决于相应网站与扩展的实现，与本项目无涉。
3. 使用者应遵守所在司法管辖区的法律法规、网络安全要求及相关网站的服务协议与版权规范，不得利用本软件从事侵犯知识产权、未经授权获取数据、传播非法内容或恶意软件、干扰或破坏任何网络服务等违法违规行为，亦不得损害任何公司或个人的合法权益。

**三、第三方平台与社区**

任何由第三方建立或维护的扩展分享平台、网站、论坛或交流群组，均属独立运营的第三方，与本项目无任何隶属关系。本项目不参与前述第三方扩展或社区的制作、发布、运营、维护与传播，亦不承担主动审查义务；使用者因使用第三方扩展或访问第三方网站而产生的一切风险与责任，由相关行为主体依法自行承担。

本项目未设立、不运营任何官方社群、群组或对外官方账号，亦未授权任何第三方以本项目名义进行宣传、推广或发布。

**四、隐私与数据**

1. 本软件全部功能均运行于用户本地设备。本项目不设任何服务器，不向维护者收集、上传任何用户数据（包括阅读内容、扩展列表、浏览记录等），亦不集成任何统计、崩溃分析或遥测组件。用户主动开启的可选功能（如 AI 翻译）可能向用户自行配置的第三方服务发送数据，详见下方第 3 款。
2. 网络与存储权限仅用于实现在线阅读、本地备份导入导出、WebDAV 同步、应用更新检查、AI 翻译、翻译模型下载等软件功能，不作任何其他用途；WebDAV 同步数据仅传输至用户自行配置的服务器，维护者无法访问、获取或控制该服务器及其中存储的数据。
3. AI 翻译为可选功能，默认关闭，且不预置任何服务商、端点或密钥。用户开启后，识别出的文字仅发送至用户自行配置的第三方模型服务；是否使用、使用哪家服务商，均由用户自行决定，并应遵守该服务商的条款——维护者不接触亦不控制此类请求或数据。可选的离线翻译引擎会从用户可配置的公开仓库（如 HuggingFace 或其镜像）下载公开发布、采用宽松许可的模型文件。

**五、知识产权**

1. 本项目尊重知识产权。若权利人认为本仓库直接包含的代码或文件侵犯其合法权益，可向维护者提交包含身份证明、权属证明及具体信息的有效通知，维护者将在合理技术能力范围内予以处理。
2. 对于任何第三方扩展及其解析、呈现的第三方内容，本项目既不托管亦无法控制，故无法对其采取移除、屏蔽等处理措施；请权利人依法向相关扩展的发布者或内容的实际托管方主张权利。
3. 本项目不受理涉及第三方网站内容、扩展配置、具体作品可用性或版权归属等事项的 issue 或技术支持请求。

**六、责任限制**

1. 在适用法律允许的最大范围内，本项目及维护者不对因使用或无法使用本软件，或因第三方扩展、第三方网站、网络环境、数据丢失、设备故障、账号异常、版权纠纷等原因造成的任何直接、间接、附带、特殊、惩罚性或后果性损失承担责任。使用者应自行评估并承担使用本软件的一切风险。
2. 本项目不保证与任何第三方网站、扩展或服务保持兼容，亦不保证任何功能持续可用。

**七、二次开发与分发**

1. 本项目是基于 Venera 修改的版本，由本项目维护者独立开发与发布，原项目及其维护者不对本项目的代码、构建产物及行为承担任何责任。本章的责任划分是双向的，同样适用于任何基于本项目再次修改的版本。
2. 任何基于本项目源码修改、构建或分发的版本（包括 fork、私有构建、自行签名的安装包），均由该版本的发布者独立负责。本项目维护者不审查、不背书、不提供技术支持，亦不对其代码、构建产物、行为及由此产生的任何后果承担责任。
3. 修改版本应以可区分的名称发布，并在显著位置说明其为基于本项目的修改版本；不得声称获得本项目授权、认可，或与本项目存在隶属关系。
4. 仅本仓库 Release 页面提供的构建产物由本项目发布。经其他渠道获取的安装包，以及任何预置了扩展脚本、扩展地址或内容源清单的构建产物，均与本项目无关，其完整性、安全性与合规性由提供者自行负责。
5. 修改版本的发布者应自行履行 LICENSE 所载义务，并遵守其所在司法管辖区的法律法规，由此产生的责任自行承担。

**八、其他**

1. 禁止在各类公开/官方平台及官方账号区域（包括但不限于微博、微信公众号、X 等）宣传或推广本项目。
2. 本软件依据仓库根目录 LICENSE 文件所载许可证授权分发；本声明不修改、不限制该许可证授予的权利，如两者存在冲突，以许可证为准。
3. 一旦下载、复制、修改或使用本项目，即视为已阅读并接受本声明的全部内容。本项目维护者保留随时修改或补充本声明的权利，修改后的声明自发布时生效。

## Star History

<a href="https://www.star-history.com/?type=date&repos=Kyosee%2FVeneraX">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&theme=dark&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=Kyosee/VeneraX&type=date&legend=top-left&sealed_token=t_CyvEveWN9HuG5CZb1KoUGGLxlcTA0a5341bBCAAV63Hh34aiVyEOvU9gpq1q9Wvcw48bzlVHPdlWQ5s-tz-bn9iq8_TBG0oU-Zk7CFAb_Pf7SqzE9J0eEazga6bCemssv2kIYq-9xlbymcG6S000iehp3Zs_TRV73aoOaEMv7pZP-qrRwaP6a7vuB1" />
 </picture>
</a>

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

## 快速开始

### 原生应用

```bash
flutter build apk        # Android
flutter build windows    # Windows
flutter build linux      # Linux
flutter build macos      # macOS
```

## 从源码构建

1. 克隆仓库
2. 安装 [Flutter](https://flutter.dev/docs/get-started/install)

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

1. 本软件全部功能均运行于用户本地设备。本项目不设任何服务器，不收集、不上传任何用户数据（包括阅读内容、扩展列表、浏览记录等），亦不集成任何统计、崩溃分析或遥测组件。
2. 网络与存储权限仅用于实现在线阅读、本地备份导入导出、WebDAV 同步、应用更新检查等软件功能，不作任何其他用途；WebDAV 同步数据仅传输至用户自行配置的服务器，维护者无法访问、获取或控制该服务器及其中存储的数据。

**五、知识产权**

1. 本项目尊重知识产权。若权利人认为本仓库直接包含的代码或文件侵犯其合法权益，可向维护者提交包含身份证明、权属证明及具体信息的有效通知，维护者将在合理技术能力范围内予以处理。
2. 对于任何第三方扩展及其解析、呈现的第三方内容，本项目既不托管亦无法控制，故无法对其采取移除、屏蔽等处理措施；请权利人依法向相关扩展的发布者或内容的实际托管方主张权利。
3. 本项目不受理涉及第三方网站内容、扩展配置、具体作品可用性或版权归属等事项的 issue 或技术支持请求。

**六、责任限制**

1. 在适用法律允许的最大范围内，本项目及维护者不对因使用或无法使用本软件，或因第三方扩展、第三方网站、网络环境、数据丢失、设备故障、账号异常、版权纠纷等原因造成的任何直接、间接、附带、特殊、惩罚性或后果性损失承担责任。使用者应自行评估并承担使用本软件的一切风险。
2. 本项目不保证与任何第三方网站、扩展或服务保持兼容，亦不保证任何功能持续可用。

**七、其他**

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

# VeneraX 鸿蒙测试版 / HarmonyOS preview

应用版本保持 **2.3.12+257**。`harmonyos-2.3.12-test.1` 是独立测试发布标签，不替换其他平台的稳定版。

## 下载与安装

- 下载 `VeneraX-2.3.12+257-harmonyos-arm64-test.1-unsigned.hap`。这是完整应用的 ARM64 release 构建，支持手机类型；声明的最低系统为 HarmonyOS 5.0.5 / API 17。
- **包未签名，普通真机不能直接安装。** 请按华为官方流程，使用自己的开发者身份、证书及包含目标设备的调试 Profile 签名。Profile 的包名必须为 `com.github.kyosee.venera`，并按项目请求配置 `ohos.permission.FILE_ACCESS_PERSIST` 等权限。保留自己的签名材料，后续覆盖安装需要兼容的签名。
- 官方说明：[配置调试签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)、[自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)、[手动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual)。使用 DevEco Studio 随附的 SDK 签名工具处理 HAP；不要上传私钥、密码、Profile 或备份给第三方签名网站。
- 签名后，连接已授权调试的手机，使用 SDK 的 `hdc install "你的已签名文件.hap"` 安装。当前尚无真机签名安装验证，不能保证所有设备或系统版本都可运行。
- 从源码签名构建：使用独立 checkout，按 [构建说明](harmonyos.md) 准备官方工具链；在 DevEco 打开 `ohos` 工程配置自己的签名，再运行 `tool/build_ohos.ps1`，加 `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release -CodeSign`。证书与本机签名配置只保留在本地。

## 已验证与限制

| 范围 | 当前结果 |
|---|---|
| 本地核心流程 | 官方 HarmonyOS 7 / API 26 x64 模拟器已验证备份导入恢复、书源网络、在线阅读、下载与离线阅读、历史收藏、六种阅读模式、WebDAV 往返、系统保存和漫画归档导回 |
| 网络与 WebView | 本地场景验证 Cookie、代理、证书拒绝和存储隔离；本次另修复导航时人为补发来源网址的问题，具体网站登录仍需实测 |
| 原生和发布构建 | ARM64 release 编译及包内版本检查；不代表 ARM64 真机已验收 |
| 待真机验证 | PDF 导入渲染、PIN/生物认证成功、持久目录授权、真实扫码、具体网站登录及在线翻译服务 |
| 已知模拟器限制 | x64 模拟器不支持官方 PDF Kit；目录选择器存在缺少完成按钮的问题；模拟器宿主曾出现自身进程退出，尚未证明由 VeneraX 引起 |

测试前请先备份。反馈问题时只提交必要的复现步骤和脱敏错误信息，不附账号、Cookie、令牌、书源配置或真实备份。

## English

The app version remains **2.3.12+257**. The separate `harmonyos-2.3.12-test.1` prerelease does not replace stable releases for other platforms.

Download `VeneraX-2.3.12+257-harmonyos-arm64-test.1-unsigned.hap`. This is the complete app in ARM64 release mode for phones, with a declared minimum of HarmonyOS 5.0.5 / API 17.

**The HAP is unsigned and cannot be installed directly on an ordinary phone.** Follow Huawei's [automatic](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) or [manual signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) instructions with your own developer identity, certificate and a debug profile containing the target device. The profile must match `com.github.kyosee.venera` and the requested permissions, including `ohos.permission.FILE_ACCESS_PERSIST`. Use the signing tool supplied with DevEco's SDK, then run `hdc install "your-signed-file.hap"` on an authorized debugging connection. Keep signing material private and consistent for future upgrades; do not upload keys, passwords, profiles or backups to signing websites.

Alternatively, follow the [isolated build guide](harmonyos.md), configure signing in the `ohos` project in DevEco, then pass `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release -CodeSign` to `tool/build_ohos.ps1`. Keep credentials and local signing configuration out of Git.

Core backup, source/network, online/offline reading, downloads, history/favorites, six reading modes, WebDAV, system saving and archive round trips have been exercised on the official HarmonyOS 7 / API 26 x64 emulator. Local WebView checks cover cookies, proxies, certificate rejection and origin storage; this preview also fixes manually reconstructed navigation referrers.

ARM64 compilation and package checks do not establish phone compatibility. Signed phone installation, native PDF rendering, successful PIN/biometric authentication, persistent folder authorization, real QR scanning, site-specific login and online translation still need device testing. The x64 emulator does not support Huawei PDF Kit, its folder picker lacks a completion action, and its host process has exited unexpectedly without evidence attributing this to VeneraX.

Back up first. Reports should contain only minimal reproduction steps and redacted errors, never accounts, cookies, tokens, source configurations or personal backups.

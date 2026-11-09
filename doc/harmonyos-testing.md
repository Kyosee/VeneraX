# VeneraX 鸿蒙开发预览版 / HarmonyOS developer preview

应用版本保持 **2.3.12+257**。`harmonyos-2.3.12-test.1` 是独立测试发布标签，不替换其他平台的稳定版。**本次提供未签名开发预览；ARM64 真机签名安装尚未验收。**

## 下载与安装

两个 HAP 都是完整应用的 release 构建，请按目标设备的 CPU 架构选择：

| 文件 | 用途与验证状态 |
|---|---|
| `VeneraX-2.3.12+257-harmonyos-x64-emulator-test.1-unsigned.hap` | Windows 上的官方 x86_64 模拟器；已在 HarmonyOS 7 / API 26 模拟器安装并启动完整应用 |
| `VeneraX-2.3.12+257-harmonyos-arm64-test.1-unsigned.hap` | ARM64 手机候选包；已编译，仍需自行签名，真机安装及运行尚未验证 |

模拟器界面显示的手机型号不代表 CPU 架构。ARM64 包不能装到这里使用的 x86_64 模拟器；更换模拟器外观型号也不能解决架构不匹配。

### x64 模拟器

启动官方模拟器，使用 DevEco SDK 自带的 `hdc` 安装 x64 包。可在 DevEco 安装目录的 `sdk/default/openharmony/toolchains` 找到此工具；将其加入 PATH，或使用完整路径运行：

```text
hdc list targets
hdc -t <设备地址> shell uname -m
hdc -t <设备地址> install "VeneraX-2.3.12+257-harmonyos-x64-emulator-test.1-unsigned.hap"
hdc -t <设备地址> shell aa start -a EntryAbility -b com.github.kyosee.venera
```

将 `<设备地址>` 替换为第一条命令列出的地址；架构应为 `x86_64`。Windows 安装路径使用反斜杠，或在 HAP 所在目录使用文件名。当前验证过的官方模拟器允许安装此未签名包；这不适用于普通真机。

若提示 `00801017`、缺少 `x86_64` ABI 或 `install parse native so failed`，检查是否误选了 ARM64 包。安装失败不会覆盖旧应用；若之后仍看到 `Hello World`，可能是此前留下的示例应用。安装成功后应进入 VeneraX 主界面，并在设置中看到版本 `2.3.12`。必要时使用 `hdc -t <设备地址> shell bm dump -n com.github.kyosee.venera` 核对 `versionName: 2.3.12`、`versionCode: 257` 和 `debug: false`；不要只凭安装命令退出码判断成功。

### ARM64 手机

- 包声明支持手机类型，最低系统为 HarmonyOS 5.0.5 / API 17；最低版本声明不等于已在该版本完成测试。
- **包未签名，普通真机不能直接安装。** 请按华为官方流程，使用自己的开发者身份、证书及包含目标设备的调试 Profile 签名。Profile 的包名必须为 `com.github.kyosee.venera`，并按项目请求配置 `ohos.permission.FILE_ACCESS_PERSIST` 等权限。保留自己的签名材料，后续覆盖安装需要兼容的签名。
- 官方说明：[配置调试签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)、[自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto)、[手动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual)。使用 DevEco Studio 随附的 SDK 签名工具处理 HAP；不要上传私钥、密码、Profile 或备份给第三方签名网站。
- 签名后，连接已授权调试的手机，使用 SDK 的 `hdc install "你的已签名文件.hap"` 安装。当前尚无真机签名安装验证，不能保证所有设备或系统版本都可运行。
- 从源码签名构建：使用独立 checkout，按 [构建说明](harmonyos.md) 准备官方工具链；在 DevEco 打开 `ohos` 工程配置自己的签名，再运行 `tool/build_ohos.ps1`，加 `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release -CodeSign`。证书与本机签名配置只保留在本地。

## 已验证与限制

| 范围 | 当前结果 |
|---|---|
| 本地核心流程 | 官方 HarmonyOS 7 / API 26 x64 模拟器已验证备份导入恢复、书源网络、在线阅读、下载与离线阅读、历史收藏、六种阅读模式、WebDAV 往返、系统保存和漫画归档导回 |
| 网络与 WebView | 本地场景验证 Cookie、代理、证书拒绝和存储隔离；本次另修复导航时人为补发来源网址的问题，具体网站登录仍需实测 |
| 原生和发布构建 | x64 release 已安装启动，ARM64 release 已编译及检查包内版本；模拟器结果不代表 ARM64 真机已验收 |
| 待真机验证 | PDF 导入渲染、PIN/生物认证成功、持久目录授权、真实扫码、具体网站登录及在线翻译服务 |
| 已知模拟器限制 | x64 模拟器不支持官方 PDF Kit；目录选择器存在缺少完成按钮的问题；模拟器宿主曾出现自身进程退出，尚未证明由 VeneraX 引起 |

测试前请先备份。反馈问题时只提交必要的复现步骤和脱敏错误信息，不附账号、Cookie、令牌、书源配置或真实备份。

## English

The app version remains **2.3.12+257**. The separate `harmonyos-2.3.12-test.1` prerelease does not replace stable releases for other platforms. **This is an unsigned developer preview; signed ARM64 phone installation has not been verified.**

Both HAPs contain the complete app in release mode. Select the CPU architecture of the target device:

| File | Purpose and validation |
|---|---|
| `VeneraX-2.3.12+257-harmonyos-x64-emulator-test.1-unsigned.hap` | Official x86_64 emulator on Windows; installation and full app startup verified on HarmonyOS 7 / API 26 |
| `VeneraX-2.3.12+257-harmonyos-arm64-test.1-unsigned.hap` | ARM64 phone candidate; compiled, but requires signing and has not been installed or run on a phone |

The phone model shown by an emulator does not determine its CPU architecture. The ARM64 package cannot be installed on the x86_64 emulator used here, even if its appearance is changed to another phone model.

### x64 emulator

Start an official emulator and use the `hdc` commands shown above. The tool is bundled in DevEco's `sdk/default/openharmony/toolchains`; add it to PATH or invoke its full path. Replace `<设备地址>` with an address listed by `hdc list targets` and confirm `uname -m` returns `x86_64`. On Windows, use backslashes in the HAP path or run the command from the HAP's directory. The tested official emulator accepts this unsigned HAP; ordinary phones do not.

Errors such as `00801017`, a missing `x86_64` ABI, or `install parse native so failed` indicate that you should check whether the ARM64 package was selected. A failed installation leaves the old app in place; a subsequent `Hello World` screen may be an earlier sample app. Successful installation should open VeneraX and show version `2.3.12` in Settings. If needed, run `hdc -t <device-address> shell bm dump -n com.github.kyosee.venera` and check `versionName: 2.3.12`, `versionCode: 257` and `debug: false`. Do not rely on the install command's exit code alone.

### ARM64 phones

The package declares phone support and a minimum of HarmonyOS 5.0.5 / API 17; this minimum has not been validated on a device.

**The HAP is unsigned and cannot be installed directly on an ordinary phone.** Follow Huawei's [automatic](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) or [manual signing](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) instructions with your own developer identity, certificate and a debug profile containing the target device. The profile must match `com.github.kyosee.venera` and the requested permissions, including `ohos.permission.FILE_ACCESS_PERSIST`. Use the signing tool supplied with DevEco's SDK, then run `hdc install "your-signed-file.hap"` on an authorized debugging connection. Keep signing material private and consistent for future upgrades; do not upload keys, passwords, profiles or backups to signing websites.

Alternatively, follow the [isolated build guide](harmonyos.md), configure signing in the `ohos` project in DevEco, then pass `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release -CodeSign` to `tool/build_ohos.ps1`. Keep credentials and local signing configuration out of Git.

Core backup, source/network, online/offline reading, downloads, history/favorites, six reading modes, WebDAV, system saving and archive round trips have been exercised on the official HarmonyOS 7 / API 26 x64 emulator. Local WebView checks cover cookies, proxies, certificate rejection and origin storage; this preview also fixes manually reconstructed navigation referrers.

ARM64 compilation and package checks do not establish phone compatibility. Signed phone installation, native PDF rendering, successful PIN/biometric authentication, persistent folder authorization, real QR scanning, site-specific login and online translation still need device testing. The x64 emulator does not support Huawei PDF Kit, its folder picker lacks a completion action, and its host process has exited unexpectedly without evidence attributing this to VeneraX.

Back up first. Reports should contain only minimal reproduction steps and redacted errors, never accounts, cookies, tokens, source configurations or personal backups.

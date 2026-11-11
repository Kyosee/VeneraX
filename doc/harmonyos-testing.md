# VeneraX 鸿蒙开发预览版

<a id="english"></a>

中文 | [English](harmonyos-testing.en.md)

本文对应 **`harmonyos-2.3.12-test.1` / 应用版本 `2.3.12+257`**，不代表后续源码构建或其他平台的稳定版本。

**这是未签名开发预览版。x64 模拟器包已完成安装启动测试；ARM64 真机包需自行签名，签名安装及运行尚未验证。**

## 目录

- [下载与架构选择](#下载与架构选择)
- [x64 模拟器安装](#x64-模拟器安装)
- [ARM64 手机签名与安装](#arm64-手机签名与安装)
- [已验证与限制](#已验证与限制)
- [反馈问题](#反馈问题)

## 下载与架构选择

打开 [该预览版本的发布页](https://github.com/Kyosee/VeneraX/releases/tag/harmonyos-2.3.12-test.1)，在附件中选择对应 HAP。两个包都包含完整应用，使用 release 模式构建。

| 文件 | 目标与验证状态 |
|---|---|
| `VeneraX-2.3.12+257-harmonyos-x64-emulator-test.1-unsigned.hap` | Windows 上的官方 x86_64 模拟器；已在 HarmonyOS 7 / API 26 模拟器安装并启动 |
| `VeneraX-2.3.12+257-harmonyos-arm64-test.1-unsigned.hap` | ARM64 真机测试用；需自行签名，真机安装与运行尚未验证 |

模拟器显示的手机型号不代表 CPU 架构。ARM64 包不能安装到这里验证过的 x86_64 模拟器；更换外观型号不能解决架构不匹配。

测试前先备份。覆盖安装需要兼容的签名；不要为了绕过安装错误直接卸载已有应用，以免丢失数据。自行从源码构建请看 [鸿蒙开发手册](harmonyos.md)。

## x64 模拟器安装

### 1. 确认设备

启动官方模拟器，在 PowerShell 中设置 DevEco SDK 自带的 `hdc` 路径并列出设备。路径为示例，请按安装位置修改。

```powershell
$hdc = 'D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe'
& $hdc list targets
```

将下一段的 `REPLACE_WITH_DEVICE_ADDRESS` 替换为上一步列出的设备地址，将 HAP 路径改为下载文件的位置，再执行：

```powershell
$device = 'REPLACE_WITH_DEVICE_ADDRESS'
$previewHap = 'D:/Downloads/VeneraX-2.3.12+257-harmonyos-x64-emulator-test.1-unsigned.hap'
& $hdc -t $device shell uname -m
```

架构应为 `x86_64`。确认后安装并启动：

```powershell
& $hdc -t $device install $previewHap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

### 2. 核对安装结果

- 应进入 VeneraX 主界面，设置中版本为 `2.3.12`。
- 对本页指定的预览包，`bm dump` 应显示 `versionName: 2.3.12`、`versionCode: 257`、`debug: false`。
- 同时检查安装命令的输出和实际应用，不要仅凭命令退出码判断成功。

| 现象 | 检查方式 |
|---|---|
| `00801017`、缺少 `x86_64` ABI、`install parse native so failed` | 先用 `uname -m` 核对设备架构，再核对是否误用了 ARM64 包 |
| 启动后仍显示 `Hello World` | 安装失败可能留下此前的示例应用；核对安装输出、包名和版本 |
| 提示签名问题 | 仅当前验证过的官方模拟器允许该未签名包；普通真机必须按下节签名 |

## ARM64 手机签名与安装

包声明最低系统为 **HarmonyOS 5.0.5 / API 17**；最低版本声明不等于已在该版本测试通过。

1. 使用自己的开发者身份，按华为 [配置调试签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)、[自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) 或 [手动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) 流程准备证书及包含目标设备的调试 Profile。
2. Profile 的包名必须匹配 `com.github.kyosee.venera`，并按应用请求配置 `ohos.permission.FILE_ACCESS_PERSIST` 等权限。使用 DevEco SDK 随附的签名工具签署 ARM64 HAP。
3. 连接已授权调试的手机，使用上节方法设置 `$hdc` 与 `$device`，核对设备架构，再安装自己的签名包。

```powershell
$signedHap = 'D:/Downloads/VeneraX-signed.hap'
& $hdc -t $device shell uname -m
& $hdc -t $device install $signedHap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

路径同样需要替换。安装后核对版本与启动情况，再逐项测试所需功能；这些步骤是待设备验证的操作指引，不是已经通过的真机验收结果。

从源码签名构建时，使用独立 checkout，在 DevEco 打开 `ohos` 工程配置签名，再按 [构建手册](harmonyos.md) 运行 `tool/build_ohos.ps1`，传入 `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release -CodeSign`。

证书、私钥、密码、Profile 和本机签名配置只保留在本地，不提交 Git，也不上传到第三方签名网站。保留自己的签名材料，后续覆盖安装需要兼容签名。设备绑定的调试 Profile 不能作为通用安装方案分发。

## 已验证与限制

以下是该预览版已有验证记录；文档更新不代表重新完成了设备测试。

| 范围 | 记录中的结果 |
|---|---|
| 本地核心流程 | 官方 HarmonyOS 7 / API 26 x64 模拟器已验证备份导入恢复、书源网络、在线阅读、下载与离线阅读、历史收藏、六种阅读模式、WebDAV 往返、系统保存和漫画归档导回 |
| 网络与 WebView | 本地场景验证 Cookie、代理、证书拒绝和存储隔离；该预览版修复了导航时人为补发来源网址的问题，具体网站登录仍需实测 |
| 原生与发布构建 | x64 release 已安装启动；ARM64 release 已编译并检查包内版本，真机签名安装及运行仍未验证 |
| 待设备验证 | PDF 导入渲染、PIN/生物认证成功、持久目录授权、真实扫码、具体网站登录及在线翻译服务 |
| 已知模拟器限制 | x64 模拟器不支持官方 PDF Kit；目录选择器缺少完成按钮；模拟器宿主曾自行退出，尚未证明由 VeneraX 引起 |

## 反馈问题

提供包文件名、设备架构、系统/API 版本、最小复现步骤和脱敏错误信息；说明使用的是本页预览包还是自行构建的版本。不要附账号、Cookie、令牌、书源配置、真实备份或签名材料。

# VeneraX 鸿蒙版安装与签名

<a id="english"></a>

中文 | [English](harmonyos-testing.en.md)

从 `3.0.2-beta.2` 起，鸿蒙发布版只提供一个面向 ARM64 手机、平板的未签名 HAP，真机安装前需自行签名。

## 目录

- [下载与架构选择](#下载与架构选择)
- [ARM64 手机签名与安装](#arm64-手机签名与安装)
- [已验证与限制](#已验证与限制)
- [反馈问题](#反馈问题)

## 下载与架构选择

在 [发布页](https://github.com/Kyosee/VeneraX/releases) 选择需要的版本，下载以 `-harmonyos-unsigned.hap` 结尾的文件。包内原生库适用于 ARM64 真机。[v3.0.0](https://github.com/Kyosee/VeneraX/releases/tag/v3.0.0) 等旧版曾另外提供 x64 模拟器 HAP。

安装前先备份。覆盖安装需要兼容的签名，卸载已有应用可能会丢失数据。

## ARM64 手机签名与安装

包声明最低系统为 **HarmonyOS 5.0.5 / API 17**；最低版本声明不等于已在该版本测试通过。

1. 使用自己的开发者身份，按华为 [配置调试签名](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing)、[自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) 或 [手动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) 流程准备证书及包含目标设备的调试 Profile。
2. Profile 的包名必须匹配 `com.github.kyosee.venera`，并按应用请求配置 `ohos.permission.FILE_ACCESS_PERSIST` 等权限。使用 DevEco SDK 随附的签名工具签署 ARM64 HAP。
3. 连接已授权调试的手机，将 `$hdc` 改为 DevEco SDK 内的工具路径，用 `list targets` 查到设备地址，核对架构后安装自己的签名包。

```powershell
$hdc = 'D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe'
& $hdc list targets
$device = 'REPLACE_WITH_DEVICE_ADDRESS'
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

以下区分适配期间已有的设备验证记录与发布构建检查。历史设备验证不等于已在所有系统、真机或网站上测试通过。

| 范围 | 记录中的结果 |
|---|---|
| 本地核心流程 | 官方 HarmonyOS 7 / API 26 x64 模拟器已验证备份导入恢复、书源网络、在线阅读、下载与离线阅读、历史收藏、六种阅读模式、WebDAV 往返、系统保存和漫画归档导回 |
| 网络与 WebView | 适配期间验证 Cookie、代理、证书拒绝和存储隔离，并修复导航时人为补发来源网址的问题；具体网站登录仍需实测 |
| 发布构建检查 | 发布流水线检查 ARM64 HAP 的版本、发布模式、架构及必需原生库。签名安装和运行仍需真机验证 |
| 待设备验证 | PDF 导入渲染、PIN/生物认证成功、持久目录授权、真实扫码、具体网站登录及在线翻译服务 |
| 已知模拟器限制 | x64 模拟器不支持官方 PDF Kit；目录选择器缺少完成按钮；模拟器宿主曾自行退出，尚未证明由 VeneraX 引起 |

## 反馈问题

提供包文件名、设备架构、系统/API 版本、最小复现步骤和脱敏错误信息；说明使用的是本页发布包还是自行构建的版本。不要附账号、Cookie、令牌、书源配置、真实备份或签名材料。

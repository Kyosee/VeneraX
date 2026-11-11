# VeneraX 鸿蒙开发

中文 | [English](harmonyos.en.md)

本手册用于在 **Windows x64** 上从源码构建和验证 VeneraX 鸿蒙版。只想安装已发布的测试包，请看 [预览版安装说明](harmonyos-testing.md)；本页只记录 VeneraX 自身的鸿蒙构建、签名、探针和设备验证。

当前为实验性适配：完整应用可构建为 x64 和 ARM64 HAP，运行记录来自官方 x64 手机模拟器。ARM64 真机签名安装与运行、持久目录授权、认证成功及原生 PDF 渲染仍需设备验证。本页保留既有验证记录，文档更新不代表重新完成了运行测试。

## 目录

- [环境与版本](#环境与版本)
- [快速开始：x64 模拟器](#快速开始x64-模拟器)
- [构建阶段与参数](#构建阶段与参数)
- [ARM64 构建、签名与安装](#arm64-构建签名与安装)
- [探针与功能验证](#探针与功能验证)
- [常见问题](#常见问题)
- [验证记录与待办](#验证记录与待办)
- [附录：依赖实现细节](#附录依赖实现细节)

## 环境与版本

### 已验证的工具组合

| 项目 | 要求或记录 |
|---|---|
| 宿主 | Windows x64、PowerShell、Git；项目脚本使用 `.bat` / `.exe`，ONNX 脚本检查 x64 宿主架构 |
| OH Flutter | CPF-Flutter `3.44.9+ohos-1.0.0-beta`，提交 `744cbb4f08e577787774c04033cc19a9d318d0d2`，Dart 3.12.2 |
| DevEco | DevEco Studio 26.0.0.865，API 26 SDK |
| SDK 组件 | JBR、Node、ohpm、hvigor、`hdc`，以及 native SDK 中的 Clang、CMake 和 Ninja |
| Rust | Rust 1.85.1；同时安装 `x86_64-unknown-linux-ohos` 和 `aarch64-unknown-linux-ohos` targets |
| 运行环境 | 官方 HarmonyOS 7 / API 26 x86_64 手机模拟器；ARM64 真机运行未验证 |
| 应用声明 | 最低 HarmonyOS 5.0.5 / API 17，目标 API 26；最低版本声明不等于最低版本验收 |
| 其他平台 | 现有标准 Flutter 环境使用 3.44.3，与 OH SDK 及项目目录分开 |

CPF-Flutter 是 [华为文档](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784651007/) 链接的 OpenHarmony 适配项目，不是 Google 上游 Flutter 发布版。这里记录的是已用过的开发候选版组合，不保证其他版本可以直接替换。

### 获取和初始化 SDK

先从华为安装 DevEco Studio，在其 SDK 管理界面安装所需组件并完成相应许可流程。Flutter OH 的 [仓库 README](https://gitcode.com/CPF-Flutter/flutter_flutter) 提供环境搭建、应用构建和插件适配文档入口。

若尚未安装 OH SDK，可在新目录获取并检出上述提交：

```powershell
git clone https://gitcode.com/CPF-Flutter/flutter_flutter.git D:/dev/tools/flutter_ohos
git -C D:/dev/tools/flutter_ohos checkout --detach 744cbb4f08e577787774c04033cc19a9d318d0d2
```

已有可用 SDK 时直接使用；不要在含有自己修改的 SDK 目录中直接切换提交。下面的路径都是示例，应改成自己的安装位置。新开一个专用于鸿蒙的 PowerShell 窗口，执行：

```powershell
$flutterOhSdk = 'D:/dev/tools/flutter_ohos'
$devEcoStudio = 'D:/Program Files/Huawei/DevEco Studio'
$ohFlutter = Join-Path $flutterOhSdk 'bin/flutter.bat'
$ohDart = Join-Path $flutterOhSdk 'bin/dart.bat'
$hdc = Join-Path $devEcoStudio 'sdk/default/openharmony/toolchains/hdc.exe'
$env:DEVECO_SDK_HOME = Join-Path $devEcoStudio 'sdk'
$env:JAVA_HOME = Join-Path $devEcoStudio 'jbr'
$env:NODE_HOME = Join-Path $devEcoStudio 'tools/node'
$env:Path = @((Join-Path $flutterOhSdk 'bin'), $env:NODE_HOME, (Join-Path $devEcoStudio 'tools/ohpm/bin'), (Join-Path $devEcoStudio 'tools/hvigor/bin'), (Join-Path $devEcoStudio 'sdk/default/openharmony/toolchains'), $env:Path) -join [IO.Path]::PathSeparator
$env:FLUTTER_STORAGE_BASE_URL = 'https://flutter-ohos.obs.cn-south-1.myhuaweicloud.com'
& $ohFlutter --version
& $ohFlutter doctor -v
git --version
rustup toolchain install 1.85.1
rustup target add x86_64-unknown-linux-ohos aarch64-unknown-linux-ohos --toolchain 1.85.1
rustup run 1.85.1 rustc --version
rustup target list --installed --toolchain 1.85.1
```

这些环境变量只影响当前终端及其子进程，关闭窗口后结束；不要把 OH 下载源和 SDK 路径覆盖到标准 Flutter 开发终端。下载源来自该版本 SDK 的 README，升级 SDK 时应重新核对官方说明。

`--version` 应对应表中的 OH SDK / Dart 版本；`doctor -v` 中与 OHOS 工具链相关的错误应先解决。Rust targets 列表必须同时含有上表两项。主构建脚本也会检查原生组件和固定源码要求。

## 快速开始：x64 模拟器

先完成上一节环境设置，以下命令沿用其中的 `$flutterOhSdk`、`$devEcoStudio`、`$ohFlutter` 和 `$hdc` 变量。

### 1. 使用独立项目目录

```powershell
git clone https://github.com/Kyosee/VeneraX.git D:/dev/project/venera-harmonyos
Set-Location D:/dev/project/venera-harmonyos
```

已有独立 checkout 时直接进入它。后续命令都在项目根目录执行。两套 Flutter SDK 都会写入 `.dart_tool/package_config.json`、包依赖图和生成的插件文件，因此标准 Flutter 与 OH Flutter 需要不同的项目目录，不能只切换可执行文件。

VeneraX 已包含 `ohos/` 工程，无需对本项目重新运行 `flutter create`。不要从标准 checkout 复制 `.dart_tool`、`build` 或生成的插件配置。

### 2. 构建完整应用

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio
Get-ChildItem build/ohos/hap/*.hap
```

默认构建入口为 `lib/main.dart`，平台为 `ohos-x64`，模式为 `debug`，不签名。首次构建会下载部分源码并编译原生库，耗时取决于网络和主机；各阶段见 [构建阶段与参数](#构建阶段与参数)。

构建成功输出会打印实际 HAP 路径。当前验证过的工具链将 HAP 复制到 `build/ohos/hap/`，未签名包通常为 `entry-default-unsigned.hap`。切换架构或模式后仍可能使用相同文件名，应以本次成功构建的参数和输出为准；该目录也可能留下先前构建的文件。

### 3. 连接并核对模拟器

启动官方 HarmonyOS 7 / API 26 x86_64 手机模拟器。运行第一条命令，将 `REPLACE_WITH_DEVICE_ADDRESS` 改成输出中的设备地址，再执行后两条：

```powershell
& $hdc list targets
$device = 'REPLACE_WITH_DEVICE_ADDRESS'
& $hdc -t $device shell uname -m
```

`uname -m` 应为 `x86_64`。模拟器外观显示的手机型号不决定 CPU 架构，ARM64 HAP 不能安装到该模拟器。

### 4. 安装、启动并验收

核对 `$hap` 与本次构建输出一致后执行：

```powershell
$hap = 'build/ohos/hap/entry-default-unsigned.hap'
& $hdc -t $device install $hap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

已验证的官方 x64 模拟器允许安装该未签名包；普通真机需要签名。检查安装输出和实际主界面，再核对设置页版本与 `bm dump`，不要只凭安装命令退出码判断成功。

源码构建版本来自当前 `pubspec.yaml`：OH SDK 会在构建时更新 OHOS 应用版本配置。不要把 `ohos/AppScope/app.json5` 的初始占位值或旧预览版的版本号当成本次产物版本。debug 构建也不应套用预览版 release 包的 `debug: false` 验收值。

按自己修改的功能验证启动、阅读、下载、数据保存等流程；设备上的已有数据应先备份。若要验证 x64 release，可重新构建并重复安装检查：

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -TargetPlatform ohos-x64 -BuildMode release
```

## 构建阶段与参数

### 脚本实际执行顺序

| 顺序 | 阶段与入口 | 作用及失败定位 |
|---|---|---|
| 1 | OH Flutter `pub get --enforce-lockfile` | 从 `pubspec.lock` 解析依赖；依赖获取或 SDK 版本错误先在这里解决 |
| 2 | [prepare_ohos.dart](../tool/prepare_ohos.dart) | 准备图标、OHOS 依赖副本、WebView 补丁、包配置和 native 源码映射 |
| 3 | `refresh_plugins.dart` | 使用当前 OH SDK 的插件生成器注册适配器；模板在 [tool/ohos](../tool/ohos/refresh_plugins.dart.template) |
| 4 | [build_ohos_rhttp.ps1](../tool/build_ohos_rhttp.ps1) | 从锁定 Rust 源码构建两种 OHOS ABI |
| 5 | [build_ohos_onnx.ps1](../tool/build_ohos_onnx.ps1) | 获取指定 ONNX/Eigen 源码、应用项目补丁、构建两种 OHOS ABI |
| 6 | OH Flutter `build hap --no-pub` | 按模式、入口和 HAP ABI 编译打包；原生 CMake 还会构建 SQLite、QuickJS、ZIP、7z 和 PNG |

网络需能访问 Pub/Cargo 依赖、GitCode 的 WebView、GitHub 的 ONNX、GitLab 的 Eigen、SQLite 官方源码及 CMake 依赖下载地址。`-WebViewSource`、`-OnnxSource`、`-EigenSource` 可复用对应源码 checkout，但不代表整个构建可以离线。

每次手动执行 `pub get` 后，OHOS 适配配置需要重新准备。日常直接使用主构建脚本，它会按顺序完成准备和插件注册；不要在准备后再运行一次会覆盖生成配置的依赖解析。脚本只临时修改进程环境，并在结束时恢复它修改的变量。

### 参数表

以下参数均属于 [build_ohos.ps1](../tool/build_ohos.ps1)。

| 参数 | 默认值 | 用途 |
|---|---|---|
| `-FlutterSdk` | 必填 | OH Flutter SDK 根目录 |
| `-DevEcoStudio` | 必填 | DevEco Studio 根目录 |
| `-TargetPlatform` | `ohos-x64` | `ohos-x64` 或 `ohos-arm64`，决定最终 HAP ABI |
| `-Target` | `lib/main.dart` | 完整应用或某个探针的 Dart 入口 |
| `-BuildMode` | `debug` | `debug`、`profile`、`release` |
| `-CodeSign` | 关闭 | 启用前必须在 DevEco 配好自己的有效签名身份 |
| `-WebViewSource` | 自动准备 | WebView 固定提交的干净 checkout |
| `-OnnxSource` | 自动准备 | ONNX 固定提交的 checkout；只允许项目规定的兼容补丁 |
| `-EigenSource` | 自动准备 | Eigen 固定提交的干净 checkout |

`-TargetPlatform` 选择最终 HAP 的 ABI；当前主脚本调用 rhttp 和 ONNX 构建时，仍各自构建 `x86_64`、`arm64-v8a` 两种库。切换到探针入口同样不会跳过这些原生构建阶段。

## ARM64 构建、签名与安装

生成未签名 ARM64 release HAP：

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -TargetPlatform ohos-arm64 -BuildMode release
```

该命令只完成编译打包，普通手机不能直接安装未签名 HAP。先连接目标手机，在 DevEco 打开独立 checkout 的 `ohos` 工程，按 [华为自动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-auto) 或 [手动签名](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-signing-manual) 流程配置自己的开发者身份、证书和包含该设备的 Profile。

包名必须匹配 `com.github.kyosee.venera`，权限需匹配项目请求（包括 `ohos.permission.FILE_ACCESS_PERSIST`）。本机签名配置、证书、密码、私钥和 Profile 不提交 Git，不上传第三方签名网站。然后构建签名包：

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -TargetPlatform ohos-arm64 -BuildMode release -CodeSign
Get-ChildItem build/ohos/hap/*.hap
```

确认最新成功输出是已签名 ARM64 HAP，替换下面的包路径和手机地址。先检查 `uname -m` 是 ARM64 架构（通常为 `aarch64`），再安装和启动：

```powershell
$signedHap = 'REPLACE_WITH_SIGNED_HAP_PATH'
& $hdc list targets
$device = 'REPLACE_WITH_PHONE_ADDRESS'
& $hdc -t $device shell uname -m
& $hdc -t $device install $signedHap
& $hdc -t $device shell aa start -a EntryAbility -b com.github.kyosee.venera
& $hdc -t $device shell bm dump -n com.github.kyosee.venera
```

覆盖安装需要兼容签名；不要直接卸载已有应用来绕过错误，以免丢失数据。安装后核对版本、启动及实际功能。ARM64 编译通过不代表签名、安装和运行通过；这些真机验证仍是待办，不能用 x64 模拟器记录替代。设备绑定的调试 Profile 不是通用分发方案。

## 探针与功能验证

### 如何运行并判断结果

探针是独立的 Dart 入口，用于验证局部能力。以下示例构建基础探针，然后按快速开始中的步骤安装和启动：

```powershell
./tool/build_ohos.ps1 -FlutterSdk $flutterOhSdk -DevEcoStudio $devEcoStudio -Target tool/ohos_smoke.dart
```

将 `-Target` 替换成下表入口即可切换。基础/网络探针在界面和日志输出 `PASS` / `FAIL`；OCR 使用自己的结果前缀，后台探针输出结构化结果并提示人工检查，阅读 UI 还有单独的着色器结果。读取完整结果和交互提示；`Ready`、取消操作或某个子项通过都不代表整项完成。

探针仅供本地开发，不作为发布附件。完成后用默认 `lib/main.dart` 重新构建并安装完整应用。基础探针数据在专用 `ohos_smoke.db`，阅读链路和 UI 探针使用独立 `ohos_reader_probe` 目录，备份探针使用新临时目录；不要把真实备份作为测试夹具。

### 入口、覆盖范围和前置条件

| 入口（位于 `tool/`） | 覆盖范围 | 额外检查与限制 |
|---|---|---|
| `ohos_smoke.dart` | 沙箱、包信息、文件读写、SQLite WAL、独立 isolate 的 QuickJS 值/Promise、Unicode ZIP、7z、PNG 像素往返 | 重启后启动计数应增加 |
| `ohos_network_smoke.dart` | 设备本地 HTTP 服务上的 DNS、重定向、Cookie、流、工作 isolate、Dio、取消、超时、代理和 TLS | 测试证书覆盖默认拒绝、显式本地信任及主机名拒绝，不修改应用或系统信任设置 |
| `ohos_onnx_smoke.dart` | FFI CPU 推理、工作 isolate、Unicode 模型名、输出形状、重复运行/会话、无效输入、贪心解码 | 运行时测试不能替代 OCR 模型及完整翻译验证 |
| `ohos_reader_smoke.dart` | 本地回环书源导入/重载、QuickJS 搜索/详情/章节、图片请求头与像素、后台历史写入、排队下载、断网离线读取 | 强制停止后再启动，检查书源、进度和下载保留；不覆盖手势、后台恢复或同步 |
| `ohos_reader_ui_smoke.dart` | 正式阅读器、生成页面、六种模式、音量键、进度和图像增强着色器 | 手势、交互与实际画面需单独检查，编译通过不足以判断 |
| `ohos_backup_smoke.dart` | 本地带认证 WebDAV 与正式 RHttpAdapter 的 `.venera` 往返；修改夹具后恢复脚本、设置、历史、收藏、Cookie | 不配置远程同步账号，不恢复到正常应用数据 |
| `ohos_webview_smoke.dart` | 初始请求头/重定向、JS 结果、原生与 HttpOnly Cookie 增删、local/session storage、恶意键、来源隔离、重载、代理切换和 TLS 拒绝 | 本地服务、无用户账号；具体书源登录与反爬仍需实测 |
| `ohos_system_smoke.dart` | 电量、省电、网络方法/事件、屏幕唤醒、系统代理、认证类型 | 认证进入后台时取消，仅接受官方成功结果；未设置凭据的模拟器不能验证 PIN/生物认证成功 |
| `ohos_file_smoke.dart` | 系统文件导出/导入往返与取消、打开分享面板 | 分享测试直接取消，不选接收方；不证明目录持久授权或接收外部文本/链接分享 |
| `ohos_directory_smoke.dart` | 人工选择目录后的读写、重命名、SQLite WAL、ZIP 和授权恢复 | 需要选择器与持久授权可用；首次完成后重启复验，取消不算通过 |
| `ohos_background_smoke.dart` | 进入后台后的本地并发 HTTP 传输、顺序、断流/恢复及通知移除 | 授予通知权限，并结合生命周期标记人工核对系统后台任务、通知及释放情况 |
| `ohos_ocr_smoke.dart` | 真实英文 OCR、空白对照、模型释放重载、本地翻译及持久结果恢复 | 先启动下节模型服务；首次完整运行成功后再重启验证，不证明在线翻译质量 |
| `ohos_pdf_smoke.dart` | 官方 PDF Kit 的页面转换、尺寸/像素及失败清理 | x86 模拟器不支持该 Kit；需要支持 PDF Kit 的 ARM 模拟器或真机 |

### OCR 模型服务

准备合法获取的本地模型目录，包含 `text_detector/det.onnx`、`ocr_en/rec.onnx`、`ocr_en/dict.txt`。三个文件大小分别须大于零且不超过 8 MiB、16 MiB、64 KiB。在第二个终端进入同一项目目录，将下面的模型根目录改成自己的路径：

```powershell
& $ohDart tool/serve_ohos_ocr_models.dart 'D:/models/translation_models' 18767
```

服务仅绑定宿主回环地址，默认端口 `18767`，只提供上述三个文件并返回 Content-Length；测试结束用 Ctrl+C 停止。探针默认从 `http://10.0.2.2:18767` 访问宿主，运行环境需要支持该模拟器宿主映射。探针只允许 HTTP 的 `127.0.0.1`、`::1`、`10.0.2.2` 根 URL，下载须完整且大小合规。

主构建脚本没有 `--dart-define` 透传参数；自定义模型地址或 restore-only 模式属于源码中的进阶入口，不能直接追加到主脚本。先完成默认完整运行，再重启检查跨进程恢复；restore-only 不能跳过首次成功运行。

### 需要人工核对的系统行为

API 26 官方 x64 模拟器的目录选择器目前缺少进入目录后的完成动作；独立原生 UIAbility 的 FILE/FOLDER 选项也可复现。文件往返或模拟桥接测试不能证明目录授权可用。漫画导出对每个 CBZ、PDF、EPUB 或 `.venera_comics` 使用系统保存对话框，合并归档只出现一次；取消会停止任务，失败不能计为完成。

Scan Kit 的打开和取消已记录通过，真实识码仍需设备测试。通知 Want 的冷/热启动跳转需要检查下载与任务页面；下载和 WebDAV 共享官方数据传输任务，按实际进度更新，最后一个请求结束时释放。本地压缩和 OCR 不申请网络后台任务，「省流」在恢复前台及正常使用时处理待保存变更，不保证无限制后台打包或上传。

API 26 桌面图标切换在启动时检查 API 和全部预设后才显示设置；旧系统保留默认图标。`prepare_ohos.dart` 从项目 PNG 生成 OHOS 资源，素材更新后可用 OH SDK 的 `dart tool/prepare_ohos_icons.dart` 刷新图标，无需重新准备全部依赖。

### 不打包的局部检查

例如修改 PDF 生命周期和导入清理时，可以使用以下现有测试。Node 需支持测试使用的类型剥离 API；Dart 测试在已准备好的 OH checkout 中使用相同 OH SDK，`--no-pub` 避免重新解析覆盖适配配置。

```powershell
node --test test/ohos/pdf_bridge_test.cjs
& $ohFlutter test --no-pub test/ohos_pdf_import_test.dart
```

这些检查覆盖桥接生命周期和 Dart 导入清理，不能代替原生 PDF Kit 渲染或设备交互验收。

## 常见问题

先找完整日志中最早失败的阶段和具体错误；主脚本的最后一行通常只是阶段失败摘要。

| 现象 | 下一步 |
|---|---|
| 找不到 `flutter.bat`、JBR、Node、Clang、CMake 或 Ninja | 核对传入的 SDK 根目录及 DevEco SDK 组件；主脚本是 Windows 构建入口 |
| `Flutter dependency resolution failed.` | 使用同一个 OH SDK 检查版本、网络和锁文件要求；不以随意升级锁文件绕过问题 |
| `Run flutter pub get --enforce-lockfile before preparing OHOS again.` | 准备脚本检测到已改写的包配置；从主构建脚本重新开始，让其按顺序解析、准备并注册 |
| `WebView requires official commit` 或 `Cannot apply the OHOS loader patch` | 核对固定源码提交与锁定依赖；准备脚本依赖指定源码形态，不能手改共享缓存来绕过 |
| `Missing OHOS Rust targets` | 安装两个 targets，并确认 `rustup run 1.85.1 rustc --version` 成功 |
| `The OHOS ONNX build requires an x64 Windows host.` | 在 Windows x64 主机构建；选择 ARM64 HAP 不等于支持 ARM64 宿主构建 |
| ONNX/Eigen 下载、提交或源码修改检查失败 | 检查官方仓库访问及要求的提交；复用 checkout 时保留项目规定的补丁状态，其他修改先另存 |
| `HarmonyOS plugin registration failed.` / `HarmonyOS HAP build failed.` | 检查前面的 Dart、hvigor 或 CMake 原始错误，以及生成配置是否被后续 `pub get` 覆盖 |
| `00801017`、缺少 `x86_64` ABI、`install parse native so failed` | 对照设备 `uname -m`、本次目标参数与实际 HAP；排除误装另一个架构的旧产物 |
| `Hello World` 或仍是旧版界面 | 安装失败可能保留旧应用；核对命令输出、包名和 `bm dump` 的版本 |
| 真机签名错误 | 按官方流程配置自己的证书、设备 Profile、包名和权限；保留验签要求 |
| 目录选择无完成按钮或 PDF 为 `PDF_UNAVAILABLE` | 对照已知设备限制；换支持对应能力的测试设备，不将此状态标为通过 |
| OCR 下载失败或后台探针局部通过 | 检查本地模型服务、地址/大小限制，或人工核对通知与系统任务；参见探针前置条件 |

反馈时提供工具版本、宿主/设备架构、所用命令、最早失败阶段和脱敏错误。不要提交账号、Cookie、令牌、私有备份或签名材料。

## 验证记录与待办

| 层级 | 当前记录 |
|---|---|
| 编译与打包 | 完整应用 x64 / ARM64 已构建；不等于设备运行验收 |
| x64 模拟器 | 官方 HarmonyOS 7 / API 26，以下流程为既有记录 |
| ARM64 真机 | 签名、安装、启动及功能仍需设备验证 |
| 特定设备能力 | 目录授权、PIN/生物认证成功、ARM PDF Kit、真实扫码、具体登录和在线翻译仍需分别验证 |

以下流程已在 API 26 x64 模拟器上运行。仓库内的探针使用生成的测试数据；私有验收数据必须留在仓库、构建输入、日志和截图之外。不得将用户备份上传到云设备或外部分析服务。

| 流程 | 已观察到的结果 |
|---|---|
| 书源与网络 | QuickJS 导入、搜索、详情、章节、图片请求头与像素、TLS 拒绝、Cookie、代理、取消及重启后数据保留均通过 |
| 阅读器 | 六种阅读模式、手势和音量键翻页、双击缩放、横竖屏旋转及进度保存均通过 |
| 下载 | 完整章节排队下载、重启后数据保留、离线图片解码及后台传输与恢复均通过 |
| 备份与 WebDAV | 导出/恢复及带认证的本地回环 PUT/GET 均通过，覆盖设置、书源数据、历史、收藏和 Cookie |
| 漫画导出 | CBZ、PDF、EPUB 及单独/合并 `.venera_comics` 的系统保存均通过；取消不会计为完成 |
| 图片与 OCR | 原生 PNG、图像增强着色器、真实 OCR 模型、本地翻译脚本及已保存翻译图片的重新绘制均通过 |
| 系统集成 | 文件选择器往返与取消、分享面板取消、WebView 存储、通知跳转、音量键和图标切换均通过 |

仍需设备验证的项目包括目录授权、已设置凭据的 PIN/生物认证成功流程、ARM PDF Kit 导入与渲染、真实二维码识别、具体书源登录及在线翻译服务。现有桥接和单元测试覆盖错误处理，不能替代这些设备检查。发布测试版本前，签名和面向用户的侧加载仍需单独验证。

## 附录：依赖实现细节

WebView 使用官方 CPF-Flutter/flutter_inappwebview OH 适配器，提交为 `389cf40dbb647f1df7272de5ea6b3401efe27a75`。可以通过 `-WebViewSource` 提供现有的干净检出目录，也可以让准备步骤从 GitCode 获取该提交。只有 Git 跟踪的源码会复制到 `.dart_tool/ohos`；公共 Flutter 封装和接口保持原有锁定版本。本地补丁覆盖接口兼容、初始请求顺序、HttpOnly 删除、存储隔离与键转义、SSL 错误报告，并保留浏览器的 TLS、来源和网络边界。准备完成后，SDK 的插件生成器会注册原生适配器。不会修改源检出目录或共享 Pub 缓存。

SQLite 仅由 OHOS CMake 工程构建，使用官方 3.54.1 合并源码及其 [公布的 SHA3-256 摘要](https://www.sqlite.org/download.html)。该归档不属于 Git 依赖，也不受 pub 锁文件覆盖；校验官方摘要用于发现下载源码被替换或损坏。不会向共享 Flutter 资源或其他平台构建加入 SQLite 二进制文件。现有平台插件引用的旧版 3.52.0 源码已被上游撤回，新平台不复用该版本。

QuickJS、ZIP、7z 和 PNG 使用锁定依赖中已有的源码。`prepare_ohos.dart` 会将它们的 Dart 库与许可证复制到 `.dart_tool/ohos`，仅增加 OHOS 动态库加载分支。它会更新独立检出目录中生成的包配置，不修改共享 Pub 缓存。CMake 使用原始锁定的 C/C++ 源码，为 ARM64 和 x86_64 构建。

`build_ohos_rhttp.ps1` 使用 Cargo 的 `--locked` 参数及官方 SDK 的 Clang，将锁定的 rhttp 包内 Rust 源码编译为两个 OHOS 目标。HTTP/3 保持启用。生成的库仅复制到 `ohos/entry/libs`，不修改共享 Pub 缓存或 Cargo.lock。OHOS 加载器会显式打开此库，其他平台保持原有初始化流程。

`build_ohos_onnx.ps1` 使用微软提交 `f217402897f40ebba457e2421bc0a4702771968e` 构建 ONNX Runtime 1.22.0，并使用 Eigen 官方 GitLab 仓库锁定的提交 `1d8b82b0740839c0de7f1242a3585e3390ff5f33`。首次构建会将这些 Git 源码获取到 `.dart_tool/ohos/sources`。可以在主构建脚本中通过 `-OnnxSource` 和 `-EigenSource` 提供现有检出目录。除 `tool/ohos/onnxruntime.patch` 外的源码修改会被拒绝。该补丁处理缺失的 pthread 亲和性及编译器特性声明；CPUINFO 被禁用，完整 CPU 算子集保持启用。上游依赖下载检查和 TLS 验证保持启用。相关库及其许可证说明仅打包到 OHOS 目标中。

脚本严格使用 `pubspec.lock`，仅修改进程环境变量，并在结束后恢复。每次 `pub get` 后都需要运行准备步骤；构建脚本会依次执行这两步。上游 Dart 原生钩子目前会将 OHOS 识别为 Linux；实验性构建会禁用这些代码资源，改用鸿蒙工具链构建支持的库。PDF 在支持的设备上使用官方系统 Kit，不使用 Linux PDFium 二进制库。不得通过关闭 TLS 验证、应用锁检查或签名要求来绕过缺失的平台实现。

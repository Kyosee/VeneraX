# VeneraX 鸿蒙开发

中文 | [English](harmonyos.en.md)

VeneraX 的实验性鸿蒙适配。完整应用已能为 ARM64 和 x64 构建；运行验证目前使用官方 x64 手机模拟器。目录访问、身份认证、原生 PDF 渲染及签名后的真机安装仍需在合适设备上验证。预览版提供未签名的 ARM64 release HAP，安装到手机前需要针对设备签名。参见 [预览版安装说明与限制](harmonyos-testing.md)。调试探针仅供本地开发，不作为发布附件。

## 独立工作目录

为鸿蒙使用单独检出的项目目录。两套 Flutter SDK 都会写入 `.dart_tool/package_config.json` 和生成的插件文件，因此在其他平台同时构建时，仅切换 Flutter 可执行文件并不足以隔离环境。现有平台继续使用标准 Flutter 3.44.3。

已验证的 OH SDK 为 CPF-Flutter `3.44.9+ohos-1.0.0-beta`，提交 `744cbb4f08e577787774c04033cc19a9d318d0d2`（Dart 3.12.2）。这是 [华为文档](https://developer.huawei.com/consumer/cn/doc/guidebook/solution-0000002784651007/) 链接的适配项目，并非 Google 上游 Flutter 发布版，可从 [CPF-Flutter/flutter_flutter](https://gitcode.com/CPF-Flutter/flutter_flutter) 获取。当前版本属于开发候选版，不代表稳定版承诺。

从华为官网下载 DevEco Studio。已验证环境为 DevEco 26.0.0.865、API 26 SDK 和 HarmonyOS 7 x86_64 手机模拟器。以下操作均在独立的项目目录中执行。

先通过官方 rustup 安装 Rust 1.85.1 及其 OHOS 编译目标：

```powershell
rustup toolchain install 1.85.1
rustup target add x86_64-unknown-linux-ohos aarch64-unknown-linux-ohos --toolchain 1.85.1
```

```powershell
./tool/build_ohos.ps1 -FlutterSdk D:/dev/tools/flutter_ohos `
  -DevEcoStudio 'D:/Program Files/Huawei/DevEco Studio'
```

上述命令会为 x64 构建 debug 模式的完整 `lib/main.dart` 应用。添加 `-Target tool/ohos_smoke.dart` 可构建独立的启动验证探针。使用 SDK 自带的 `hdc` 安装 `build/ohos/hap/entry-default-unsigned.hap`，然后启动 `com.github.kyosee.venera` / `EntryAbility`。该探针检查沙箱目录、包信息、文件读写、SQLite WAL、独立 isolate 中的 QuickJS 值与 Promise、Unicode ZIP 条目、7z 解压及 PNG 像素往返处理。重启后，启动计数应增加。探针持久数据仅写入应用沙箱内专用的 `ohos_smoke.db`。

构建手机预览版时，使用 `-Target lib/main.dart -TargetPlatform ohos-arm64 -BuildMode release`。原生编译和打包会遵循所选 ABI。默认构建不签名；只有在 DevEco Studio 配置自己的有效签名身份后，显式传入 `-CodeSign` 才会签名。探针使用独立入口，验证结束后应重新构建并安装完整应用。

使用 `-Target tool/ohos_network_smoke.dart` 运行 HTTP 探针。它在设备上启动本地服务，验证 DNS、重定向、Cookie、流、工作 isolate、应用的 Dio 适配器、取消、超时及 HTTP 代理。测试专用证书用于验证默认拒绝、显式本地信任和主机名不匹配时的拒绝行为，不改变系统或应用的信任设置。

使用 `-Target tool/ohos_onnx_smoke.dart`，通过应用的 FFI 绑定验证 ONNX CPU 推理。覆盖工作 isolate、Unicode 模型文件名、输出形状、重复运行与会话、无效输入及贪心解码。这只验证运行时；OCR 模型及完整翻译流程仍需单独进行应用层验证。

使用 `-Target tool/ohos_reader_smoke.dart` 验证实际书源和下载流程，测试使用自包含的本地回环漫画源与生成的图片。覆盖书源导入与重载、QuickJS 网络搜索、详情、章节、图片请求头与解码像素、后台历史记录写入、章节排队下载，以及关闭服务后的离线读取。强制停止应用后再次启动，确认书源、进度和下载内容能跨进程保留。所有探针数据均放在独立的 `ohos_reader_probe` 目录中。此探针不验证阅读器手势、后台恢复或同步。

使用 `-Target tool/ohos_reader_ui_smoke.dart`，以生成的页面验证正式阅读器的六种阅读模式、音量键翻页、进度保存及图像增强着色器。它使用阅读器探针的独立数据目录。交互效果需要单独检查，编译结果不能替代交互验证。

使用 `-Target tool/ohos_backup_smoke.dart`，在新建的临时目录中验证完整的 `.venera` 备份往返流程。它通过本地带认证的 WebDAV 服务和正式 RHttpAdapter 上传、下载备份，修改测试数据后恢复脚本、设置、历史、收藏和 Cookie。它不会配置远程同步账号，也不会向正常应用数据目录恢复内容。

使用 `-Target tool/ohos_webview_smoke.dart` 运行 WebView 探针。覆盖初始自定义请求头与重定向、JavaScript 返回值、原生与 HttpOnly Cookie（含删除）、local/session storage、恶意存储键、来源隔离、重载、自定义/直连/系统代理切换，以及拒绝不受信任的 TLS 证书。测试只使用本地服务，不使用用户账号。探针通过不代表所有书源的登录或反爬流程都已验证。

使用 `-Target tool/ohos_system_smoke.dart` 验证电量、省电状态、网络连接方法与事件、保持屏幕唤醒请求、系统代理及可用的认证类型。认证桥接会在应用进入后台时取消认证，并且只接受官方定义的成功结果。当前模拟器未设置认证凭据；PIN 或生物认证成功流程仍需在合适设备上验证。

使用 `-Target tool/ohos_file_smoke.dart`，交互验证文件导出/导入往返流程及选择器取消操作。分享测试会打开系统面板；应直接取消，不选择接收方。持久目录授权及接收外部分享的文本/链接采用独立实现；文件往返测试和模拟桥接测试均不能证明所有设备都支持目录选择。

官方 API 26 手机模拟器目前声明支持文件夹选择，但进入目录后没有完成选择的操作入口。使用文档规定的 FILE/FOLDER 选项编写独立原生 UIAbility，也能复现该行为。目录导入和自定义存储路径仍需在选择器可用的合适设备上验证授权目录的往返访问。鸿蒙漫画导出会为每个生成的 CBZ、PDF、EPUB 或 `.venera_comics` 文件打开系统保存对话框。取消会停止任务；保存失败不会计为导出完成。合并漫画归档只使用一次保存对话框。

Scan Kit 提供系统二维码扫描器；已验证界面的打开与取消。通知携带的 Want 在冷启动和热启动时均可将完整应用引导至下载及任务页面。后台桥接会让活动下载和 WebDAV 请求共享一个官方数据传输任务，按实际进度更新，并在最后一个请求结束时释放任务。`tool/ohos_background_smoke.dart` 验证进入后台后的真实并发 HTTP 传输、中断与恢复，以及通知移除。本地压缩和 OCR 不会申请网络后台任务。「省流」会在恢复前台及正常使用期间处理待保存的变更，不保证无限制的后台打包或上传。

API 26 的桌面图标切换使用系统包管理器。启动时会检查 API 是否实际可用，以及所有已配置的图标预设，再决定是否显示设置项。`prepare_ohos.dart` 仅使用项目现有 PNG 生成 OHOS 图标资源；修改图标素材后，可用 `dart tool/prepare_ohos_icons.dart` 刷新资源，无需重新准备依赖。较早的系统保持默认图标。

`-Target tool/ohos_pdf_smoke.dart` 通过官方 PDF Kit 验证 PDF 转换。华为不支持在 x86 模拟器上使用此 Kit；原生渲染验证需要 ARM 模拟器或真机。生命周期检查可在本地运行 `node --test test/ohos/pdf_bridge_test.cjs`；Dart 端的导入清理逻辑由 OH Flutter SDK 下的 `test/ohos_pdf_import_test.dart` 覆盖。这些测试不能替代原生 PDF 渲染验证。

ARM64 编译通过不代表真机验证通过。设备签名与用户侧加载仍未验证。不得将开发者私钥或绑定设备的 Profile 当作通用安装方案分发。

## 验证覆盖范围

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

## 依赖

WebView 使用官方 CPF-Flutter/flutter_inappwebview OH 适配器，提交为 `389cf40dbb647f1df7272de5ea6b3401efe27a75`。可以通过 `-WebViewSource` 提供现有的干净检出目录，也可以让准备步骤从 GitCode 获取该提交。只有 Git 跟踪的源码会复制到 `.dart_tool/ohos`；公共 Flutter 封装和接口保持原有锁定版本。本地补丁覆盖接口兼容、初始请求顺序、HttpOnly 删除、存储隔离与键转义、SSL 错误报告，并保留浏览器的 TLS、来源和网络边界。准备完成后，SDK 的插件生成器会注册原生适配器。不会修改源检出目录或共享 Pub 缓存。

SQLite 仅由 OHOS CMake 工程构建，使用官方 3.54.1 合并源码及其 [公布的 SHA3-256 摘要](https://www.sqlite.org/download.html)。该归档不属于 Git 依赖，也不受 pub 锁文件覆盖；校验官方摘要用于发现下载源码被替换或损坏。不会向共享 Flutter 资源或其他平台构建加入 SQLite 二进制文件。现有平台插件引用的旧版 3.52.0 源码已被上游撤回，新平台不复用该版本。

QuickJS、ZIP、7z 和 PNG 使用锁定依赖中已有的源码。`prepare_ohos.dart` 会将它们的 Dart 库与许可证复制到 `.dart_tool/ohos`，仅增加 OHOS 动态库加载分支。它会更新独立检出目录中生成的包配置，不修改共享 Pub 缓存。CMake 使用原始锁定的 C/C++ 源码，为 ARM64 和 x86_64 构建。

`build_ohos_rhttp.ps1` 使用 Cargo 的 `--locked` 参数及官方 SDK 的 Clang，将锁定的 rhttp 包内 Rust 源码编译为两个 OHOS 目标。HTTP/3 保持启用。生成的库仅复制到 `ohos/entry/libs`，不修改共享 Pub 缓存或 Cargo.lock。OHOS 加载器会显式打开此库，其他平台保持原有初始化流程。

`build_ohos_onnx.ps1` 使用微软提交 `f217402897f40ebba457e2421bc0a4702771968e` 构建 ONNX Runtime 1.22.0，并使用 Eigen 官方 GitLab 仓库锁定的提交 `1d8b82b0740839c0de7f1242a3585e3390ff5f33`。首次构建会将这些 Git 源码获取到 `.dart_tool/ohos/sources`。可以在主构建脚本中通过 `-OnnxSource` 和 `-EigenSource` 提供现有检出目录。除 `tool/ohos/onnxruntime.patch` 外的源码修改会被拒绝。该补丁处理缺失的 pthread 亲和性及编译器特性声明；CPUINFO 被禁用，完整 CPU 算子集保持启用。上游依赖下载检查和 TLS 验证保持启用。相关库及其许可证说明仅打包到 OHOS 目标中。

脚本严格使用 `pubspec.lock`，仅修改进程环境变量，并在结束后恢复。每次 `pub get` 后都需要运行准备步骤；构建脚本会依次执行这两步。上游 Dart 原生钩子目前会将 OHOS 识别为 Linux；实验性构建会禁用这些代码资源，改用鸿蒙工具链构建支持的库。PDF 在支持的设备上使用官方系统 Kit，不使用 Linux PDFium 二进制库。不得通过关闭 TLS 验证、应用锁检查或签名要求来绕过缺失的平台实现。

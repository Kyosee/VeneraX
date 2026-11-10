# VeneraX Apple 小组件

iOS 15.1 起、macOS 14 起提供最近阅读、正在追更、漫画更新、本地漫画四种 WidgetKit 小组件，支持小、中、大尺寸。小尺寸点击进入第一项；中、大尺寸可分别点击条目，标题进入对应列表。内容由主应用更新，WidgetKit 决定实际刷新时机。

共享实现位于 `apple/Widgets/`。两个 Xcode 工程均包含 `ReadingWidgets` 扩展，并由 `Runner` 嵌入。主应用仍使用 `io.github.kyosee.venera`，扩展使用 `io.github.kyosee.venera.ReadingWidgets`。扩展版本来自 Flutter 生成的构建配置，与主应用一致。

## 签名和共享容器

主应用与扩展必须拥有相同的 App Group：`group.io.github.kyosee.venera`。开发者需要在实际签名账户中配置这一权限，并为两个 bundle identifier 提供相应签名；macOS 两个目标同时保留沙盒设置。

仓库现有 iOS CI 生成未签名 IPA，macOS 构建允许无开发者证书。能生成 IPA/DMG 不代表小组件已具备共享容器权限。侧载、重新签名、替换 bundle identifier 或使用不同签名账户时，必须验证扩展被保留且两端 App Group entitlement 与最终 provisioning 匹配。不同侧载工具和账户的能力不同，不能保证所有侧载方式均可使用小组件。

原生桥接在共享容器不可用时返回 `WIDGET_APP_GROUP_UNAVAILABLE`；目录或写入权限错误返回 `WIDGET_UPDATE_FAILED`。这些错误由主应用处理，扩展显示打开应用的提示，不回退读取其他目录。

## 数据和隐私

`venera/reading_widget` 通道支持：

| 方法 | 参数 | 返回 |
|---|---|---|
| `hasWidgets` | `history` / `following` / `updates` / `local` | 当前已添加的匹配 kind 是否存在 |
| `update` | JSON 字符串，含 `kind`、`locked`、`title`、`emptyText`、`subtitle`、`items` | 成功返回空值，失败返回平台错误 |

每种 kind 的快照独立保存。原生端依据 kind、漫画 ID 和 type 构造链接，不采信传入的 URI。仅允许把主应用 support 目录下 `reading_widget_covers/<UUID>.png` 缩略图复制到 App Group 的 `widget_covers`；快照保存相对路径，不包含图源凭据或远程图片 URL。删除旧封面前检查所有 kind 的引用。

锁定更新先原子保存全局隐私状态，再清空四类快照和未引用的封面。扩展 provider 和视图都检查隐私状态，敏感内容同时标记 `privacySensitive`。隐私文件缺失或损坏时隐藏内容。进程在清空中断后，下次解锁先清空其他 kind 的旧快照，再发布当前内容。

WidgetKit 的调度和系统已缓存画面由系统控制，`reloadTimelines` 不保证立即撤回此前的截图；涉及应用锁时需要实际设备验收这个系统边界。

## 验证

Windows 可执行 `node --test test/apple_widgets_test.cjs`，检查两份 Xcode 对象图、扩展嵌入和依赖、源码归属、版本、最低系统版本、App Group、URL 注册及三语资源。

`ios/RunnerTests/RunnerTests.swift` 包含共享存储的 XCTest：锁定清空、清空中断后的解锁、跨 kind 封面引用、非法路径、损坏隐私文件和包含特殊字符的点击链接。需要在 Mac/Xcode 的 RunnerTests 中运行；Windows 静态检查不会执行这些 Swift 测试。

交付前还需在 Apple 环境验证：

- 使用 Xcode 编译主应用和扩展，检查 `.app/PlugIns`（macOS 为 `.app/Contents/PlugIns`）包含 `ReadingWidgets.appex`。
- 检查最终签名和 App Group 容器读写，尤其是重签后的 IPA。
- 添加四种小组件，验证三种尺寸、简体/繁体/英文、浅色/深色和动态字体。
- 验证冷启动、后台唤醒、锁定后点击、无数据、离线封面和锁定清空。

这组静态检查不能替代 Apple SDK 编译、签名和桌面运行验收。

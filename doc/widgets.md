# 桌面卡片 / Home-screen widgets

先打开一次 VeneraX，再从系统的小组件或服务卡片列表中选择 VeneraX。

| 卡片 | 显示内容 | 点击标题 |
|---|---|---|
| 最近阅读 | 可见的最近阅读记录和进度 | 阅读历史 |
| 追更 | 追更范围内的漫画，优先显示有更新的漫画 | 全部追更漫画 |
| 有更新 | 尚未读过的新更新，以及最近检查时间 | 更新列表 |
| 本地漫画 | 最近入库且本机文件可用的漫画 | 本地漫画 |

点击漫画继续阅读；本机已有的内容优先离线打开。删除、隐藏或屏蔽后的失效入口会返回相应列表。开启应用锁后，所有卡片只显示打开应用的入口。

- Android：长按桌面空白处 → 小组件 → VeneraX。每类提供封面和列表两种样式，列表可调整尺寸，最多显示六本。
- HarmonyOS：从桌面 VeneraX 图标的服务卡片入口选择卡片。2×2 显示一本，2×4 显示两本，4×4 最多显示四本。
- iPhone/iPad：编辑主屏幕 → 添加小组件 → VeneraX。支持小、中、大尺寸。
- macOS：编辑小组件 → VeneraX。支持桌面和通知中心的小、中、大尺寸。Apple 两端的小组件需要主应用与扩展具有匹配的签名和共享权限，侧载包是否支持取决于实际签名方式；详见 [Apple 配置说明](widgets-apple.md)。

应用会预备前两本封面，添加后再次打开应用可补齐更多封面。阅读、调整追更范围、修改隐私设置，以及重新打开应用时都会更新内容；鸿蒙现有后台追更任务完成后也会刷新追更卡片。Apple 系统决定实际刷新时间，卡片不承诺实时更新。没有封面或离线时显示占位图。Windows、Linux 本轮不提供系统小组件。

## English

Open VeneraX once, then add it from your system's widget or service-card picker.

| Widget | Content | Header destination |
|---|---|---|
| Recent reading | Visible reading history and progress | Reading history |
| Following | Followed comics, with updates first | All followed comics |
| New updates | Unread updates and the latest check time | Updates |
| Local comics | Recent additions with available local files | Local library |

Tap a comic to continue reading, preferring available offline files. Removed, hidden or blocked entries fall back to their list. Enabling the app lock hides titles and covers on every widget.

Android offers cover and resizable list styles, with up to six comics. HarmonyOS offers 2×2, 2×4 and 4×4 cards showing one, two and up to four comics respectively. iOS/iPadOS and macOS use small, medium and large WidgetKit widgets. Apple widgets require matching app/extension signing and shared-container permissions; support depends on the actual signing or sideloading method.

The app prepares two covers before the first widget is added. Open it after adding a widget to load additional covers. Reading, follow-scope changes, privacy changes and reopening the app refresh widget data. HarmonyOS background follow checks also refresh the following widgets. Apple controls when updates appear; widgets do not promise real-time refreshes. Missing covers use placeholders. Windows and Linux widgets are deferred.

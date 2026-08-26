part of 'settings_page.dart';

class AppSettings extends StatefulWidget {
  const AppSettings({super.key});

  @override
  State<AppSettings> createState() => _AppSettingsState();
}

class _AppSettingsState extends State<AppSettings> {
  String _appLockTypeName(AppLockType type) {
    return switch (type) {
      AppLockType.biometric => "Biometric".tl,
      AppLockType.pin => "PIN".tl,
      AppLockType.password => "Password".tl,
      AppLockType.pattern => "Pattern".tl,
    };
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      scrollbarTopPadding: context.padding.top + 56,
      slivers: [
        SliverAppbar(title: Text("App".tl)),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('appAppearanceGroup'),
          initiallyExpanded: true,
          icon: Icons.color_lens,
          title: "Appearance".tl,
          children: [
            SelectSetting(
              title: "Theme Mode".tl,
              settingKey: "theme_mode",
              optionTranslation: {
                "system": "System".tl,
                "light": "Light".tl,
                "dark": "Dark".tl,
              },
              onChanged: () async {
                App.forceRebuild();
              },
            ),
            SelectSetting(
              title: "Theme Color".tl,
              settingKey: "color",
              optionTranslation: {
                "system": "System".tl,
                "red": "Red".tl,
                "pink": "Pink".tl,
                "purple": "Purple".tl,
                "green": "Green".tl,
                "orange": "Orange".tl,
                "blue": "Blue".tl,
              },
              onChanged: () async {
                await App.init();
                App.forceRebuild();
              },
            ),
            if (App.isAndroid)
              _SwitchSetting(
                title: "Predictive Back Animation".tl,
                subtitle: "Page follows the back gesture as you drag".tl,
                settingKey: "enablePredictiveBack",
                onChanged: () {
                  App.forceRebuild();
                },
              ),
            ListTile(
              title: Text("Home Page Layout".tl),
              subtitle: Text("Reorder or hide home sections".tl),
              leading: const Icon(Icons.dashboard_customize_outlined),
              trailing: const Icon(Icons.arrow_right),
              onTap: () {
                context.to(() => const HomeLayoutSettings());
              },
            ),
            ListTile(
              title: Text("Image Favorites Tabs".tl),
              subtitle: Text(
                "Reorder or hide the Tags / Authors / Comics tabs".tl,
              ),
              leading: const Icon(Icons.tab_outlined),
              trailing: const Icon(Icons.arrow_right),
              onTap: () {
                context.to(() => const ImageFavoritesTabsSettings());
              },
            ),
            if (LauncherIconService.isSupported)
              ListTile(
                title: Text("App Icon".tl),
                subtitle: Text(
                  LauncherIconService.isWindowIconOnly
                      ? "Choose the window and taskbar icon".tl
                      : "Choose the home screen icon".tl,
                ),
                leading: const Icon(Icons.apps_outlined),
                trailing: const Icon(Icons.arrow_right),
                onTap: () {
                  context.to(() => const LauncherIconSettings());
                },
              ),
          ],
        ).toSliver(),
        if (App.isAndroid)
          _SettingsExpansionTile(
            expansionKey: const PageStorageKey('appBackgroundGroup'),
            initiallyExpanded: true,
            icon: Icons.battery_saver,
            title: "Background".tl,
            children: const [_BatteryOptimizationSetting()],
          ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('appUserGroup'),
          initiallyExpanded: true,
          icon: Icons.person_outline,
          title: "User".tl,
          children: [
            SelectSetting(
              title: "Language".tl,
              settingKey: "language",
              optionTranslation: const {
                "system": "System",
                "zh-CN": "简体中文",
                "zh-TW": "繁體中文",
                "en-US": "English",
              },
              onChanged: () {
                App.forceRebuild();
              },
            ),
            if (!App.isLinux) ...[
              _SwitchSetting(
                title: "Authorization Required".tl,
                settingKey: "authorizationRequired",
                onChanged: () async {
                  var enabled = appdata.settings['authorizationRequired'];
                  if (enabled) {
                    // Just switched on: pick an unlock method and record its
                    // credential. Revert if the user backs out or setup fails.
                    var ok = await showAppLockSetup(context);
                    if (!ok) {
                      setState(() {
                        appdata.settings['authorizationRequired'] = false;
                      });
                      appdata.saveData();
                      return;
                    }
                  }
                  setState(() {});
                },
              ),
              if (appdata.settings['authorizationRequired'] == true)
                _CallbackSetting(
                  title: "Unlock method".tl,
                  subtitle: _appLockTypeName(AppLock.type),
                  actionTitle: "Change".tl,
                  callback: () async {
                    var ok = await showAppLockSetup(context);
                    if (ok) setState(() {});
                  },
                ),
            ],
          ],
        ).toSliver(),
        if (App.isWindows)
          _SettingsExpansionTile(
            expansionKey: const PageStorageKey('appWindowGroup'),
            initiallyExpanded: true,
            icon: Icons.web_asset,
            title: "Window".tl,
            children: [
              _SwitchSetting(
                title: "Minimize to tray".tl,
                settingKey: "minimizeToTray",
                onChanged: () {
                  TrayController.instance.setEnabled(
                    appdata.settings["minimizeToTray"] == true,
                  );
                },
              ),
            ],
          ).toSliver(),
      ],
    );
  }
}

/// 电池优化豁免设置项（仅 Android）。展示当前豁免状态，未豁免时提供一键请求；
/// 系统请求对话框被 ROM 屏蔽时退回到设置列表。回到前台时刷新状态，方便用户在
/// 系统设置里改完开关返回即时看到结果。
class _BatteryOptimizationSetting extends StatefulWidget {
  const _BatteryOptimizationSetting();

  @override
  State<_BatteryOptimizationSetting> createState() =>
      _BatteryOptimizationSettingState();
}

class _BatteryOptimizationSettingState
    extends State<_BatteryOptimizationSetting> with WidgetsBindingObserver {
  bool? _ignoring;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final ignoring = await BatteryOptimization.instance.isIgnoring();
    if (mounted) {
      setState(() => _ignoring = ignoring);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ignoring = _ignoring;
    final subtitle = ignoring == null
        ? "Checking".tl
        : (ignoring
            ? "Battery optimization disabled".tl
            : "Battery optimization enabled, background tasks may be frozen".tl);
    return ListTile(
      title: Text("Ignore Battery Optimization".tl),
      subtitle: Text(subtitle),
      isThreeLine: ignoring == false,
      trailing: ignoring == true
          ? Icon(Icons.check_circle, color: context.colorScheme.primary)
          : Button.normal(
              onPressed: () async {
                await BatteryOptimization.instance.request();
                await _refresh();
              },
              child: Text("Allow".tl),
            ).fixHeight(28),
      onTap: ignoring == true
          ? null
          : () async {
              await BatteryOptimization.instance.request();
              await _refresh();
            },
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String logLevelToShow = "all";

  @override
  Widget build(BuildContext context) {
    var logToShow = logLevelToShow == "all"
        ? Log.logs
        : Log.logs.where((log) => log.level.name == logLevelToShow).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Logs".tl),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              final RelativeRect position = RelativeRect.fromLTRB(
                MediaQuery.of(context).size.width,
                MediaQuery.of(context).padding.top + kToolbarHeight,
                0.0,
                0.0,
              );
              showMenu(
                context: context,
                position: position,
                items: [
                  PopupMenuItem(
                    child: Text("all"),
                    onTap: () => setState(() => logLevelToShow = "all"),
                  ),
                  PopupMenuItem(
                    child: Text("info"),
                    onTap: () => setState(() => logLevelToShow = "info"),
                  ),
                  PopupMenuItem(
                    child: Text("warning"),
                    onTap: () => setState(() => logLevelToShow = "warning"),
                  ),
                  PopupMenuItem(
                    child: Text("error"),
                    onTap: () => setState(() => logLevelToShow = "error"),
                  ),
                ],
              );
            }),
            icon: const Icon(Icons.filter_alt_outlined),
          ),
          IconButton(
            onPressed: () => setState(() {
              final RelativeRect position = RelativeRect.fromLTRB(
                MediaQuery.of(context).size.width,
                MediaQuery.of(context).padding.top + kToolbarHeight,
                0.0,
                0.0,
              );
              showMenu(
                context: context,
                position: position,
                items: [
                  PopupMenuItem(
                    child: Text("Clear".tl),
                    onTap: () => setState(() => Log.clear()),
                  ),
                  PopupMenuItem(
                    child: Text("Disable Length Limitation".tl),
                    onTap: () {
                      Log.ignoreLimitation = true;
                      context.showMessage(
                        message: "Only valid for this run".tl,
                      );
                    },
                  ),
                  PopupMenuItem(
                    child: Text(
                      Log.verboseNetwork
                          ? "Stop Logging All Requests".tl
                          : "Log All Network Requests".tl,
                    ),
                    onTap: () {
                      var enable = !Log.verboseNetwork;
                      appdata.settings['verboseNetworkLog'] = enable;
                      Log.syncVerboseNetwork(enable);
                      appdata.saveData();
                      context.showMessage(
                        message: enable
                            ? "Recording every request. This uses more battery; turn it off when done."
                                .tl
                            : "Only failed requests are recorded now.".tl,
                      );
                    },
                  ),
                  PopupMenuItem(
                    child: Text("Export".tl),
                    onTap: () {
                      // Buffered lines would otherwise be missing from the file.
                      Log.flush();
                      saveLog(Log().toString());
                    },
                  ),
                ],
              );
            }),
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: ListView.builder(
        reverse: true,
        controller: ScrollController(),
        itemCount: logToShow.length,
        itemBuilder: (context, index) {
          index = logToShow.length - index - 1;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(16),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(logToShow[index].title),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Container(
                        decoration: BoxDecoration(
                          color: [
                            Theme.of(context).colorScheme.error,
                            Theme.of(context).colorScheme.errorContainer,
                            Theme.of(context).colorScheme.primaryContainer,
                          ][logToShow[index].level.index],
                          borderRadius: const BorderRadius.all(
                            Radius.circular(16),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(
                            logToShow[index].level.name,
                            style: TextStyle(
                              color: logToShow[index].level.index == 0
                                  ? Colors.white
                                  : Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(logToShow[index].content),
                  Text(
                    logToShow[index].time.toString().replaceAll(
                      RegExp(r"\.\w+"),
                      "",
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: logToShow[index].content),
                      );
                    },
                    child: Text("Copy".tl),
                  ),
                  const Divider(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void saveLog(String log) async {
    saveFile(data: utf8.encode(log), filename: 'log.txt');
  }
}

/// A user-facing group of settings that can be excluded from WebDAV sync.
///
/// The stored value is still the raw comma-joined key list the sync layer
/// consumes ([Appdata._disableSync] / syncdata.json); this just maps those
/// opaque keys onto a labeled, checkable category so users don't have to know
/// (or read the source for) internal field names.
class _SkipSyncCategory {
  const _SkipSyncCategory(this.label, this.description, this.keys);

  /// Translation key for the category name.
  final String label;

  /// Translation key for the one-line explanation.
  final String description;

  /// The setting keys this category toggles together.
  final List<String> keys;
}

/// The categories offered in the skip-sync picker. Only settings that actually
/// sync belong here — device-local ones (proxy, app lock, webdav creds, ...)
/// are already force-excluded in [Appdata._disableSync] and would be redundant.
const _skipSyncCategories = <_SkipSyncCategory>[
  _SkipSyncCategory(
    "Appearance",
    "Theme color, light/dark mode, comic tile layout",
    ["color", "theme_mode", "comicDisplayMode", "comicTileScale"],
  ),
  _SkipSyncCategory(
    "Reading Options",
    "Reader mode, page-turn, image enhance and other reading options",
    [
      "readerMode",
      "enableContinuousChapterReading",
      "readerScreenPicNumberForLandscape",
      "readerScreenPicNumberForPortrait",
      "enableTapToTurnPages",
      "reverseTapToTurnPages",
      "enableCustomTapZones",
      "tapZoneTop",
      "tapZoneBottom",
      "tapZoneLeft",
      "tapZoneRight",
      "enablePageAnimation",
      "autoPageTurningInterval",
      "enableLongPressToZoom",
      "longPressZoomPosition",
      "enableTurnPageByVolumeKey",
      "enableClockAndBatteryInfoInReader",
      "showPageNumberInReader",
      "showSingleImageOnFirstPage",
      "enableDoubleTapToZoom",
      "reverseChapterOrder",
      "showSystemStatusBar",
      "readerScrollSpeed",
      "readerCenterPageOnTurn",
      "readerPageSpacing",
      "comicListDisplayMode",
      "galleryFillScreen",
      "readerBackgroundColor",
      "readerNightModeFollowSystem",
      "readerNightModeColor",
      "readerNightModeIntensity",
      "enableReaderImageEnhance",
      "readerImageEnhanceStrength",
      "readerImageEnhanceClarity",
      "readerImageEnhanceContrast",
      "readerImageEnhanceVibrance",
      "limitImageWidth",
      "preloadImageCount",
      "showChapterComments",
      "commentsFontSize",
      "showChapterCommentsAtEnd",
    ],
  ),
  _SkipSyncCategory(
    "Explore",
    "Explore pages, categories, search options and content filters",
    [
      "explore_pages",
      "categories",
      "searchSources",
      "defaultSearchTarget",
      "autoAddLanguageFilter",
      "blockedWords",
      "blockedCommentWords",
      "showFavoriteStatusOnTile",
      "showHistoryStatusOnTile",
      "showReadLaterStatusOnTile",
    ],
  ),
  _SkipSyncCategory(
    "Favorites",
    "Favorite folders, sort order and quick-favorite options",
    [
      "favorites",
      "newFavoriteAddTo",
      "moveFavoriteAfterRead",
      "quickFavorite",
      "quickCollectImage",
      "autoFavoriteCover",
      "onClickFavorite",
      "localFavoritesFirst",
      "autoCloseFavoritePanel",
    ],
  ),
  _SkipSyncCategory(
    "Comic Source list",
    "The subscribed comic source list",
    ["comicSourceLibraries", "comicSourceListUrl"],
  ),
];

class _WebdavSetting extends StatefulWidget {
  const _WebdavSetting();

  @override
  State<_WebdavSetting> createState() => _WebdavSettingState();
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String url = "";
  String user = "";
  String pass = "";
  String disableSync = "";

  WebdavSyncMode syncMode = WebdavSyncMode.realtime;

  bool syncLocalComicImages = false;

  bool isTesting = false;

  bool isTestingConnection = false;

  @override
  void initState() {
    super.initState();
    if (appdata.settings['webdav'] is! List) {
      appdata.settings['webdav'] = [];
    }
    if (appdata.settings['disableSyncFields'].trim().isNotEmpty) {
      disableSync = appdata.settings['disableSyncFields'];
    }
    var configs = appdata.settings['webdav'] as List;
    if (configs.whereType<String>().length == 3) {
      url = configs[0];
      user = configs[1];
      pass = configs[2];
    }
    // Reads through the legacy-webdavAutoSync migration in DataSync.syncMode.
    // Still needed here: the QR share/scan and Save paths carry the mode even
    // though the mode/retention/proxy selectors now live in _WebdavSyncOptions.
    syncMode = DataSync().syncMode;
    syncLocalComicImages = appdata.settings['syncLocalComicImages'] ?? false;
  }

  /// True when every key of [category] is currently in the skip list.
  bool _isCategorySkipped(_SkipSyncCategory category) {
    final current = appdata.splitField(disableSync).toSet();
    return category.keys.every(current.contains);
  }

  int _skipSyncSelectedCount() {
    return _skipSyncCategories.where(_isCategorySkipped).length;
  }

  String _skipSyncSummary() {
    final selected =
        _skipSyncCategories.where(_isCategorySkipped).map((c) => c.label.tl);
    if (selected.isEmpty) {
      return "None".tl;
    }
    return selected.join("、");
  }

  /// Rebuilds [disableSync] from the checked categories plus any preserved
  /// unknown keys, then persists it. Called on every checkbox toggle so the
  /// choice survives even without tapping Save (parity with the mode/proxy
  /// selectors which also persist immediately).
  void _setCategorySkipped(_SkipSyncCategory category, bool skip) {
    final current = appdata.splitField(disableSync).toSet();
    if (skip) {
      current.addAll(category.keys);
    } else {
      current.removeAll(category.keys);
    }
    setState(() {
      disableSync = current.join(", ");
      appdata.settings['disableSyncFields'] = disableSync;
      appdata.saveData();
    });
  }

  void _editSkipSyncFields() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return ContentDialog(
              title: "Skip Sync Items".tl,
              content: SizedBox(
                // Cap to the viewport so the fixed-width content never
                // overflows the dialog on narrow phones (ContentDialog wraps
                // this in an IntrinsicWidth, so a bare 400 could exceed the
                // available width). A plain min() avoids a LayoutBuilder,
                // which crashes inside that IntrinsicWidth.
                width: context.width < 420 ? context.width - 48 : 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Chosen categories stay on this device only: they are never uploaded, and won't be overwritten by other devices."
                          .tl,
                      style: TextStyle(
                        fontSize: 13,
                        color: context.colorScheme.outline,
                      ),
                    ).paddingHorizontal(8),
                    const SizedBox(height: 8),
                    ..._skipSyncCategories.map((category) {
                      return CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _isCategorySkipped(category),
                        title: Text(category.label.tl),
                        subtitle: Text(
                          category.description.tl,
                          style: const TextStyle(fontSize: 12),
                        ),
                        onChanged: (v) {
                          _setCategorySkipped(category, v ?? false);
                          // Reflect the toggle in this dialog and in the field
                          // summary behind it.
                          setDialogState(() {});
                        },
                      );
                    }),
                  ],
                ),
              ),
              actions: [
                Button.filled(
                  onPressed: dialogContext.pop,
                  child: Text("Done".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Shows the current config as a PIN-encrypted QR code for another device to
  /// scan. Available on every platform (the "generate" side, incl. desktop).
  void _showConfigQr() {
    if (url.trim().isEmpty || user.trim().isEmpty || pass.isEmpty) {
      context.showMessage(
        message: "Fill in URL, username and password first".tl,
      );
      return;
    }
    showSyncConfigQrDialog(
      context,
      SyncConfigPayload(
        url: url.trim(),
        user: user.trim(),
        pass: pass,
        // The payload keeps its legacy boolean shape so older installs can
        // scan it; the three-way tier collapses to "any automation vs none".
        autoSync: syncMode != WebdavSyncMode.manual,
        disableSyncFields: disableSync,
      ),
    );
  }

  /// Probes the WebDAV credentials the form currently holds (which may include
  /// unsaved edits or a fresh QR scan) and reports whether the server is
  /// reachable and the login is accepted, without saving or syncing anything.
  void _testConnection() async {
    if (url.trim().isEmpty || user.trim().isEmpty || pass.isEmpty) {
      context.showMessage(
        message: "Fill in URL, username and password first".tl,
      );
      return;
    }
    setState(() {
      isTestingConnection = true;
    });
    var result = await DataSync().testConnection(
      url: url,
      user: user,
      pass: pass,
    );
    if (!mounted) return;
    setState(() {
      isTestingConnection = false;
    });
    if (result.error) {
      context.showMessage(
        message: "Connection failed: @error"
            .tlParams({"error": result.errorMessage ?? ""}),
      );
    } else {
      context.showMessage(message: "Connection successful".tl);
    }
  }

  /// Scans another device's QR code, fills the form with the recovered config,
  /// and applies it immediately (no separate Save tap needed). Mobile only —
  /// the button is hidden on desktop.
  void _scanConfigQr() async {
    final payload = await scanAndDecodeSyncConfig(context);
    if (payload == null || !mounted) return;
    setState(() {
      url = payload.url;
      user = payload.user;
      pass = payload.pass;
      // Legacy boolean → tier: false was "nothing automatic".
      syncMode = payload.autoSync
          ? WebdavSyncMode.realtime
          : WebdavSyncMode.manual;
      disableSync = payload.disableSyncFields;
    });
    // Persist and sync right away — the scan already carries a complete,
    // validated config, so requiring a manual Save afterwards is redundant.
    await _saveConfig();
  }

  /// Persists the WebDAV config the form currently holds, then runs a
  /// best-effort initial sync (unless the tier is manual). Pops the settings
  /// page when done. Shared by the Save button and the QR-scan handler.
  Future<void> _saveConfig() async {
    if (url.trim().isEmpty && user.trim().isEmpty && pass.trim().isEmpty) {
      appdata.settings['webdav'] = [];
      // Persist the tier the form holds (it may come from a QR scan that is
      // only applied on Save). With no config the tier stays inert —
      // everything gates on isConfigured — and activates once a config is
      // added (#67 semantics).
      DataSync().setSyncMode(syncMode);
      appdata.saveData();
      context.showMessage(message: "Saved".tl);
      App.rootPop();
      return;
    }

    final config = [url.trim(), user.trim(), pass];
    appdata.settings['webdav'] = config;
    appdata.settings['disableSyncFields'] = disableSync;
    DataSync().setSyncMode(syncMode);

    // Persisting the configuration always succeeds at this point. The initial
    // sync below is best-effort: its result is only surfaced as a hint and
    // never rolls the config back.
    appdata.saveData();

    if (syncMode == WebdavSyncMode.manual) {
      // No automatic uploads wanted; skip the immediate test sync too — the
      // user triggers everything by hand.
      context.showMessage(message: "Saved".tl);
      App.rootPop();
      return;
    }

    setState(() {
      isTesting = true;
    });
    // Use syncData() instead of uploadData() so a fresh install with no local
    // data downloads the remote backup instead of being blocked by the
    // empty-data upload guards.
    var syncResult = await DataSync().syncData();
    if (!mounted) return;
    setState(() {
      isTesting = false;
    });
    if (syncResult.error) {
      context.showMessage(
        message: "Saved, but sync failed: @error"
            .tlParams({"error": syncResult.errorMessage ?? ""}),
      );
    } else {
      context.showMessage(message: "Saved".tl);
    }
    App.rootPop();
  }

  void _showRemoteBackupList(BuildContext context) async {
    // The settings page lives inside the nested navigator created by
    // showPopUpWidget, but showDialog pushes onto the ROOT navigator by
    // default. Pop the same (root) navigator we pushed the spinner onto,
    // otherwise the spinner is never dismissed and resurfaces as a stuck
    // loading dialog after later dialogs are closed.
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    showDialog(
      context: context,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );
    var result = await DataSync().listRemoteBackups();
    if (context.mounted) rootNavigator.pop();
    if (result.error) {
      if (context.mounted) {
        context.showMessage(message: result.errorMessage!);
      }
      return;
    }
    var backups = result.data;
    if (backups.isEmpty) {
      if (context.mounted) {
        context.showMessage(message: "No backups found".tl);
      }
      return;
    }
    if (!context.mounted) return;
    var selected = await showDialog<RemoteBackupInfo>(
      context: context,
      builder: (ctx) => _RemoteBackupListDialog(backups: backups),
    );
    if (selected == null || !context.mounted) return;
    _confirmAndDownload(context, selected);
  }

  void _confirmAndDownload(BuildContext context, RemoteBackupInfo backup) {
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: "Confirm Download".tl,
        content: Text(
          "This will overwrite all local data. Continue?".tl,
        ),
        actions: [
          Button.filled(
            onPressed: () async {
              Navigator.of(ctx).pop();
              var result =
                  await DataSync().downloadSpecificBackup(backup.fileName);
              if (context.mounted) {
                if (result.error) {
                  context.showMessage(message: result.errorMessage!);
                } else {
                  context.showMessage(message: "Download successful".tl);
                }
              }
            },
            child: Text("Confirm".tl),
          ),
          Button.outlined(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Cancel".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Webdav",
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "URL",
                hintText: "A valid WebDav directory URL".tl,
                border: OutlineInputBorder(),
              ),
              controller: TextEditingController(text: url),
              onChanged: (value) => url = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Username".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: user),
              onChanged: (value) => user = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Password".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: pass),
              onChanged: (value) => pass = value,
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _editSkipSyncFields,
              borderRadius: BorderRadius.circular(4),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: "Skip Sync Items (Optional)".tl,
                  helperText:
                      "Keep chosen categories device-specific; they won't sync."
                          .tl,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  suffixIcon: const Icon(Icons.chevron_right),
                ),
                child: Text(
                  _skipSyncSummary(),
                  style: TextStyle(
                    color: _skipSyncSelectedCount() == 0
                        ? Theme.of(context).hintColor
                        : null,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Button.outlined(
                    onPressed: _showConfigQr,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.qr_code_2, size: 18),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            "Show Config QR".tl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (App.isAndroid || App.isIOS) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Button.outlined(
                      onPressed: _scanConfigQr,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.qr_code_scanner, size: 18),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              "Scan to Import".tl,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: Button.outlined(
                isLoading: isTestingConnection,
                onPressed: _testConnection,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.wifi_tethering, size: 18),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        "Test Connection".tl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: Text("${"Sync Local Comic Images".tl}（${"Experimental".tl}）"),
              subtitle: Text(
                "开启后将通过WebDAV同步漫画图片文件。注意：这会导致同步数据量显著增大且同步速度变慢。关闭时仅同步漫画记录，图包需在各设备手动下载或导入。".tl,
                style: const TextStyle(fontSize: 12),
              ),
              value: syncLocalComicImages,
              onChanged: (v) {
                if (v) {
                  showDialog(
                    context: context,
                    builder: (ctx) => ContentDialog(
                      title: "Experimental Feature".tl,
                      content: Text(
                        "This feature is experimental. Syncing comic images may consume significant network bandwidth and storage space on your WebDAV server. Please ensure you have sufficient quota and a stable connection.".tl,
                      ).paddingHorizontal(16).paddingVertical(8),
                      actions: [
                        Button.text(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text("Cancel".tl),
                        ),
                        Button.filled(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() => syncLocalComicImages = true);
                            appdata.settings['syncLocalComicImages'] = true;
                            appdata.saveData();
                          },
                          child: Text("Enable".tl),
                        ),
                      ],
                    ),
                  );
                } else {
                  setState(() => syncLocalComicImages = false);
                  appdata.settings['syncLocalComicImages'] = false;
                  appdata.saveData();
                }
              },
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Button.outlined(
                  onPressed: () async {
                    // Explicit "publish": the user tapped Upload, so this
                    // device's data wins even if it trails the server (#86
                    // guard is for automatic uploads only).
                    var result = await DataSync().uploadData(force: true);
                    if (result.error) {
                      context.showMessage(message: result.errorMessage!);
                    } else {
                      context.showMessage(message: "Upload successful".tl);
                    }
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_upload_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text("Upload".tl),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Button.outlined(
                  onPressed: () => _showRemoteBackupList(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_download_outlined, size: 18),
                      const SizedBox(width: 6),
                      Text("Download".tl),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(
              child: Button.filled(
                isLoading: isTesting,
                onPressed: _saveConfig,
                child: Text("Save".tl),
              ),
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }
}

/// The sync-mode / backup-retention / proxy options, surfaced directly under
/// the "WebDAV Sync" group header instead of inside the connection dialog.
/// Moved out because on shorter screens the dialog's growing content pushed
/// the Save button off-screen behind a scroll region (#114 follow-up).
class _WebdavSyncOptions extends StatefulWidget {
  const _WebdavSyncOptions();

  @override
  State<_WebdavSyncOptions> createState() => _WebdavSyncOptionsState();
}

class _WebdavSyncOptionsState extends State<_WebdavSyncOptions> {
  WebdavSyncMode syncMode = WebdavSyncMode.realtime;

  int backupRetention = backupRetentionPerPlatform;

  /// The retention choices offered in the UI. Foreign synced values outside
  /// this list still work (sanitized on use); the selector then shows the
  /// sanitized number as-is.
  static const _retentionChoices = [3, 5, 10, 20];

  bool useProxy = true;

  bool syncLocalComics = true;

  @override
  void initState() {
    super.initState();
    // Reads through the legacy-webdavAutoSync migration in DataSync.syncMode.
    syncMode = DataSync().syncMode;
    backupRetention = sanitizedBackupRetention(
      appdata.settings['webdavBackupRetention'],
    );
    useProxy = appdata.settings['webdavUseProxy'] != false;
    syncLocalComics = appdata.settings['syncLocalComics'] != false;
  }

  String _syncModeLabel(WebdavSyncMode mode) => switch (mode) {
        WebdavSyncMode.realtime => "Realtime".tl,
        WebdavSyncMode.dataSaver => "Data Saver".tl,
        WebdavSyncMode.manual => "Manual Only".tl,
      };

  String _syncModeDescription(WebdavSyncMode mode) => switch (mode) {
        WebdavSyncMode.realtime => "Upload shortly after every change".tl,
        WebdavSyncMode.dataSaver =>
          "Batch changes; upload on app switch / resume, at most every 30 minutes"
              .tl,
        WebdavSyncMode.manual => "Upload only when triggered manually".tl,
      };

  void onSyncModeChanged(WebdavSyncMode mode) {
    setState(() {
      syncMode = mode;
      DataSync().setSyncMode(mode);
    });
  }

  void onBackupRetentionChanged(int value) {
    setState(() {
      backupRetention = value;
      appdata.settings['webdavBackupRetention'] = value;
      appdata.saveData();
    });
  }

  void onUseProxyChanged(bool value) {
    setState(() {
      useProxy = value;
      appdata.settings['webdavUseProxy'] = value;
      appdata.saveData();
    });
  }

  void onSyncLocalComicsChanged(bool value) {
    setState(() {
      syncLocalComics = value;
      appdata.settings['syncLocalComics'] = value;
      appdata.saveData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          title: Text("Sync Mode".tl),
          subtitle: Text(
            _syncModeDescription(syncMode),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Select(
            current: _syncModeLabel(syncMode),
            values: WebdavSyncMode.values.map(_syncModeLabel).toList(),
            minWidth: 84,
            onTap: (index) => onSyncModeChanged(WebdavSyncMode.values[index]),
          ),
        ),
        ListTile(
          title: Text("Backups to keep per platform".tl),
          subtitle: Text(
            "Older backups on the server are removed after each upload".tl,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Select(
            current: backupRetention.toString(),
            values: [
              // A synced value outside the offered list stays selectable
              // instead of rendering an empty selector.
              if (!_retentionChoices.contains(backupRetention))
                backupRetention.toString(),
              ..._retentionChoices.map((e) => e.toString()),
            ],
            minWidth: 64,
            onTap: (index) {
              var values = [
                if (!_retentionChoices.contains(backupRetention))
                  backupRetention,
                ..._retentionChoices,
              ];
              onBackupRetentionChanged(values[index]);
            },
          ),
        ),
        ListTile(
          title: Text("Sync Local Comics".tl),
          subtitle: Text(
            "Include this device's local comic library in sync. Turn off to read or download comics online instead of receiving the whole library from other devices."
                .tl,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Switch(
            value: syncLocalComics,
            onChanged: onSyncLocalComicsChanged,
          ),
        ),
        ListTile(
          title: Text("Use Proxy for Sync".tl),
          subtitle: Text(
            "Route WebDAV sync through the app proxy. Turn off if an unstable proxy makes sync fail."
                .tl,
            style: const TextStyle(fontSize: 12),
          ),
          trailing: Switch(value: useProxy, onChanged: onUseProxyChanged),
        ),
      ],
    );
  }
}

class _RemoteBackupListDialog extends StatelessWidget {
  const _RemoteBackupListDialog({required this.backups});

  final List<RemoteBackupInfo> backups;

  String _platformLabel(String platform) {
    return switch (platform) {
      'win' => 'Windows',
      'ios' => 'iOS',
      'android' => 'Android',
      'macos' => 'macOS',
      'linux' => 'Linux',
      'web' => 'Web',
      _ => platform,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ContentDialog(
      title: "Select Backup".tl,
      content: SizedBox(
        width: 400,
        height: 350,
        child: ListView.builder(
          itemCount: backups.length,
          itemBuilder: (context, index) {
            var b = backups[index];
            var d = b.effectiveDate;
            String two(int n) => n.toString().padLeft(2, '0');
            var dateStr =
                "${d.year}-${two(d.month)}-${two(d.day)}"
                " ${two(d.hour)}:${two(d.minute)}:${two(d.second)}";
            return ListTile(
              title: Text("v${b.version}  ${_platformLabel(b.platform)}"),
              subtitle: Text(dateStr),
              trailing: const Icon(Icons.download),
              onTap: () {
                // Return the chosen backup to the caller, which drives the
                // confirm/download flow on a stable context. Pop the same
                // (root) navigator this dialog was shown on.
                Navigator.of(context, rootNavigator: true).pop(b);
              },
            );
          },
        ),
      ),
    );
  }
}

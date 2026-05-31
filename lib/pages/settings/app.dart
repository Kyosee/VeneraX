part of 'settings_page.dart';

class AppSettings extends StatefulWidget {
  const AppSettings({super.key});

  @override
  State<AppSettings> createState() => _AppSettingsState();
}

class _AppSettingsState extends State<AppSettings> {
  void _showSyncLogsDialog(BuildContext context) {
    final logs = DataSync().syncLogs;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("Sync Logs".tl),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: logs.isEmpty
              ? Center(child: Text("No logs".tl))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) {
                    final log = logs[i];
                    final time = DateTime.fromMillisecondsSinceEpoch(
                      log['time'] as int? ?? 0,
                    );
                    final action = log['action'] as String? ?? '';
                    final success = log['success'] as bool? ?? false;
                    final error = log['error'] as String?;
                    final fileName = log['fileName'] as String?;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        success ? Icons.check_circle : Icons.error,
                        color: success ? Colors.green : Colors.red,
                        size: 20,
                      ),
                      title: Text(
                        action == 'upload' ? 'Upload'.tl : action == 'download' ? 'Download'.tl : action,
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        '${time.toString().substring(0, 19)}${fileName != null ? '\n$fileName' : ''}${error != null ? '\n$error' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Close".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("App".tl)),
        _SettingPartTitle(title: "Data".tl, icon: Icons.storage),
        if (!App.isWeb) ...[
          ListTile(
            title: Text("Storage Path for local comics".tl),
            subtitle: Text(LocalManager().path, softWrap: false),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: LocalManager().path));
                context.showMessage(message: "Path copied to clipboard".tl);
              },
            ),
          ).toSliver(),
          _CallbackSetting(
            title: "Set New Storage Path".tl,
            actionTitle: "Set".tl,
            callback: () async {
              String? result;
              if (App.isAndroid) {
                var picker = DirectoryPicker();
                result = (await picker.pickDirectory())?.path;
              } else if (App.isIOS) {
                result = await selectDirectoryIOS();
              } else {
                result = await selectDirectory();
              }
              if (result == null) return;
              var loadingDialog = showLoadingDialog(
                App.rootContext,
                barrierDismissible: false,
                allowCancel: false,
              );
              var res = await LocalManager().setNewPath(result);
              loadingDialog.close();
              if (res != null) {
                context.showMessage(message: res);
              } else {
                context.showMessage(message: "Path set successfully".tl);
                setState(() {});
              }
            },
          ).toSliver(),
          ListTile(
            title: Text("Cache Size".tl),
            subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
          ).toSliver(),
          _CallbackSetting(
            title: "Clear Cache".tl,
            actionTitle: "Clear".tl,
            callback: () async {
              var loadingDialog = showLoadingDialog(
                App.rootContext,
                barrierDismissible: false,
                allowCancel: false,
              );
              await CacheManager().clear();
              loadingDialog.close();
              context.showMessage(message: "Cache cleared".tl);
              setState(() {});
            },
          ).toSliver(),
          _CallbackSetting(
            title: "Cache Limit".tl,
            subtitle: "${appdata.settings['cacheSize']} MB",
            callback: () {
              showInputDialog(
                context: context,
                title: "Set Cache Limit".tl,
                hintText: "Size in MB".tl,
                inputValidator: RegExp(r"^\d+$"),
                onConfirm: (value) {
                  appdata.settings['cacheSize'] = int.parse(value);
                  appdata.saveData();
                  setState(() {});
                  CacheManager().setLimitSize(appdata.settings['cacheSize']);
                  return null;
                },
              );
            },
            actionTitle: 'Set'.tl,
          ).toSliver(),
        ],
        _CallbackSetting(
          title: "Export App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await exportAppData(false);
            await saveFile(filename: "data.venera", file: file);
            controller.close();
          },
          actionTitle: 'Export'.tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Import App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await selectFile(
              ext: App.isWeb ? ['venera'] : ['venera', 'picadata'],
            );
            if (file != null) {
              var cacheFile = File(
                FilePath.join(App.cachePath, "import_data_temp"),
              );
              await file.saveTo(cacheFile.path);
              try {
                if (file.name.endsWith('picadata')) {
                  if (App.isWeb) {
                    context.showMessage(
                      message: "Pica data import is not supported on WebPWA".tl,
                    );
                  } else {
                    await importPicaData(cacheFile);
                  }
                } else {
                  await importAppData(cacheFile);
                }
              } catch (e, s) {
                Log.error("Import data", e.toString(), s);
                context.showMessage(message: "Failed to import data".tl);
              } finally {
                cacheFile.deleteIgnoreError();
                App.forceRebuild();
              }
            }
            controller.close();
          },
          actionTitle: 'Import'.tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Data Sync".tl,
          callback: () async {
            showPopUpWidget(context, const _WebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Sync Logs".tl,
          callback: () async {
            _showSyncLogsDialog(context);
          },
          actionTitle: 'View'.tl,
        ).toSliver(),
        _SettingPartTitle(title: "User".tl, icon: Icons.person_outline),
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
        ).toSliver(),
        if (!App.isLinux && !App.isWeb)
          _SwitchSetting(
            title: "Authorization Required".tl,
            settingKey: "authorizationRequired",
            onChanged: () async {
              var current = appdata.settings['authorizationRequired'];
              if (current) {
                final auth = LocalAuthentication();
                final bool canAuthenticateWithBiometrics =
                    await auth.canCheckBiometrics;
                final bool canAuthenticate =
                    canAuthenticateWithBiometrics ||
                    await auth.isDeviceSupported();
                if (!canAuthenticate) {
                  context.showMessage(message: "Biometrics not supported".tl);
                  setState(() {
                    appdata.settings['authorizationRequired'] = false;
                  });
                  appdata.saveData();
                  return;
                }
              }
            },
          ).toSliver(),
      ],
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
                    child: Text("Export".tl),
                    onTap: () => saveLog(Log().toString()),
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

  bool autoSync = true;

  bool syncLocalComicImages = false;

  bool isTesting = false;

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
    autoSync = appdata.implicitData['webdavAutoSync'] ?? true;
    syncLocalComicImages = appdata.settings['syncLocalComicImages'] ?? false;
    if (App.isWeb) {
      unawaited(_loadServerWebDavConfig());
    }
  }

  Future<void> _loadServerWebDavConfig() async {
    try {
      final config = await DataSync().loadWebDavConfig(force: true);
      if (!mounted || config == null) {
        return;
      }
      final loadedUrl = config['url']?.toString() ?? '';
      final loadedUser = config['user']?.toString() ?? '';
      final loadedPass = config['pass']?.toString() ?? '';
      if (loadedUrl.isEmpty || loadedUser.isEmpty) {
        return;
      }
      setState(() {
        url = loadedUrl;
        user = loadedUser;
        pass = loadedPass;
        disableSync =
            config['disableSyncFields']?.toString() ?? disableSync;
        autoSync = config['autoSync'] == true;
      });
    } catch (e, s) {
      Log.error('WebDAV Config', e, s);
    }
  }

  void onAutoSyncChanged(bool value) {
    setState(() {
      autoSync = value;
      appdata.implicitData['webdavAutoSync'] = value;
      appdata.writeImplicitData();
    });
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
            TextField(
              decoration: InputDecoration(
                labelText: "Skip Setting Fields (Optional)".tl,
                hintText: "field0, field1, field2, ...",
                hintStyle: TextStyle(color: Theme.of(context).hintColor),
                border: OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(Icons.help_outline),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: Text("Skip Setting Fields".tl),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "When sync data, skip certain setting fields, which means these won't be uploaded / override."
                                  .tl,
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    "See source code for available fields.".tl,
                                  ),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: IconButton(
                                    icon: const Icon(Icons.open_in_new),
                                    onPressed: () {
                                      launchUrlString(
                                        "https://github.com/Kyosee/venera/blob/master/lib/foundation/appdata.dart",
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              controller: TextEditingController(text: disableSync),
              onChanged: (value) => disableSync = value,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Auto Sync Data".tl),
              contentPadding: EdgeInsets.zero,
              trailing: Switch(value: autoSync, onChanged: onAutoSyncChanged),
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
                    var result = await DataSync().uploadData();
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
                onPressed: () async {
                  if (url.trim().isEmpty &&
                      user.trim().isEmpty &&
                      pass.trim().isEmpty) {
                    if (App.isWeb) {
                      await DataSync().clearWebDavConfig();
                    }
                    appdata.settings['webdav'] = [];
                    appdata.implicitData['webdavAutoSync'] = false;
                    appdata.writeImplicitData();
                    appdata.saveData();
                    context.showMessage(message: "Saved".tl);
                    App.rootPop();
                    return;
                  }

                  final config = [url.trim(), user.trim(), pass];
                  if (App.isWeb) {
                    try {
                      await DataSync().saveWebDavConfig(
                        config,
                        autoSync: autoSync,
                        disableSyncFields: disableSync,
                      );
                    } catch (e, s) {
                      Log.error('WebDAV Config', e, s);
                      context.showMessage(message: e.toString());
                      context.showMessage(message: "Saved Failed".tl);
                      return;
                    }
                  }

                  appdata.settings['webdav'] = App.isWeb ? [] : config;
                  appdata.settings['disableSyncFields'] = disableSync;
                  appdata.implicitData['webdavAutoSync'] = autoSync;
                  appdata.writeImplicitData();

                  // Persisting the configuration always succeeds at this
                  // point. The initial sync below is best-effort: its result
                  // is only surfaced as a hint and never rolls the config back.
                  appdata.saveData();

                  if (!autoSync) {
                    context.showMessage(message: "Saved".tl);
                    App.rootPop();
                    return;
                  }

                  setState(() {
                    isTesting = true;
                  });
                  // Use syncData() instead of uploadData() so a fresh install
                  // with no local data downloads the remote backup instead of
                  // being blocked by the empty-data upload guards.
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
                },
                child: Text("Save".tl),
              ),
            ),
          ],
        ).paddingHorizontal(16),
      ),
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
            var dateStr =
                "${b.date.year}-${b.date.month.toString().padLeft(2, '0')}"
                "-${b.date.day.toString().padLeft(2, '0')}";
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

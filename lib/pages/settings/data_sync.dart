part of 'settings_page.dart';

/// Settings for local application data and WebDAV synchronization.
class DataSyncSettings extends StatefulWidget {
  const DataSyncSettings({this.storageOnly = false, this.section, super.key});

  final bool storageOnly;
  final String? section;

  @override
  State<DataSyncSettings> createState() => _DataSyncSettingsState();
}

class _DataSyncSettingsState extends State<DataSyncSettings> {
  Future<void> _openSection(String section) async {
    await context.to(
      () => DataSyncSettings(storageOnly: widget.storageOnly, section: section),
    );
    if (mounted) setState(() {});
  }

  String _importTaskMessage(ImportTask task) {
    if (task.phase == ImportPhase.extracting) {
      if (task.extractedBytes <= 0) return "Extracting".tl;
      return "${"Extracting".tl} · "
          "${"Extracted @size".tlParams({'size': bytesToReadableString(task.extractedBytes)})}";
    }
    var key = task.phase == ImportPhase.applying && task.message != null
        ? task.message!
        : importPhaseLabelKey(task.phase);
    return key.tl;
  }

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
                        action == 'upload'
                            ? 'Upload'.tl
                            : action == 'download'
                            ? 'Download'.tl
                            : action,
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
    return _SettingsPageView(
      title: widget.storageOnly ? 'Downloads & storage' : 'Sync & backup',
      description: widget.storageOnly
          ? 'Downloads, cache and saved files'
          : 'WebDAV, backups and data management',
      section:
          widget.section ??
          _settingsSectionForTitle(
            widget.storageOnly ? 9 : 3,
            _SettingsJumpScope.targetOf(context),
          ),
      onOpenSection: _openSection,
      sections: [
        if (widget.storageOnly) ...[
          _SettingsSection(
            title: 'Downloads',
            common: true,
            icon: Icons.download_outlined,
            children: [
              _SliderSetting(
                title: "Download Threads".tl,
                description:
                    'Images downloaded at once within each comic. Reduce this if the source limits requests.'
                        .tl,
                settingsIndex: 'downloadThreads',
                interval: 1,
                min: 1,
                max: 16,
              ),
              _SliderSetting(
                title: "Parallel Downloads".tl,
                description:
                    'Comics downloaded at the same time. Combined with Download Threads, this controls the total number of image requests.'
                        .tl,
                settingsIndex: 'maxParallelDownloads',
                interval: 1,
                min: 1,
                max: 3,
              ),
              _SwitchSetting(
                title: "Download on WiFi Only".tl,
                settingKey: 'downloadWifiOnly',
                onChanged: () =>
                    DownloadNetworkGuard.instance.onSettingChanged(),
              ),
            ],
          ),
          _SettingsSection(
            title: 'Storage locations',
            subtitle: LocalManager().path,
            icon: Icons.storage,
            children: [
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
              ),
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
                  Future<void> apply({bool allowNonEmpty = false}) async {
                    var loadingDialog = showLoadingDialog(
                      App.rootContext,
                      barrierDismissible: false,
                      allowCancel: false,
                    );
                    var res = await LocalManager().setNewPath(
                      result!,
                      allowNonEmpty: allowNonEmpty,
                    );
                    loadingDialog.close();
                    if (res == LocalManager.dirNotEmptySignal) {
                      showConfirmDialog(
                        context: App.rootContext,
                        title: "Directory is not empty".tl,
                        content:
                            "The selected directory is not empty. Continue to merge local comics into it?"
                                .tl,
                        confirmText: "Continue".tl,
                        onConfirm: () => apply(allowNonEmpty: true),
                      );
                    } else if (res != null) {
                      context.showMessage(message: res);
                    } else {
                      context.showMessage(message: "Path set successfully".tl);
                      setState(() {});
                    }
                  }

                  await apply();
                },
              ),
              const ComicCacheDirectorySetting(),
            ],
          ),
          _SettingsSection(
            title: 'Cache',
            common: true,
            icon: Icons.cached,
            children: [
              ListTile(
                title: Text("Cache Size".tl),
                subtitle: Text(
                  bytesToReadableString(CacheManager().currentSize),
                ),
              ),
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
              ),
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
                      CacheManager().setLimitSize(
                        appdata.settings['cacheSize'],
                      );
                      return null;
                    },
                  );
                },
                actionTitle: 'Set'.tl,
              ),
            ],
          ),
        ],
        if (!widget.storageOnly) ...[
          _SettingsSection(
            title: 'Data import & export',
            subtitle: 'App data and translation results',
            icon: Icons.import_export,
            children: [
              _CallbackSetting(
                title: "Export App Data".tl,
                callback: () async {
                  var controller = showLoadingDialog(context);
                  var file = await exportAppData(sync: false);
                  await saveFile(filename: "data.venera", file: file);
                  controller.close();
                },
                actionTitle: 'Export'.tl,
              ),
              _CallbackSetting(
                title: "Export Translation Results".tl,
                subtitle:
                    "Saves only translated pages. Importing it with Import App Data on another device adds them and leaves that device's other data unchanged."
                        .tl,
                callback: () async {
                  var controller = showLoadingDialog(context);
                  File? file;
                  Object? error;
                  try {
                    file = await exportTranslations();
                  } catch (e, s) {
                    error = e;
                    Log.error("Export Translations", "$e", s);
                  }
                  controller.close();
                  if (error != null) {
                    App.rootContext.showMessage(message: "Export failed".tl);
                    return;
                  }
                  if (file == null) {
                    App.rootContext.showMessage(
                      message: "No translation results to export".tl,
                    );
                    return;
                  }
                  try {
                    await saveFile(filename: "translations.venera", file: file);
                  } finally {
                    file.deleteIgnoreError();
                  }
                },
                actionTitle: 'Export'.tl,
              ),
              _CallbackSetting(
                title: "Import App Data".tl,
                callback: () async {
                  var file = await selectFile(ext: ['venera', 'picadata']);
                  if (file == null) return;
                  var manager = ImportTaskManager.instance;
                  var task = manager.startImport(
                    filePath: file.path,
                    fileName: file.name,
                    isPica: file.name.endsWith('picadata'),
                  );
                  if (task == null) {
                    context.showMessage(
                      message: "An import task is already running".tl,
                    );
                    return;
                  }
                  var controller = showLoadingDialog(
                    context,
                    withProgress: true,
                    barrierDismissible: false,
                    message: _importTaskMessage(task),
                    secondaryButtonText: "Background",
                    onSecondary: () {},
                    cancelButtonText: "Cancel",
                    onCancel: () => manager.cancel(task.id),
                  );
                  void listener() {
                    if (controller.closed) {
                      manager.removeListener(listener);
                      return;
                    }
                    controller.setProgress(task.indicatorValue);
                    controller.setMessage(_importTaskMessage(task));
                    if (!task.isRunning) {
                      manager.removeListener(listener);
                      controller.close();
                      if (task.status == ImportTaskStatus.completed) {
                        App.rootContext.showMessage(
                          message: task.translationsOnly
                              ? "Imported translations for @n pages".tlParams({
                                  'n': task.translatedPages,
                                })
                              : "Import completed".tl,
                        );
                      } else if (task.status == ImportTaskStatus.failed) {
                        App.rootContext.showMessage(
                          message: (task.error ?? "Import failed").tl,
                        );
                      }
                    }
                  }

                  manager.addListener(listener);
                  listener();
                },
                actionTitle: 'Import'.tl,
              ),
            ],
          ),
          _SettingsSection(
            title: 'WebDAV Sync',
            common: true,
            icon: Icons.cloud_sync_outlined,
            children: [
              _CallbackSetting(
                title: "Data Sync".tl,
                callback: () async {
                  await showPopUpWidget(context, const _WebdavSetting());
                  if (mounted) setState(() {});
                },
                actionTitle: 'Set'.tl,
              ),
              const _WebdavSyncOptions(showAdvanced: false),
            ],
          ),
          const _SettingsSection(
            title: 'Sync preferences',
            subtitle: 'Sync mode, backup retention and sync scope',
            icon: Icons.sync,
            children: [_WebdavSyncOptions(showCommon: false)],
          ),
          _SettingsSection(
            title: 'Data management',
            common: true,
            icon: Icons.cloud_outlined,
            children: [
              _CallbackSetting(
                title: "Sync Logs".tl,
                callback: () async {
                  _showSyncLogsDialog(context);
                },
                actionTitle: 'View'.tl,
              ),
              _CallbackSetting(
                title: "WebDAV Comic Library".tl,
                callback: () async {
                  App.rootContext.to(() => const WebdavLibrariesPage());
                },
                actionTitle: 'Set'.tl,
              ),
            ],
          ),
        ],
      ],
    );
  }
}

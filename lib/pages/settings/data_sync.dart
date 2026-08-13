part of 'settings_page.dart';

/// Settings for local application data and WebDAV synchronization.
class DataSyncSettings extends StatefulWidget {
  const DataSyncSettings({super.key});

  @override
  State<DataSyncSettings> createState() => _DataSyncSettingsState();
}

class _DataSyncSettingsState extends State<DataSyncSettings> {
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
    return SmoothCustomScrollView(
      scrollbarTopPadding: context.padding.top + 56,
      slivers: [
        SliverAppbar(title: Text("Data & Sync".tl)),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('dataSyncDataGroup'),
          initiallyExpanded: true,
          icon: Icons.storage,
          title: "Data".tl,
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
            ListTile(
              title: Text("Cache Size".tl),
              subtitle: Text(bytesToReadableString(CacheManager().currentSize)),
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
                    CacheManager().setLimitSize(appdata.settings['cacheSize']);
                    return null;
                  },
                );
              },
              actionTitle: 'Set'.tl,
            ),
            SelectSetting(
              title: "Auto clean reading history".tl,
              settingKey: "autoCleanHistoryDays",
              help:
                  "Automatically delete reading history older than the selected period when the app starts."
                      .tl,
              optionTranslation: {
                "0": "Never".tl,
                "7": "7 days".tl,
                "30": "30 days".tl,
                "90": "90 days".tl,
                "180": "180 days".tl,
                "365": "365 days".tl,
              },
            ),
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
                        message: "Import completed".tl,
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
        ).toSliver(),
        _SettingsExpansionTile(
          expansionKey: const PageStorageKey('dataSyncWebdavGroup'),
          initiallyExpanded: true,
          icon: Icons.cloud_sync_outlined,
          title: "WebDAV Sync".tl,
          children: [
            _CallbackSetting(
              title: "Data Sync".tl,
              callback: () async {
                showPopUpWidget(context, const _WebdavSetting());
              },
              actionTitle: 'Set'.tl,
            ),
            const _WebdavSyncOptions(),
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
        ).toSliver(),
      ],
    );
  }
}

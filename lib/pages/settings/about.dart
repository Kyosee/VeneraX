part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text("V${App.version}", style: const TextStyle(fontSize: 16)),
            Text("Venera is a free and open-source app for comic reading.".tl),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                setState(() {
                  isCheckingUpdate = false;
                });
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("Github"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/Kyosee/venera");
          },
        ).toSliver(),
      ],
    );
  }
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.releaseUrl,
    this.windowsPackageUrl,
  });

  final String version;
  final String releaseUrl;
  final String? windowsPackageUrl;

  bool get canUseWindowsUpdater => App.isWindows && windowsPackageUrl != null;
}

Future<AppUpdateInfo?> checkUpdate() async {
  final latestRelease = await _getLatestRelease();
  final latestVersion = _versionFromRelease(latestRelease);
  if (latestVersion == null || !_compareVersion(latestVersion, App.version)) {
    return null;
  }
  final windowsAsset = App.isWindows
      ? _findWindowsZipAsset(latestRelease["assets"])
      : null;
  return AppUpdateInfo(
    version: latestVersion,
    releaseUrl:
        latestRelease["html_url"]?.toString() ??
        "https://github.com/Kyosee/venera/releases",
    windowsPackageUrl: windowsAsset?["browser_download_url"]?.toString(),
  );
}

Future<Map<String, dynamic>> _getLatestRelease() async {
  final res = await AppDio().get(
    "https://api.github.com/repos/Kyosee/venera/releases/latest",
    options: Options(
      headers: {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Venera",
      },
    ),
  );
  if (res.statusCode == 200) {
    final data = res.data is String ? jsonDecode(res.data) : res.data;
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
  }
  throw StateError("Failed to check latest release");
}

String? _versionFromRelease(Map<String, dynamic> release) {
  final tagName = release["tag_name"]?.toString();
  if (tagName == null || tagName.isEmpty) {
    return null;
  }
  return _normalizeVersion(tagName);
}

Map<String, dynamic>? _findWindowsZipAsset(Object? assets) {
  if (assets is! List) {
    return null;
  }
  final candidates = assets
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .where((asset) {
        final name = asset["name"]?.toString().toLowerCase() ?? "";
        return name.endsWith(".zip") &&
            name.contains("windows") &&
            !name.contains("installer") &&
            asset["browser_download_url"] != null;
      })
      .toList();
  if (candidates.isEmpty) {
    return null;
  }

  final isArm64 = isWindowsArm64;
  Map<String, dynamic>? preferred;
  for (final asset in candidates) {
    final name = asset["name"]!.toString().toLowerCase();
    if (isArm64 && name.contains("arm64")) {
      preferred = asset;
      break;
    }
    if (!isArm64 && !name.contains("arm64")) {
      preferred = asset;
      break;
    }
  }
  return preferred ?? candidates.first;
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  try {
    var value = await checkUpdate();
    if (value != null) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      showDialog(
        context: App.rootContext,
        builder: (context) {
          final canUseWindowsUpdater = value.canUseWindowsUpdater;
          return ContentDialog(
            title: "New version available".tl,
            content: Text(
              "Version @v is available. Do you want to update now?".tlParams({
                "v": value.version,
              }),
            ).paddingHorizontal(16),
            actions: [
              Button.text(
                onPressed: () {
                  Navigator.pop(context);
                  launchUrlString(value.releaseUrl);
                },
                child: Text(
                  canUseWindowsUpdater ? "Open release page".tl : "Update".tl,
                ),
              ),
              if (canUseWindowsUpdater)
                Button.filled(
                  onPressed: () {
                    Navigator.pop(context);
                    _startWindowsUpdate(value);
                  },
                  child: Text("Update".tl),
                ),
            ],
          );
        },
      );
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
    if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "Failed to check updates".tl);
    }
  }
}

Future<void> _startWindowsUpdate(AppUpdateInfo updateInfo) async {
  if (!App.isWindows || updateInfo.windowsPackageUrl == null) {
    await launchUrlString(updateInfo.releaseUrl);
    return;
  }
  final appExe = Platform.resolvedExecutable;
  final appDir = File(appExe).parent.path;
  final updater = File(_joinWindowsPath(appDir, "venera_updater.exe"));
  if (!updater.existsSync()) {
    App.rootContext.showMessage(
      message:
          "Updater not found. Please download the latest package manually.".tl,
    );
    await launchUrlString(updateInfo.releaseUrl);
    return;
  }

  final tempFile = File(
    _joinWindowsPath(Directory.systemTemp.path, 'venera_update_download.zip'),
  );

  var cancelled = false;
  var downloadedBytes = 0;
  var totalBytes = 0;
  String? errorMsg;
  final cancelToken = CancelToken();
  void Function(VoidCallback)? rebuildDialog;

  if (App.rootContext.mounted) {
    showDialog(
      context: App.rootContext,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            rebuildDialog = setDialogState;
            final done = totalBytes > 0
                ? downloadedBytes / totalBytes
                : null;
            return ContentDialog(
              title: "Downloading update".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (done != null)
                    LinearProgressIndicator(value: done)
                  else
                    const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    totalBytes > 0
                        ? "${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)} MB / ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB"
                        : "${(downloadedBytes / 1024 / 1024).toStringAsFixed(1)} MB",
                  ),
                  if (errorMsg != null) ...[
                    const SizedBox(height: 8),
                    Text(errorMsg, style: const TextStyle(color: Colors.red)),
                  ],
                ],
              ).paddingHorizontal(16),
              actions: [
                Button.text(
                  onPressed: () {
                    cancelled = true;
                    cancelToken.cancel();
                    Navigator.pop(ctx);
                  },
                  child: Text("Cancel".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  try {
    await AppDio().download(
      updateInfo.windowsPackageUrl!,
      tempFile.path,
      cancelToken: cancelToken,
      onReceiveProgress: (received, total) {
        downloadedBytes = received;
        totalBytes = total;
        rebuildDialog?.call(() {});
      },
    );
  } catch (e) {
    if (cancelled) return;
    errorMsg = e.toString();
    App.rootPop();
    App.rootContext.showMessage(message: "Download failed: $errorMsg");
    return;
  }

  if (cancelled) {
    if (tempFile.existsSync()) {
      tempFile.deleteSync();
    }
    return;
  }

  App.rootPop();
  App.rootContext.showMessage(
    message: "Installing update. Venera will restart automatically.".tl,
  );
  await appdata.saveData(false);
  appdata.writeImplicitData();
  await Process.start(updater.path, [
    "--app-dir",
    appDir,
    "--package-file",
    tempFile.path,
    "--app-exe",
    appExe,
    "--pid",
    pid.toString(),
    "--restart",
  ], mode: ProcessStartMode.detached);
  await Future.delayed(const Duration(milliseconds: 500));
  exit(0);
}

String _joinWindowsPath(String dir, String file) {
  if (dir.endsWith(r"\")) {
    return "$dir$file";
  }
  return "$dir\\$file";
}

/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  var v1 = _normalizeVersion(version1).split(".");
  var v2 = _normalizeVersion(version2).split(".");
  final length = v1.length > v2.length ? v1.length : v2.length;
  for (var i = 0; i < length; i++) {
    final value1 = i < v1.length ? int.tryParse(v1[i]) ?? 0 : 0;
    final value2 = i < v2.length ? int.tryParse(v2[i]) ?? 0 : 0;
    if (value1 > value2) {
      return true;
    }
    if (value1 < value2) {
      return false;
    }
  }
  return false;
}

String _normalizeVersion(String version) {
  var result = version.trim();
  if (result.startsWith("v") || result.startsWith("V")) {
    result = result.substring(1);
  }
  result = result.split("+").first;
  result = result.split("-").first;
  return result;
}

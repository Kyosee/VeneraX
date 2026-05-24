part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  String get _repoOwner =>
      (appdata.settings['updateRepoOwner'] as String?) ?? 'Kyosee';
  String get _repoName =>
      (appdata.settings['updateRepoName'] as String?) ?? 'venera';
  bool get _usePrivateRepo =>
      appdata.settings['updateUsePrivateRepo'] == true;
  String get _repoToken =>
      (appdata.settings['updateRepoToken'] as String?) ?? '';

  @override
  void initState() {
    super.initState();
    _migrateLegacyRepoDefaults();
  }

  void _migrateLegacyRepoDefaults() {
    final owner = _repoOwner;
    final repo = _repoName;
    if (owner.toLowerCase() == 'haukuen' && repo.toLowerCase() == 'venera') {
      appdata.settings['updateRepoOwner'] = 'Kyosee';
      appdata.settings['updateRepoName'] = 'venera';
      appdata.saveData();
    }
  }

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
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(136)),
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
              setState(() => isCheckingUpdate = true);
              checkUpdateUi().then((_) {
                setState(() => isCheckingUpdate = false);
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        ListTile(
          title: Text("GitHub Update Source".tl),
          subtitle: Text(
            _usePrivateRepo
                ? "$_repoOwner/$_repoName - ${"Private Repository".tl}"
                : "$_repoOwner/$_repoName - ${"Public Repository".tl}",
          ),
          trailing: const Icon(Icons.tune),
          onTap: _editGithubUpdateSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: Text("Repository".tl),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/$_repoOwner/$_repoName");
          },
        ).toSliver(),
      ],
    );
  }

  void _editGithubUpdateSettings() {
    final ownerController = TextEditingController(text: _repoOwner);
    final repoController = TextEditingController(text: _repoName);
    final tokenController = TextEditingController(text: _repoToken);
    var usePrivateRepo = _usePrivateRepo;
    var syncToken = appdata.settings['syncUpdateRepoToken'] == true;
    var obscureToken = true;

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return ContentDialog(
              title: "GitHub Update Source".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: ownerController,
                    decoration: InputDecoration(
                      labelText: "Repository Owner".tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: repoController,
                    decoration: InputDecoration(
                      labelText: "Repository Name".tl,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: usePrivateRepo,
                    onChanged: (value) =>
                        setDialogState(() => usePrivateRepo = value),
                    title: Text("Use Private Repository".tl),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: syncToken,
                    onChanged: (value) =>
                        setDialogState(() => syncToken = value),
                    title: Text("Sync GitHub token in data sync".tl),
                  ),
                  if (usePrivateRepo) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: tokenController,
                      obscureText: obscureToken,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: "GitHub Token".tl,
                        hintText: "Fine-grained token with repository read access".tl,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          onPressed: () =>
                              setDialogState(() => obscureToken = !obscureToken),
                          icon: Icon(obscureToken
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined),
                        ),
                      ),
                    ),
                  ],
                ],
              ).paddingHorizontal(16).paddingVertical(8),
              actions: [
                Button.text(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text("Cancel".tl),
                ),
                Button.filled(
                  onPressed: () {
                    final owner = ownerController.text.trim();
                    final repo = repoController.text.trim();
                    final token = tokenController.text.trim();
                    if (owner.isEmpty || repo.isEmpty) {
                      context.showMessage(message: "Repository owner and name cannot be empty".tl);
                      return;
                    }
                    if (usePrivateRepo && token.isEmpty) {
                      context.showMessage(message: "GitHub token is required for private repository updates".tl);
                      return;
                    }
                    appdata.settings['updateRepoOwner'] = owner;
                    appdata.settings['updateRepoName'] = repo;
                    appdata.settings['updateUsePrivateRepo'] = usePrivateRepo;
                    appdata.settings['updateRepoToken'] = token;
                    appdata.settings['syncUpdateRepoToken'] = syncToken;
                    appdata.saveData();
                    if (!mounted) return;
                    setState(() {});
                    Navigator.pop(dialogContext);
                    this.context.showMessage(message: "Saved".tl);
                  },
                  child: Text("Save".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
// --- Data classes ---

class _GithubUpdateConfig {
  final String owner;
  final String repo;
  final bool usePrivateRepo;
  final String? token;
  const _GithubUpdateConfig({
    required this.owner,
    required this.repo,
    required this.usePrivateRepo,
    this.token,
  });
}

class _GitHubAsset {
  final String name;
  final String apiUrl;
  final String browserDownloadUrl;
  final int size;
  final String? digest;
  const _GitHubAsset({
    required this.name,
    required this.apiUrl,
    required this.browserDownloadUrl,
    required this.size,
    this.digest,
  });
  String get lowerName => name.toLowerCase();
  bool get isApk => lowerName.endsWith(".apk");
  bool get isExe => lowerName.endsWith(".exe");
  bool get isZip => lowerName.endsWith(".zip");
}

class _GitHubRelease {
  final String version;
  final String htmlUrl;
  final List<_GitHubAsset> assets;
  const _GitHubRelease({
    required this.version,
    required this.htmlUrl,
    required this.assets,
  });
}

class _UpdateCheckResult {
  final bool hasUpdate;
  final _GitHubRelease? release;
  final _GithubUpdateConfig config;
  const _UpdateCheckResult({
    required this.hasUpdate,
    required this.release,
    required this.config,
  });
}

// --- Config & Headers ---

_GithubUpdateConfig _readGithubUpdateConfig() {
  var owner = (appdata.settings['updateRepoOwner'] as String?) ?? 'Kyosee';
  var repo = (appdata.settings['updateRepoName'] as String?) ?? 'venera';
  if (owner.toLowerCase() == 'haukuen' && repo.toLowerCase() == 'venera') {
    owner = 'Kyosee';
    repo = 'venera';
    appdata.settings['updateRepoOwner'] = owner;
    appdata.settings['updateRepoName'] = repo;
    appdata.saveData();
  }
  var usePrivate = appdata.settings['updateUsePrivateRepo'] == true;
  var token = (appdata.settings['updateRepoToken'] as String?) ?? '';
  final tokenOrNull = token.isEmpty ? null : token;
  return _GithubUpdateConfig(
    owner: owner,
    repo: repo,
    usePrivateRepo: usePrivate,
    token: tokenOrNull,
  );
}

Map<String, String> _buildGithubHeaders(
  _GithubUpdateConfig config, {
  bool binary = false,
}) {
  final headers = <String, String>{
    "Accept": binary ? "application/octet-stream" : "application/vnd.github+json",
  };
  if (config.token != null && config.token!.isNotEmpty) {
    headers["Authorization"] = "Bearer ${config.token}";
    if (!App.isWeb) {
      headers["X-GitHub-Api-Version"] = "2022-11-28";
    }
  }
  return headers;
}

// --- Fetch & Compare ---

Future<_GitHubRelease> _fetchLatestRelease(_GithubUpdateConfig config) async {
  if (config.usePrivateRepo && (config.token == null || config.token!.isEmpty)) {
    throw Exception("GitHub token is required for private repository updates".tl);
  }
  final url =
      "https://api.github.com/repos/${config.owner}/${config.repo}/releases/latest";
  final response = await AppDio().get(
    url,
    options: Options(headers: _buildGithubHeaders(config)),
  );
  if (response.statusCode != 200) {
    throw Exception("Failed to get release info from GitHub".tl);
  }
  var data = response.data;
  if (data is String) data = jsonDecode(data);
  if (data is! Map) throw Exception("Invalid release response".tl);
  var map = Map<String, dynamic>.from(data);
  var tag = map['tag_name']?.toString() ?? "";
  var version = _normalizeVersion(tag);
  var htmlUrl = map['html_url']?.toString() ??
      "https://github.com/${config.owner}/${config.repo}/releases";
  var assets = <_GitHubAsset>[];
  if (map['assets'] is List) {
    for (var item in map['assets'] as List) {
      if (item is! Map) continue;
      var asset = Map<String, dynamic>.from(item);
      var name = asset['name']?.toString();
      var apiUrl = asset['url']?.toString();
      var browserUrl = asset['browser_download_url']?.toString();
      if (name == null || name.isEmpty || apiUrl == null || apiUrl.isEmpty ||
          browserUrl == null || browserUrl.isEmpty) {
        continue;
      }
      assets.add(_GitHubAsset(
        name: name,
        apiUrl: apiUrl,
        browserDownloadUrl: browserUrl,
        size: (asset['size'] as num?)?.toInt() ?? 0,
        digest: asset['digest']?.toString(),
      ));
    }
  }
  return _GitHubRelease(version: version, htmlUrl: htmlUrl, assets: assets);
}

Future<_UpdateCheckResult> _checkUpdateDetails() async {
  var config = _readGithubUpdateConfig();
  var release = await _fetchLatestRelease(config);
  var hasUpdate = _compareVersion(release.version, App.version);
  return _UpdateCheckResult(hasUpdate: hasUpdate, release: release, config: config);
}

Future<bool> checkUpdate() async {
  try {
    var value = await _checkUpdateDetails();
    return value.hasUpdate;
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
    return false;
  }
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  try {
    var value = await _checkUpdateDetails();
    if (value.hasUpdate && value.release != null) {
      if (delay) await Future.delayed(const Duration(seconds: 2));
      showDialog(
        context: App.rootContext,
        builder: (context) {
          return ContentDialog(
            title: "New version available".tl,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("A new version is available. Do you want to update now?".tl),
                const SizedBox(height: 8),
                Text("Current version: ${App.version}"),
                Text("Latest version: ${value.release!.version}"),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
            actions: [
              Button.text(
                onPressed: () {
                  Navigator.pop(context);
                  launchUrlString(value.release!.htmlUrl);
                },
                child: Text("View Release Page".tl),
              ),
              Button.filled(
                onPressed: () {
                  Navigator.pop(context);
                  _doUpdate(value);
                },
                child: Text("Update Now".tl),
              ),
            ],
          );
        },
      );
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "Failed to check for updates".tl);
    }
    Log.error("Check Update", e.toString(), s);
  }
}
// --- Platform dispatch ---

Future<void> _doUpdate(_UpdateCheckResult updateResult) async {
  final release = updateResult.release;
  if (release == null) return;

  if (App.isWindows) {
    await _updateWindows(updateResult.config, release);
    return;
  }
  if (App.isAndroid) {
    await _updateAndroid(updateResult.config, release);
    return;
  }
  await launchUrlString(release.htmlUrl);
  App.rootContext.showMessage(
    message: "This platform opens the release page for update".tl,
  );
}

// --- Android ---

Future<void> _updateAndroid(
  _GithubUpdateConfig config,
  _GitHubRelease release,
) async {
  var asset = _selectAndroidAsset(release.assets);
  if (asset == null) {
    await launchUrlString(release.htmlUrl);
    App.rootContext.showMessage(
      message: "No compatible update package found for this platform".tl,
    );
    return;
  }
  var filePath = await _downloadUpdateAsset(config, asset);
  if (filePath == null) return;

  var ok = await _verifyDigestIfNeeded(filePath, asset.digest);
  if (!ok) {
    File(filePath).deleteIfExistsSync();
    App.rootContext.showMessage(message: "Update package verification failed".tl);
    return;
  }

  var opened = await _installAndroidApk(filePath);
  if (!opened) {
    opened = await launchUrlString(Uri.file(filePath).toString());
  }
  if (!opened) {
    App.rootContext.showMessage(
      message: "Update package downloaded to $filePath",
    );
  }
}

Future<bool> _installAndroidApk(String filePath) async {
  if (!App.isAndroid) return false;
  const channel = MethodChannel("venera/method_channel");
  try {
    final installed = await channel.invokeMethod<bool>("installApk", {"path": filePath});
    return installed == true;
  } catch (e, s) {
    Log.error("Android Update", e.toString(), s);
    return false;
  }
}

// --- Windows ---

const _windowsUpdaterExeName = "venera_updater.exe";

Future<void> _updateWindows(
  _GithubUpdateConfig config,
  _GitHubRelease release,
) async {
  var asset = _selectWindowsAsset(release.assets);
  if (asset == null) {
    await launchUrlString(release.htmlUrl);
    App.rootContext.showMessage(
      message: "No compatible update package found for this platform".tl,
    );
    return;
  }
  var filePath = await _downloadUpdateAsset(config, asset);
  if (filePath == null) return;

  var ok = await _verifyDigestIfNeeded(filePath, asset.digest);
  if (!ok) {
    File(filePath).deleteIfExistsSync();
    App.rootContext.showMessage(message: "Update package verification failed".tl);
    return;
  }

  if (asset.isExe) {
    await _runWindowsInstaller(filePath);
    return;
  }
  if (asset.isZip) {
    await _runWindowsZipUpdater(filePath);
    return;
  }
  await launchUrlString(release.htmlUrl);
}

// --- Download ---

Future<String?> _downloadUpdateAsset(
  _GithubUpdateConfig config,
  _GitHubAsset asset,
) async {
  var updatesDir = Directory(FilePath.join(App.cachePath, "updates"));
  if (!updatesDir.existsSync()) updatesDir.createSync(recursive: true);

  var savePath = FilePath.join(updatesDir.path, asset.name);
  File(savePath).deleteIfExistsSync();

  bool canceled = false;
  final cancelToken = CancelToken();
  var loading = showLoadingDialog(
    App.rootContext,
    withProgress: true,
    message: "Downloading update package".tl,
    onCancel: () {
      canceled = true;
      cancelToken.cancel();
    },
  );

  try {
    final response = await AppDio().get<ResponseBody>(
      asset.browserDownloadUrl,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        headers: _buildGithubHeaders(config, binary: true),
      ),
    );
    final body = response.data!;
    final totalBytes = int.tryParse(
      body.headers['content-length']?.first ?? '',
    ) ?? asset.size;

    var downloadedBytes = 0;
    final sink = File(savePath).openWrite();
    await for (var chunk in body.stream) {
      if (canceled || loading.closed) {
        canceled = true;
        break;
      }
      sink.add(chunk);
      downloadedBytes += chunk.length;
      loading.setProgress(
        totalBytes > 0 ? downloadedBytes / totalBytes : null,
      );
      loading.setMessage(
        "${bytesToReadableString(downloadedBytes)} / "
        "${totalBytes > 0 ? bytesToReadableString(totalBytes) : '?'}",
      );
    }
    await sink.close();
  } catch (e, s) {
    if (canceled) {
      // ignore cancel errors
    } else {
      Log.error("Update Download", e.toString(), s);
      App.rootContext.showMessage(message: "Failed to download update package".tl);
      loading.close();
      return null;
    }
  } finally {
    loading.close();
  }

  if (canceled) {
    File(savePath).deleteIfExistsSync();
    App.rootContext.showMessage(message: "Update download canceled".tl);
    return null;
  }
  if (!File(savePath).existsSync()) return null;
  return savePath;
}

// --- Verification ---

Future<bool> _verifyDigestIfNeeded(String filePath, String? digestText) async {
  if (digestText == null || digestText.trim().isEmpty) return true;
  var digest = digestText.trim();
  if (!digest.toLowerCase().startsWith("sha256:")) return true;
  var expected = digest.substring("sha256:".length).trim().toLowerCase();
  if (expected.isEmpty) return true;
  var bytes = await File(filePath).readAsBytes();
  var actual = sha256.convert(bytes).toString().toLowerCase();
  return actual == expected;
}
// --- Windows Installer ---

Future<void> _runWindowsInstaller(String installerPath) async {
  final exePath = Platform.resolvedExecutable;
  final scriptPath = FilePath.join(App.cachePath, "venera_windows_installer_updater.ps1");
  await File(scriptPath).writeAsString(_buildWindowsInstallerUpdateScript());
  await _runWindowsUpdaterScript(
    scriptPath: scriptPath,
    args: ["-InstallerPath", installerPath, "-ExePath", exePath],
    message: "Installer started. App will close to continue update".tl,
  );
}

Future<void> _runWindowsZipUpdater(String zipPath) async {
  var exePath = Platform.resolvedExecutable;
  var installDir = File(exePath).parent.path;

  if (await _runWindowsUpdaterExecutable(zipPath: zipPath, installDir: installDir, exePath: exePath)) {
    return;
  }

  var scriptPath = FilePath.join(App.cachePath, "venera_windows_updater.ps1");
  await File(scriptPath).writeAsString(_buildWindowsZipUpdateScript());
  await _runWindowsUpdaterScript(
    scriptPath: scriptPath,
    args: ["-ZipPath", zipPath, "-TargetDir", installDir, "-ExePath", exePath],
    message: "Update script started. App will restart after update".tl,
  );
}

Future<bool> _runWindowsUpdaterExecutable({
  required String zipPath,
  required String installDir,
  required String exePath,
}) async {
  final updaterPath = FilePath.join(installDir, _windowsUpdaterExeName);
  if (!File(updaterPath).existsSync()) return false;

  final updatesDir = Directory(FilePath.join(App.cachePath, "updates"));
  if (!updatesDir.existsSync()) updatesDir.createSync(recursive: true);

  final stagedUpdaterPath = FilePath.join(updatesDir.path, _windowsUpdaterExeName);

  try {
    File(stagedUpdaterPath).deleteIfExistsSync();
    await File(updaterPath).copy(stagedUpdaterPath);
    await Process.start(
      stagedUpdaterPath,
      [
        "--app-dir", installDir,
        "--package-file", zipPath,
        "--app-exe", exePath,
        "--pid", pid.toString(),
        "--restart",
      ],
      mode: ProcessStartMode.detached,
      workingDirectory: updatesDir.path,
    );
    App.rootContext.showMessage(message: "Updater started. App will restart after update".tl);
    await Future.delayed(const Duration(milliseconds: 400));
    if (!App.isWeb) exit(0);
    return true;
  } catch (e, s) {
    Log.error("Windows Update", e.toString(), s);
    App.rootContext.showMessage(message: "Failed to start updater, falling back to update script".tl);
    return false;
  }
}

Future<void> _runWindowsUpdaterScript({
  required String scriptPath,
  required List<String> args,
  required String message,
}) async {
  await Process.start("powershell.exe", [
    "-NoProfile",
    "-NonInteractive",
    "-WindowStyle", "Hidden",
    "-ExecutionPolicy", "Bypass",
    "-File", scriptPath,
    ...args,
  ], mode: ProcessStartMode.detached);
  App.rootContext.showMessage(message: message);
  await Future.delayed(const Duration(milliseconds: 400));
  exit(0);
}
// --- PowerShell Scripts ---

String _buildWindowsInstallerUpdateScript() {
  return r'''
param(
  [Parameter(Mandatory=$true)][string]$InstallerPath,
  [Parameter(Mandatory=$true)][string]$ExePath
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
for ($i = 0; $i -lt 120; $i++) {
  try {
    $stream = [System.IO.File]::Open($ExePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $stream.Close()
    break
  } catch { Start-Sleep -Milliseconds 500 }
}
try {
  $installerArgs = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NOCANCEL','/SP-','/CLOSEAPPLICATIONS','/FORCECLOSEAPPLICATIONS','/NORESTART')
  Start-Process -FilePath $InstallerPath -ArgumentList $installerArgs -Wait | Out-Null
} catch {}
try { Start-Process -FilePath $ExePath | Out-Null } catch {}''';
}

String _buildWindowsZipUpdateScript() {
  return r'''
param(
  [Parameter(Mandatory=$true)][string]$ZipPath,
  [Parameter(Mandatory=$true)][string]$TargetDir,
  [Parameter(Mandatory=$true)][string]$ExePath
)
$ProgressPreference = "SilentlyContinue"
$logFile = Join-Path ([System.IO.Path]::GetDirectoryName($ZipPath)) "venera_update.log"
function Log($msg) {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  "$ts  $msg" | Out-File -LiteralPath $logFile -Append -Encoding utf8
}
Log "Update started. ZipPath=$ZipPath TargetDir=$TargetDir ExePath=$ExePath"
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
$requiresElevation = $false
try {
  $probeFile = Join-Path $TargetDir ".venera_update_write_test"
  Set-Content -LiteralPath $probeFile -Value "test" -Encoding utf8
  Remove-Item -LiteralPath $probeFile -Force
} catch { $requiresElevation = $true }
Log "isAdmin=$isAdmin requiresElevation=$requiresElevation"
if ($requiresElevation -and -not $isAdmin) {
  try {
    $qp = { param($s) '"' + $s.Replace('"', '""') + '"' }
    $argString = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $(&$qp $PSCommandPath) -ZipPath $(&$qp $ZipPath) -TargetDir $(&$qp $TargetDir) -ExePath $(&$qp $ExePath)"
    Log "Elevating with args: $argString"
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argString -Wait
  } catch {
    Log "Elevation failed: $_"
    try { Start-Process -FilePath $ExePath } catch {}
  }
  exit
}
$extractDir = Join-Path ([System.IO.Path]::GetDirectoryName($ZipPath)) "venera_update_extract"
if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
New-Item -ItemType Directory -Path $extractDir | Out-Null
Log "Waiting for app to exit..."
$exited = $false
for ($i = 0; $i -lt 120; $i++) {
  try {
    $stream = [System.IO.File]::Open($ExePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $stream.Close()
    $exited = $true
    break
  } catch { Start-Sleep -Milliseconds 500 }
}
if (-not $exited) { Log "WARNING: App exe still locked after 60s, attempting update anyway" }
Start-Sleep -Milliseconds 500
Log "Extracting zip..."
try {
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir -Force
} catch {
  Log "Extract failed: $_"
  try { Start-Process -FilePath $ExePath | Out-Null } catch {}
  exit 1
}
$entries = Get-ChildItem -LiteralPath $extractDir
$sourceDir = $extractDir
if ($entries.Count -eq 1 -and $entries[0].PSIsContainer) { $sourceDir = $entries[0].FullName }
Log "Source dir: $sourceDir (entries: $($entries.Count))"
Log "Copying files to $TargetDir ..."
$copyFailed = $false
try {
  Copy-Item -Path (Join-Path $sourceDir '*') -Destination $TargetDir -Recurse -Force -ErrorAction Stop
  Log "Copy succeeded"
} catch {
  Log "Copy-Item failed: $_"
  $copyFailed = $true
  Log "Retrying with robocopy..."
  try {
    $robocopyArgs = @($sourceDir, $TargetDir, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP', '/IS', '/IT')
    $rc = (Start-Process -FilePath "robocopy.exe" -ArgumentList $robocopyArgs -Wait -PassThru -NoNewWindow).ExitCode
    Log "Robocopy exit code: $rc"
    if ($rc -le 7) { $copyFailed = $false }
  } catch { Log "Robocopy also failed: $_" }
}
if ($copyFailed) { Log "Update FAILED - files not copied" } else { Log "Update completed successfully" }
try { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Log "Starting app..."
try { Start-Process -FilePath $ExePath } catch { Log "Failed to start app: $_" }''';
}
// --- Asset selection ---

_GitHubAsset? _selectAndroidAsset(List<_GitHubAsset> assets) {
  final apkAssets = assets.where((e) => e.isApk).toList();
  if (apkAssets.isEmpty) return null;
  _GitHubAsset? bestAsset;
  var bestScore = 1 << 30;
  for (var asset in apkAssets) {
    var name = asset.lowerName;
    var score = 100;
    if (name.contains("universal")) score -= 80;
    if (name.contains("arm64") || name.contains("armeabi") ||
        name.contains("x86_64") || name.contains("x86")) {
      score += 25;
    }
    if (name.contains("debug")) score += 100;
    if (score < bestScore) {
      bestScore = score;
      bestAsset = asset;
    }
  }
  return bestAsset;
}

_GitHubAsset? _selectWindowsAsset(List<_GitHubAsset> assets) {
  final windowsAssets = assets.where((asset) {
    var name = asset.lowerName;
    return name.contains("windows") || asset.isExe || asset.isZip;
  }).toList();
  final targetAssets = windowsAssets.isNotEmpty ? windowsAssets : assets;

  _GitHubAsset? bestZip;
  var bestZipScore = 1 << 30;
  for (var asset in targetAssets) {
    if (!asset.isZip) continue;
    var name = asset.lowerName;
    var score = 100;
    if (name.contains("windows")) score -= 20;
    if (name.contains("portable")) score -= 10;
    if (isWindowsArm64 && name.contains("arm64")) score -= 30;
    if (!isWindowsArm64 && name.contains("arm64")) score += 50;
    if (score < bestZipScore) {
      bestZipScore = score;
      bestZip = asset;
    }
  }
  if (bestZip != null) return bestZip;

  _GitHubAsset? bestInstaller;
  var bestInstallerScore = 1 << 30;
  for (var asset in targetAssets) {
    if (!asset.isExe) continue;
    var name = asset.lowerName;
    var score = 100;
    if (name.contains("installer") || name.contains("setup")) score -= 40;
    if (name.contains("windows")) score -= 20;
    if (name.contains("portable")) score += 20;
    if (score < bestInstallerScore) {
      bestInstallerScore = score;
      bestInstaller = asset;
    }
  }
  return bestInstaller;
}

// --- Version utilities ---

String _normalizeVersion(String version) {
  var result = version.trim();
  if (result.startsWith("v") || result.startsWith("V")) {
    result = result.substring(1);
  }
  result = result.split("+").first;
  result = result.split("-").first;
  return result;
}

/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  var v1 = _normalizeVersion(version1).split(".");
  var v2 = _normalizeVersion(version2).split(".");
  final length = v1.length > v2.length ? v1.length : v2.length;
  for (var i = 0; i < length; i++) {
    final value1 = i < v1.length ? int.tryParse(v1[i]) ?? 0 : 0;
    final value2 = i < v2.length ? int.tryParse(v2[i]) ?? 0 : 0;
    if (value1 > value2) return true;
    if (value1 < value2) return false;
  }
  return false;
}
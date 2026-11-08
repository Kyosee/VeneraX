import 'dart:async';
import 'dart:io';

import 'windows_updater_ui.dart';

Future<void> main(List<String> args) async {
  final config = _UpdaterConfig.parse(args);
  final logger = _Logger();
  final progress = WindowsUpdaterWindow(
    restart: config.restart,
    iconPath: _join(config.appDir, 'data/flutter_assets/assets/new_logo.png'),
    themeColors: config.themeColors,
    onError: logger.write,
  );
  try {
    if (!Platform.isWindows) {
      throw StateError('Windows updater can only run on Windows.');
    }
    await progress.show();
    final completed = await _runUpdate(config, logger, progress);
    if (completed) {
      progress.update(UpdateStage.complete);
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    await progress.close();
    exit(0);
  } catch (e, s) {
    logger.write('Update failed: $e\n$s');
    progress.update(UpdateStage.failed);
    await progress.waitForClose();
    await progress.close();
    exit(1);
  }
}

Future<bool> _runUpdate(
  _UpdaterConfig config,
  _Logger logger,
  WindowsUpdaterWindow progress,
) async {
  final appDir = Directory(config.appDir);
  if (!appDir.existsSync()) {
    throw StateError('App directory does not exist: ${config.appDir}');
  }

  final selfPath = File(Platform.resolvedExecutable).absolute.path;
  if (!config.fromTemp && _isInside(selfPath, appDir.absolute.path)) {
    await _relaunchFromTemp(config, logger);
    return false;
  }

  if (!await _canWriteTo(appDir)) {
    if (config.elevated) {
      throw StateError('No permission to write app directory.');
    }
    await _relaunchElevated(config, logger);
    return false;
  }

  progress.update(UpdateStage.waiting);
  await _waitForMainProcess(config.pid, logger);

  final stamp = DateTime.now().millisecondsSinceEpoch;
  final workDir = Directory(
    _join(Directory.systemTemp.path, 'venera_update_$stamp'),
  );
  final stagingDir = Directory(_join(workDir.path, 'staging'));
  final backupDir = Directory(
    _join(Directory.systemTemp.path, 'venera_backup_$stamp'),
  );
  await stagingDir.create(recursive: true);
  await backupDir.create(recursive: true);

  final zipFile = File(_join(workDir.path, 'update.zip'));
  if (config.packageFile != null) {
    progress.update(UpdateStage.preparing);
    logger.write('Using local package: ${config.packageFile}');
    final source = File(config.packageFile!);
    await _copyStream(
      source.openRead(),
      zipFile,
      await source.length(),
      progress,
      UpdateStage.preparing,
    );
  } else {
    progress.update(UpdateStage.downloading);
    await _download(config.packageUrl!, zipFile, logger, progress);
  }
  progress.update(UpdateStage.extracting);
  await _expandZip(zipFile, stagingDir, logger);

  final payloadDir = await _findPayloadDir(stagingDir);
  if (payloadDir == null) {
    throw StateError('Update package does not contain venera.exe.');
  }

  progress.update(UpdateStage.backingUp);
  logger.write('Backing up current app.');
  await _copyDirectoryContents(
    appDir,
    backupDir,
    progress,
    UpdateStage.backingUp,
  );

  try {
    progress.update(UpdateStage.installing);
    logger.write('Replacing app files.');
    await _clearDirectory(appDir, preserveUninstaller: true);
    await _copyDirectoryContents(
      payloadDir,
      appDir,
      progress,
      UpdateStage.installing,
    );
  } catch (e) {
    progress.update(UpdateStage.rollingBack);
    logger.write('Replace failed, rolling back: $e');
    await _clearDirectory(appDir, preserveUninstaller: false);
    await _copyDirectoryContents(
      backupDir,
      appDir,
      progress,
      UpdateStage.rollingBack,
    );
    rethrow;
  }

  if (config.restart) {
    final appExe = config.appExe ?? _join(appDir.path, 'venera.exe');
    if (File(appExe).existsSync()) {
      progress.update(UpdateStage.restarting);
      logger.write('Restarting app.');
      await Process.start(
        appExe,
        const [],
        workingDirectory: appDir.path,
        mode: ProcessStartMode.detached,
      );
    }
  }
  return true;
}

Future<void> _relaunchFromTemp(_UpdaterConfig config, _Logger logger) async {
  final tempDir = Directory(_join(Directory.systemTemp.path, 'VeneraUpdater'));
  await tempDir.create(recursive: true);
  final copiedUpdater = File(
    _join(
      tempDir.path,
      'venera_updater_${DateTime.now().millisecondsSinceEpoch}.exe',
    ),
  );
  await File(Platform.resolvedExecutable).copy(copiedUpdater.path);
  logger.write('Relaunching updater from temp.');
  await Process.start(
    copiedUpdater.path,
    config.toArgs(fromTemp: true),
    mode: ProcessStartMode.detached,
  );
}

Future<void> _relaunchElevated(_UpdaterConfig config, _Logger logger) async {
  logger.write('Relaunching updater with administrator permission.');
  final argLine = config
      .toArgs(fromTemp: true, elevated: true)
      .map(_windowsArgQuote)
      .join(' ');
  final command =
      'Start-Process -FilePath ${_psQuote(Platform.resolvedExecutable)} '
      '-ArgumentList ${_psQuote(argLine)} -Verb RunAs';
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    command,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Failed to request administrator permission.');
  }
}

Future<void> _waitForMainProcess(int? pid, _Logger logger) async {
  if (pid == null || pid <= 0) {
    await Future<void>.delayed(const Duration(seconds: 1));
    return;
  }
  logger.write('Waiting for Venera process $pid to exit.');
  for (var i = 0; i < 240; i++) {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '\$p = Get-Process -Id $pid -ErrorAction SilentlyContinue; '
          'if (\$p) { exit 1 } else { exit 0 }',
    ]);
    if (result.exitCode == 0) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw StateError('Timed out waiting for Venera to exit.');
}

Future<void> _download(
  String url,
  File target,
  _Logger logger,
  WindowsUpdaterWindow progress,
) async {
  logger.write('Downloading update package.');
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.userAgentHeader, 'Venera Updater');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw StateError('Download failed with HTTP ${response.statusCode}.');
    }
    await _copyStream(
      response,
      target,
      response.contentLength,
      progress,
      UpdateStage.downloading,
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> _copyStream(
  Stream<List<int>> source,
  File target,
  int total,
  WindowsUpdaterWindow progress,
  UpdateStage stage,
) async {
  var completed = 0;
  progress.update(stage, completed: 0, total: total, unit: 'bytes');
  final sink = target.openWrite();
  try {
    await sink.addStream(
      source.map((chunk) {
        completed += chunk.length;
        progress.update(
          stage,
          completed: completed,
          total: total,
          unit: 'bytes',
        );
        return chunk;
      }),
    );
  } finally {
    await sink.close();
  }
  progress.update(stage, completed: completed, total: completed, unit: 'bytes');
}

Future<void> _expandZip(
  File zipFile,
  Directory stagingDir,
  _Logger logger,
) async {
  logger.write('Extracting update package.');
  final command =
      'Expand-Archive -LiteralPath ${_psQuote(zipFile.path)} '
      '-DestinationPath ${_psQuote(stagingDir.path)} -Force';
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    command,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Extract failed: ${result.stderr}');
  }
}

Future<Directory?> _findPayloadDir(Directory stagingDir) async {
  if (File(_join(stagingDir.path, 'venera.exe')).existsSync()) {
    return stagingDir;
  }
  await for (final entity in stagingDir.list(recursive: true)) {
    if (entity is File &&
        _basename(entity.path).toLowerCase() == 'venera.exe') {
      return entity.parent;
    }
  }
  return null;
}

Future<void> _copyDirectoryContents(
  Directory source,
  Directory target,
  WindowsUpdaterWindow progress,
  UpdateStage stage,
) async {
  await target.create(recursive: true);
  final entries = await source.list(recursive: true).toList();
  final total = entries.whereType<File>().length;
  final prefixLength =
      source.path.length +
      (source.path.endsWith('/') || source.path.endsWith('\\') ? 0 : 1);
  var completed = 0;
  progress.update(stage, completed: completed, total: total, unit: 'files');
  for (final entity in entries) {
    final relativePath = entity.path.substring(prefixLength);
    final newPath = _join(target.path, relativePath);
    if (entity is Directory) {
      await Directory(newPath).create(recursive: true);
    } else if (entity is File) {
      await File(newPath).parent.create(recursive: true);
      await entity.copy(newPath);
      progress.update(
        stage,
        completed: ++completed,
        total: total,
        unit: 'files',
      );
    }
  }
}

Future<void> _clearDirectory(
  Directory directory, {
  required bool preserveUninstaller,
}) async {
  if (!directory.existsSync()) {
    return;
  }
  await for (final entity in directory.list(recursive: false)) {
    final name = _basename(entity.path).toLowerCase();
    if (preserveUninstaller && name.startsWith('unins')) {
      continue;
    }
    await entity.delete(recursive: true);
  }
}

Future<bool> _canWriteTo(Directory directory) async {
  try {
    final probe = File(
      _join(
        directory.path,
        '.venera_update_probe_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await probe.writeAsString('ok');
    await probe.delete();
    return true;
  } catch (_) {
    return false;
  }
}

bool _isInside(String path, String parentPath) {
  final child = File(path).absolute.path.toLowerCase();
  var parent = Directory(parentPath).absolute.path.toLowerCase();
  if (!parent.endsWith(Platform.pathSeparator)) {
    parent = '$parent${Platform.pathSeparator}';
  }
  return child.startsWith(parent);
}

String _join(String first, String second) {
  if (first.endsWith(Platform.pathSeparator)) {
    return '$first$second';
  }
  return '$first${Platform.pathSeparator}$second';
}

String _basename(String path) {
  final normalized = path.replaceAll('/', Platform.pathSeparator);
  return normalized.split(Platform.pathSeparator).last;
}

String _psQuote(String value) {
  return "'${value.replaceAll("'", "''")}'";
}

String _windowsArgQuote(String value) {
  return '"${value.replaceAll('"', r'\"')}"';
}

class _UpdaterConfig {
  const _UpdaterConfig({
    required this.appDir,
    this.packageUrl,
    this.packageFile,
    this.appExe,
    this.pid,
    this.restart = false,
    this.fromTemp = false,
    this.elevated = false,
    this.themeColors,
  });

  final String appDir;
  final String? packageUrl;
  final String? packageFile;
  final String? appExe;
  final int? pid;
  final bool restart;
  final bool fromTemp;
  final bool elevated;
  final String? themeColors;

  static _UpdaterConfig parse(List<String> args) {
    final values = <String, String>{};
    var restart = false;
    var fromTemp = false;
    var elevated = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      switch (arg) {
        case '--restart':
          restart = true;
        case '--from-temp':
          fromTemp = true;
        case '--elevated':
          elevated = true;
        default:
          if (!arg.startsWith('--') || i + 1 >= args.length) {
            throw ArgumentError('Invalid argument: $arg');
          }
          values[arg] = args[++i];
      }
    }
    final appDir = values['--app-dir'];
    if (appDir == null) {
      throw ArgumentError('--app-dir is required.');
    }
    final packageUrl = values['--package-url'];
    final packageFile = values['--package-file'];
    if (packageUrl == null && packageFile == null) {
      throw ArgumentError('--package-url or --package-file is required.');
    }
    return _UpdaterConfig(
      appDir: appDir,
      packageUrl: packageUrl,
      packageFile: packageFile,
      appExe: values['--app-exe'],
      pid: int.tryParse(values['--pid'] ?? ''),
      restart: restart,
      fromTemp: fromTemp,
      elevated: elevated,
      themeColors: values['--theme-colors'],
    );
  }

  List<String> toArgs({bool? fromTemp, bool? elevated}) {
    final result = <String>['--app-dir', appDir];
    if (packageFile != null) {
      result.addAll(['--package-file', packageFile!]);
    } else if (packageUrl != null) {
      result.addAll(['--package-url', packageUrl!]);
    }
    if (appExe != null) {
      result.addAll(['--app-exe', appExe!]);
    }
    if (pid != null) {
      result.addAll(['--pid', pid.toString()]);
    }
    if (restart) {
      result.add('--restart');
    }
    if (themeColors != null) {
      result.addAll(['--theme-colors', themeColors!]);
    }
    if (fromTemp ?? this.fromTemp) {
      result.add('--from-temp');
    }
    if (elevated ?? this.elevated) {
      result.add('--elevated');
    }
    return result;
  }
}

class _Logger {
  _Logger()
    : _file = File(
        _join(
          Directory.systemTemp.path,
          'venera_updater_${DateTime.now().millisecondsSinceEpoch}.log',
        ),
      );

  final File _file;

  void write(String message) {
    final line = '[${DateTime.now().toIso8601String()}] $message';
    // ignore: avoid_print
    print(line);
    try {
      _file.writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {
      // Logging must never fail the update.
    }
  }
}

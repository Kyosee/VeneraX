import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/utils/ext.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart' as s;
import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:venera/utils/file_type.dart';

export 'dart:io';
export 'dart:typed_data';

class IO {
  /// A global flag used to indicate whether the app is selecting files.
  ///
  /// Select file and other similar file operations will launch external programs,
  /// causing the app to lose focus. AppLifecycleState will be set to paused.
  static bool get isSelectingFiles => _isSelectingFiles;

  static bool _isSelectingFiles = false;
}

class FilePath {
  const FilePath._();

  static String join(
    String path1,
    String path2, [
    String? path3,
    String? path4,
    String? path5,
  ]) {
    return p.join(path1, path2, path3, path4, path5);
  }
}

extension FileSystemEntityExt on FileSystemEntity {
  /// Get the base name of the file or directory.
  String get name {
    return p.basename(path);
  }

  /// Delete the file or directory and ignore errors.
  Future<void> deleteIgnoreError({bool recursive = false}) async {
    try {
      await delete(recursive: recursive);
    } catch (e) {
      // ignore
    }
  }

  /// Delete the file or directory if it exists.
  Future<void> deleteIfExists({bool recursive = false}) async {
    if (existsSync()) {
      await delete(recursive: recursive);
    }
  }

  /// Delete the file or directory if it exists.
  void deleteIfExistsSync({bool recursive = false}) {
    if (existsSync()) {
      deleteSync(recursive: recursive);
    }
  }
}

extension FileExtension on File {
  /// Get the file extension, not including the dot.
  String get extension => path.split('.').last;

  /// Copy the file to the specified path using memory.
  ///
  /// This method prevents errors caused by files from different file systems.
  Future<void> copyMem(String newPath) async {
    var newFile = File(newPath);
    // Stream is not usable since [AndroidFile] does not support [openRead].
    await newFile.writeAsBytes(await readAsBytes());
  }

  /// Get the base name of the file without the extension.
  String get basenameWithoutExt {
    return p.basenameWithoutExtension(path);
  }
}

/// Copies [src] into [dst] by streaming fixed-size chunks through a
/// [RandomAccessFile], so a multi-gigabyte file is never fully loaded into
/// memory the way [FileExtension.copyMem] / readAsBytes would (issue #93:
/// merging a large library into a single .venera_comics archive ran out of
/// memory while copying the finished archive into the destination folder).
///
/// Works for both plain files and SAF-backed ([AndroidFile]) destinations:
/// SAF has no usable openRead/openWrite but does implement [RandomAccessFile].
/// [dst] must not already exist — SAF's `create()` returns a detached handle
/// for an existing path (its descriptor stays unset), so any stale file is
/// removed first to keep the write target valid.
Future<void> copyFileStreaming(
  File src,
  File dst, {
  void Function(int copied, int total)? onProgress,
}) async {
  const chunkSize = 8 * 1024 * 1024; // 8 MiB
  if (await dst.exists()) {
    await dst.delete();
  }
  final total = onProgress == null ? 0 : await src.length();
  RandomAccessFile? reader;
  RandomAccessFile? writer;
  var completed = false;
  try {
    await dst.create(recursive: true);
    reader = await src.open();
    writer = await dst.open(mode: FileMode.write);
    var copied = 0;
    while (true) {
      final chunk = await reader.read(chunkSize);
      if (chunk.isEmpty) break;
      await writer.writeFrom(chunk);
      if (onProgress != null) {
        copied += chunk.length;
        onProgress(copied, total);
      }
    }
    await writer.flush();
    completed = true;
  } finally {
    try {
      await reader?.close();
    } catch (_) {}
    try {
      await writer?.close();
    } catch (_) {}
    if (!completed) {
      // Never leave a half-written (or just-created empty) file behind: callers
      // such as the merged-export resume check treat any existing destination as
      // a finished archive, so a partial copy would masquerade as a complete one.
      await dst.deleteIgnoreError();
    }
  }
}

extension DirectoryExtension on Directory {
  /// Calculate the size of the directory.
  Future<int> get size async {
    if (!existsSync()) return 0;
    int total = 0;
    for (var f in listSync(recursive: true)) {
      if (FileSystemEntity.typeSync(f.path) == FileSystemEntityType.file) {
        total += await File(f.path).length();
      }
    }
    return total;
  }

  /// Change the base name of the directory.
  Directory renameX(String newName) {
    newName = sanitizeFileName(newName);
    return renameSync(path.replaceLast(name, newName));
  }

  File joinFile(String name) {
    return File(FilePath.join(path, name));
  }

  /// Delete the contents of the directory.
  void deleteContentsSync({recursive = true}) {
    if (!existsSync()) return;
    for (var f in listSync()) {
      f.deleteIfExistsSync(recursive: recursive);
    }
  }

  /// Delete the contents of the directory.
  Future<void> deleteContents({recursive = true}) async {
    if (!existsSync()) return;
    for (var f in listSync()) {
      await f.deleteIfExists(recursive: recursive);
    }
  }

  /// Create the directory. If the directory already exists, delete it first.
  void forceCreateSync() {
    if (existsSync()) {
      deleteSync(recursive: true);
    }
    createSync(recursive: true);
  }
}

/// Sanitize the file name. Remove invalid characters and trim the file name.
String sanitizeFileName(String fileName, {String? dir, int? maxLength}) {
  while (fileName.endsWith('.')) {
    fileName = fileName.substring(0, fileName.length - 1);
  }
  var length = maxLength ?? 255;
  if (dir != null) {
    if (!dir.endsWith('/') && !dir.endsWith('\\')) {
      dir = "$dir/";
    }
    length -= dir.length;
  }
  final invalidChars = RegExp(r'[<>:"/\\|?*]');
  final sanitizedFileName = fileName.replaceAll(invalidChars, ' ');
  var trimmedFileName = sanitizedFileName.trim();
  if (trimmedFileName.isEmpty) {
    throw Exception('Invalid File Name: Empty length.');
  }
  if (length <= 0) {
    throw Exception('Invalid File Name: Max length is less than 0.');
  }
  if (trimmedFileName.length > length) {
    trimmedFileName = trimmedFileName.substring(0, length);
  }
  return trimmedFileName;
}

/// Copy the **contents** of the source directory to the destination directory.
Future<void> copyDirectory(Directory source, Directory destination) async {
  List<FileSystemEntity> contents = source.listSync();
  for (FileSystemEntity content in contents) {
    String newPath = FilePath.join(destination.path, content.name);

    if (content is File) {
      var resultFile = File(newPath);
      resultFile.createSync();
      var data = content.readAsBytesSync();
      resultFile.writeAsBytesSync(data);
    } else if (content is Directory) {
      Directory newDirectory = Directory(newPath);
      newDirectory.createSync();
      copyDirectory(content.absolute, newDirectory.absolute);
    }
  }
}

/// Copy the **contents** of the source directory to the destination directory.
/// This function is executed in an isolate to prevent the UI from freezing.
Future<void> copyDirectoryIsolate(
  Directory source,
  Directory destination,
) async {
  await Isolate.run(() => overrideIO(() => copyDirectory(source, destination)));
}

String findValidDirectoryName(String path, String directory) {
  var name = sanitizeFileName(directory);
  var dir = Directory("$path/$name");
  var i = 1;
  while (dir.existsSync() && dir.listSync().isNotEmpty) {
    name = sanitizeFileName("$directory($i)");
    dir = Directory("$path/$name");
    i++;
  }
  return name;
}

class DirectoryPicker {
  /// Pick a directory.
  ///
  /// The directory may not be usable after the instance is GCed.
  DirectoryPicker();

  static final _finalizer = Finalizer<String>((path) {
    if (path.startsWith(App.cachePath)) {
      Directory(path).deleteIgnoreError();
    }
    if (App.isIOS || App.isMacOS) {
      _methodChannel.invokeMethod("stopAccessingSecurityScopedResource");
    }
  });

  static const _methodChannel = MethodChannel("venera/method_channel");

  Future<Directory?> pickDirectory({bool directAccess = false}) async {
    IO._isSelectingFiles = true;
    try {
      String? directory;
      if (App.isWindows || App.isLinux) {
        directory = await file_selector.getDirectoryPath();
      } else if (App.isAndroid) {
        directory = (await AndroidDirectory.pickDirectory())?.path;
        if (directory != null && directAccess) {
          // Native library does not have access to the directory. Copy it to cache.
          var cache = FilePath.join(App.cachePath, "selected_directory");
          if (Directory(cache).existsSync()) {
            Directory(cache).deleteSync(recursive: true);
          }
          Directory(cache).createSync();
          await copyDirectoryIsolate(Directory(directory), Directory(cache));
          directory = cache;
        }
      } else {
        // ios, macos
        directory = await _methodChannel.invokeMethod<String?>(
          "getDirectoryPath",
        );
      }
      if (directory == null) return null;
      _finalizer.attach(this, directory);
      return Directory(directory);
    } finally {
      Future.delayed(const Duration(milliseconds: 100), () {
        IO._isSelectingFiles = false;
      });
    }
  }
}

/// Android全文件访问权限（MANAGE_EXTERNAL_STORAGE / R 以下的读写权限）。
///
/// 下载目录若指向共享存储（如 SD 卡、外置存储的自定义目录），没有该权限时
/// dart:io 写入会静默失败——文件看似下完却一个都没落盘（#89）。下载入口在
/// 入队前调用 [ensureGranted] 主动申请，避免用户白下一场。
class StoragePermission {
  StoragePermission._();

  static const _channel = MethodChannel("venera/storage");

  /// 是否已具备写入下载目录所需的存储权限。
  ///
  /// 仅在 Android 上有意义；其它平台恒为 true。通过对目标目录做一次探针写入
  /// 判断——这与 LocalManager 判定路径可用的方式一致，能覆盖“有权限但目录本身
  /// 不可写”的情况。
  static bool isGrantedFor(String dirPath) {
    if (!App.isAndroid) return true;
    try {
      var dir = Directory(dirPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      var probe = File(FilePath.join(dirPath, '.venera_perm_probe'));
      const marker = [0x76, 0x65, 0x6e]; // "ven"
      probe.writeAsBytesSync(marker);
      // Read the bytes back before deleting: without all-files access a write
      // to shared storage can *silently* no-op (the #89 symptom) instead of
      // throwing. A probe that only writes+deletes would be fooled by that and
      // report the folder writable while real downloads land nowhere. Verifying
      // the bytes actually persisted catches both the throw and the no-op case.
      var readBack = probe.existsSync() ? probe.readAsBytesSync() : const <int>[];
      probe.deleteSync();
      return readBack.length == marker.length;
    } catch (_) {
      return false;
    }
  }

  /// 向系统申请全文件访问权限，返回用户是否已授予。
  ///
  /// Android R+ 会跳转到系统的“所有文件访问权限”设置页，等待用户返回后回传
  /// 结果；R 以下走运行时读写权限弹窗。其它平台无操作，直接返回 true。
  static Future<bool> request() async {
    if (!App.isAndroid) return true;
    try {
      var granted = await _channel.invokeMethod<bool>("request");
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 确保下载目录可写：可写则直接放行；不可写则申请权限并复检。
  ///
  /// 返回 true 表示目录已可写（本就可写或用户刚授予）；false 表示仍不可写，
  /// 调用方应中止下载并提示用户。
  static Future<bool> ensureGranted(String dirPath) async {
    if (!App.isAndroid) return true;
    if (isGrantedFor(dirPath)) return true;
    var granted = await request();
    if (!granted) return false;
    return isGrantedFor(dirPath);
  }
}

class IOSDirectoryPicker {
  static const MethodChannel _channel = MethodChannel("venera/method_channel");

  // 调用 iOS 目录选择方法
  static Future<String?> selectDirectory() async {
    IO._isSelectingFiles = true;
    try {
      final String? path = await _channel.invokeMethod('selectDirectory');
      return path;
    } catch (e) {
      // 返回报错信息
      return e.toString();
    } finally {
      Future.delayed(const Duration(milliseconds: 100), () {
        IO._isSelectingFiles = false;
      });
    }
  }
}

Future<FileSelectResult?> selectFile({required List<String> ext}) async {
  IO._isSelectingFiles = true;
  try {
    var extensions = App.isMacOS || App.isIOS ? null : ext;
    file_selector.XTypeGroup typeGroup = file_selector.XTypeGroup(
      label: 'files',
      extensions: extensions,
    );
    FileSelectResult? file;
    if (App.isAndroid) {
      const selectFileChannel = MethodChannel("venera/select_file");
      String mimeType = "*/*";
      if (ext.length == 1) {
        mimeType = FileType.fromExtension(ext[0]).mime;
        if (mimeType == "application/octet-stream") {
          mimeType = "*/*";
        }
      }
      var filePath = await selectFileChannel.invokeMethod(
        "selectFile",
        mimeType,
      );
      if (filePath == null) return null;
      file = FileSelectResult(filePath);
    } else {
      var xFile = await file_selector.openFile(
        acceptedTypeGroups: <file_selector.XTypeGroup>[typeGroup],
      );
      if (xFile == null) return null;
      file = FileSelectResult(xFile.path);
    }
    if (!ext.contains(file.path.split(".").last)) {
      App.rootContext.showMessage(
        message: "Invalid file type: ${file.path.split(".").last}",
      );
      return null;
    }
    return file;
  } finally {
    Future.delayed(const Duration(milliseconds: 100), () {
      IO._isSelectingFiles = false;
    });
  }
}

Future<String?> selectDirectory() async {
  IO._isSelectingFiles = true;
  try {
    var path = await file_selector.getDirectoryPath();
    return path;
  } finally {
    Future.delayed(const Duration(milliseconds: 100), () {
      IO._isSelectingFiles = false;
    });
  }
}

// selectDirectoryIOS
Future<String?> selectDirectoryIOS() async {
  return IOSDirectoryPicker.selectDirectory();
}

Future<void> saveFile({
  Uint8List? data,
  required String filename,
  File? file,
}) async {
  if (data == null && file == null) {
    throw Exception("data and file cannot be null at the same time");
  }
  IO._isSelectingFiles = true;
  try {
    if (data != null) {
      var cache = FilePath.join(App.cachePath, filename);
      if (File(cache).existsSync()) {
        File(cache).deleteSync();
      }
      await File(cache).writeAsBytes(data);
      file = File(cache);
    }
    if (App.isMobile) {
      final params = SaveFileDialogParams(sourceFilePath: file!.path);
      await FlutterFileDialog.saveFile(params: params);
    } else {
      final result = await file_selector.getSaveLocation(
        suggestedName: filename,
      );
      if (result != null) {
        var xFile = file_selector.XFile(file!.path);
        await xFile.saveTo(result.path);
      }
    }
  } finally {
    Future.delayed(const Duration(milliseconds: 100), () {
      IO._isSelectingFiles = false;
    });
  }
}

final class _IOOverrides extends IOOverrides {
  @override
  Directory createDirectory(String path) {
    if (App.isAndroid) {
      var dir = AndroidDirectory.fromPathSync(path);
      if (dir == null) {
        return super.createDirectory(path);
      }
      return dir;
    } else {
      return super.createDirectory(path);
    }
  }

  @override
  File createFile(String path) {
    if (path.startsWith("file://")) {
      path = path.substring(7);
    }
    if (App.isAndroid) {
      var f = AndroidFile.fromPathSync(path);
      if (f == null) {
        return super.createFile(path);
      }
      return f;
    } else {
      return super.createFile(path);
    }
  }
}

T overrideIO<T>(T Function() f) {
  return IOOverrides.runWithIOOverrides<T>(f, _IOOverrides());
}

class Share {
  static void shareFile({
    required Uint8List data,
    required String filename,
    required String mime,
  }) {
    if (!App.isWindows) {
      s.SharePlus.instance.share(
        s.ShareParams(
          files: [s.XFile.fromData(data, mimeType: mime)],
          fileNameOverrides: [filename],
        ),
      );
    } else {
      // write to cache
      var file = File(FilePath.join(App.cachePath, filename));
      file.writeAsBytesSync(data);
      s.SharePlus.instance.share(s.ShareParams(files: [s.XFile(file.path)]));
    }
  }

  static void shareText(String text) {
    s.SharePlus.instance.share(s.ShareParams(text: text));
  }
}

String bytesToReadableString(int bytes) {
  if (bytes < 1024) {
    return "$bytes B";
  } else if (bytes < 1024 * 1024) {
    return "${(bytes / 1024).toStringAsFixed(2)} KB";
  } else if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / 1024 / 1024).toStringAsFixed(2)} MB";
  } else {
    return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
  }
}

/// Maps a disk-full IO error to a user-facing translation key, or null when the
/// error isn't a storage-space problem. Reused by the download error paths so a
/// full disk shows a clear message instead of a raw errno (#18).
String? diskFullMessageKey(Object error) {
  final s = error.toString().toLowerCase();
  if (s.contains('no space') ||
      s.contains('enospc') ||
      s.contains('errno = 28') ||
      s.contains('errno=28') ||
      s.contains('os error 28')) {
    return 'Not enough storage space';
  }
  return null;
}

class FileSelectResult {
  final String path;

  static final _finalizer = Finalizer<String>((path) {
    if (path.startsWith(App.cachePath)) {
      File(path).deleteIgnoreError();
    }
  });

  FileSelectResult(this.path) {
    _finalizer.attach(this, path);
  }

  Future<void> saveTo(String path) async {
    await File(this.path).copy(path);
  }

  Future<Uint8List> readAsBytes() {
    return File(path).readAsBytes();
  }

  String get name => File(path).name;
}

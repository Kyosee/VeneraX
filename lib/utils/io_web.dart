// Web stubs for dart:io-dependent IO utilities.
import 'dart:js_interop';
import 'dart:typed_data';

export 'dart:typed_data';
export 'io_compat_web.dart' show File, Directory, FileStat, IOSink, exit;

int get pid => 0;

class IO {
  static bool get isSelectingFiles => false;
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
    final parts = [
      path1,
      path2,
      path3,
      path4,
      path5,
    ].whereType<String>().where((s) => s.isNotEmpty);
    return parts.join('/');
  }
}

String sanitizeFileName(String fileName, {String? dir, int? maxLength}) {
  while (fileName.endsWith('.')) {
    fileName = fileName.substring(0, fileName.length - 1);
  }
  final invalidChars = RegExp(r'[<>:"/\\|?*]');
  var result = fileName.replaceAll(invalidChars, ' ').trim();
  if (result.isEmpty) throw Exception('Invalid File Name: Empty length.');
  final limit = maxLength ?? 255;
  if (result.length > limit) result = result.substring(0, limit);
  return result;
}

String bytesToReadableString(int bytes) {
  if (bytes < 1024) return "$bytes B";
  if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(2)} KB";
  if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / 1024 / 1024).toStringAsFixed(2)} MB";
  }
  return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
}

class FileSelectResult {
  final String path;
  FileSelectResult(this.path);
  Future<void> saveTo(String dest) async {}
  Future<Uint8List> readAsBytes() async => Uint8List(0);
  String get name => path.split('/').last;
}

Future<FileSelectResult?> selectFile({required List<String> ext}) async => null;
Future<String?> selectDirectory() async => null;
Future<String?> selectDirectoryIOS() async => null;
Future<void> saveFile({
  Uint8List? data,
  required String filename,
  dynamic file,
}) async {
  if (data == null) return;
  _webDownloadBytes(data, filename);
}

@JS('eval')
external JSFunction _jsEval(String code);

void _webDownloadBytes(Uint8List data, String filename) {
  final downloadFn = _jsEval('''(function(bytes, name) {
      var blob = new Blob([bytes], {type: 'application/octet-stream'});
      var url = URL.createObjectURL(blob);
      var a = document.createElement('a');
      a.href = url;
      a.download = name;
      a.style.display = 'none';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    })''');
  downloadFn.callAsFunction(null, data.toJS, filename.toJS);
}

class Share {
  static void shareFile({
    required Uint8List data,
    required String filename,
    required String mime,
  }) {}
  static void shareText(String text) {}
}

class DirectoryPicker {
  DirectoryPicker();
  Future<dynamic> pickDirectory({bool directAccess = false}) async => null;
}

class IOSDirectoryPicker {
  static Future<String?> selectDirectory() async => null;
}

Future<void> copyDirectory(dynamic source, dynamic destination) async {}
Future<void> copyDirectoryIsolate(dynamic source, dynamic destination) async {}

String findValidDirectoryName(String path, String directory) {
  return sanitizeFileName(directory);
}

dynamic overrideIO<T>(T Function() f) => f();

class Platform {
  static String get resolvedExecutable => '';
  static bool get isWindows => false;
  static bool get isMacOS => false;
  static bool get isLinux => false;
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isFuchsia => false;
  static String get operatingSystem => 'web';
  static String get pathSeparator => '/';
  static Map<String, String> get environment => const {};
}

enum ProcessStartMode { normal, detached, detachedWithStdio, inheritStdio }

class ProcessResult {
  final int exitCode;
  final String stdout;
  final String stderr;
  const ProcessResult(this.exitCode, this.stdout, this.stderr);
}

class Process {
  static Future<Process> start(
    String executable,
    List<String> arguments, {
    ProcessStartMode mode = ProcessStartMode.normal,
    Map<String, String>? environment,
    String? workingDirectory,
    bool runInShell = false,
  }) async => Process._();

  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool runInShell = false,
  }) async => const ProcessResult(0, '', '');

  Process._();
}

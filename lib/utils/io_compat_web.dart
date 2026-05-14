// Lightweight virtual file system for Flutter web.
//
// This is intentionally limited to APIs used by the app on web:
// - appdata json files
// - comic source scripts and source data files
//
// Data is persisted in `window.localStorage`.
//
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

void exit(int code) {}

class FileStat {
  final DateTime modified;
  const FileStat(this.modified);
}

const _kVfsStorageKey = 'venera_vfs_v1';

bool _vfsReady = false;
final Map<String, _VfsFileEntry> _vfsFiles = <String, _VfsFileEntry>{};
final Set<String> _vfsDirs = <String>{'/'};

class _VfsFileEntry {
  Uint8List bytes;
  DateTime modified;

  _VfsFileEntry({required this.bytes, required this.modified});
}

void _ensureVfsReady() {
  if (_vfsReady) return;
  _vfsReady = true;
  try {
    final raw = html.window.localStorage[_kVfsStorageKey];
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return;

    final dirs = decoded['dirs'];
    if (dirs is List) {
      for (final dir in dirs) {
        if (dir is String) {
          _vfsDirs.add(_normalizePath(dir));
        }
      }
    }

    final files = decoded['files'];
    if (files is Map) {
      files.forEach((rawPath, rawInfo) {
        if (rawPath is! String || rawInfo is! Map) return;
        final data = rawInfo['data'];
        final modified = rawInfo['modified'];
        if (data is! String) return;

        try {
          final bytes = base64Decode(data);
          final modifiedMs = (modified as num?)?.toInt() ?? 0;
          _vfsFiles[_normalizePath(rawPath)] = _VfsFileEntry(
            bytes: Uint8List.fromList(bytes),
            modified: DateTime.fromMillisecondsSinceEpoch(modifiedMs),
          );
        } catch (_) {
          // Ignore broken entries.
        }
      });
    }
  } catch (_) {
    // Ignore parse/storage errors.
  }

  _vfsDirs.add('/');
}

void _persistVfs() {
  try {
    final json = <String, dynamic>{
      'dirs': _vfsDirs.toList()..sort(),
      'files': <String, dynamic>{},
    };
    final files = json['files'] as Map<String, dynamic>;
    final paths = _vfsFiles.keys.toList()..sort();
    for (final path in paths) {
      final entry = _vfsFiles[path]!;
      files[path] = <String, dynamic>{
        'data': base64Encode(entry.bytes),
        'modified': entry.modified.millisecondsSinceEpoch,
      };
    }
    html.window.localStorage[_kVfsStorageKey] = jsonEncode(json);
  } catch (_) {
    // Ignore quota/storage errors.
  }
}

String _normalizePath(String rawPath) {
  var path = rawPath.replaceAll('\\', '/').trim();
  if (path.startsWith('file://')) {
    path = path.substring(7);
  }
  if (path.isEmpty) return '/';
  if (!path.startsWith('/')) {
    path = '/$path';
  }
  while (path.contains('//')) {
    path = path.replaceAll('//', '/');
  }
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return path;
}

String _parentPath(String path) {
  if (path == '/') return '/';
  final idx = path.lastIndexOf('/');
  if (idx <= 0) return '/';
  return path.substring(0, idx);
}

String _childName(String path) {
  if (path == '/') return '/';
  final idx = path.lastIndexOf('/');
  return idx == -1 ? path : path.substring(idx + 1);
}

String _dirPrefix(String dir) => dir == '/' ? '/' : '$dir/';

bool _isDirectChild(String parentDir, String childPath) {
  final prefix = _dirPrefix(parentDir);
  if (!childPath.startsWith(prefix) || childPath == parentDir) {
    return false;
  }
  final rest = childPath.substring(prefix.length);
  return rest.isNotEmpty && !rest.contains('/');
}

void _ensureDirectory(String dirPath) {
  final path = _normalizePath(dirPath);
  if (_vfsDirs.contains(path)) return;
  if (path != '/') {
    _ensureDirectory(_parentPath(path));
  }
  _vfsDirs.add(path);
}

bool _directoryHasChildren(String dirPath) {
  final prefix = _dirPrefix(dirPath);
  return _vfsDirs.any((d) => d != dirPath && d.startsWith(prefix)) ||
      _vfsFiles.keys.any((f) => f.startsWith(prefix));
}

void _deleteDirectoryRecursively(String dirPath) {
  if (dirPath == '/') {
    _vfsFiles.clear();
    _vfsDirs
      ..clear()
      ..add('/');
    _persistVfs();
    return;
  }

  final prefix = _dirPrefix(dirPath);
  final filesToDelete = _vfsFiles.keys
      .where((f) => f.startsWith(prefix))
      .toList();
  for (final path in filesToDelete) {
    _vfsFiles.remove(path);
  }

  final dirsToDelete = _vfsDirs
      .where((d) => d == dirPath || d.startsWith(prefix))
      .toList();
  for (final dir in dirsToDelete) {
    _vfsDirs.remove(dir);
  }
  _vfsDirs.add('/');
  _persistVfs();
}

class File {
  final String path;

  File(String rawPath) : path = _normalizePath(rawPath);

  File get absolute => File(path);

  Uri get uri => Uri(path: path);

  String get extension {
    final name = _childName(path);
    final idx = name.lastIndexOf('.');
    if (idx < 0) return '';
    return name.substring(idx + 1);
  }

  String get name => _childName(path);

  Directory get parent => Directory(_parentPath(path));

  bool existsSync() {
    _ensureVfsReady();
    return _vfsFiles.containsKey(path);
  }

  Future<bool> exists() async => existsSync();

  Future<File> create({bool recursive = false, bool exclusive = false}) async {
    createSync(recursive: recursive, exclusive: exclusive);
    return this;
  }

  void createSync({bool recursive = false, bool exclusive = false}) {
    _ensureVfsReady();
    if (exclusive && existsSync()) {
      throw StateError('File already exists: $path');
    }
    final parent = _parentPath(path);
    if (!_vfsDirs.contains(parent)) {
      if (!recursive) {
        throw StateError('Parent directory does not exist: $parent');
      }
      _ensureDirectory(parent);
    }
    _vfsFiles[path] = _VfsFileEntry(
      bytes: _vfsFiles[path]?.bytes ?? Uint8List(0),
      modified: DateTime.now(),
    );
    _persistVfs();
  }

  Future<File> writeAsString(
    String contents, {
    dynamic mode,
    dynamic encoding,
    bool flush = false,
  }) async {
    final codec = (encoding is Encoding) ? encoding : utf8;
    return writeAsBytes(codec.encode(contents), mode: mode, flush: flush);
  }

  void writeAsStringSync(
    String contents, {
    dynamic mode,
    dynamic encoding,
    bool flush = false,
  }) {
    final codec = (encoding is Encoding) ? encoding : utf8;
    writeAsBytesSync(codec.encode(contents), mode: mode, flush: flush);
  }

  Future<File> writeAsBytes(
    List<int> bytes, {
    dynamic mode,
    bool flush = false,
  }) async {
    _ensureVfsReady();
    final parent = _parentPath(path);
    _ensureDirectory(parent);
    _vfsFiles[path] = _VfsFileEntry(
      bytes: Uint8List.fromList(bytes),
      modified: DateTime.now(),
    );
    _persistVfs();
    return this;
  }

  void writeAsBytesSync(List<int> bytes, {dynamic mode, bool flush = false}) {
    _ensureVfsReady();
    final parent = _parentPath(path);
    _ensureDirectory(parent);
    _vfsFiles[path] = _VfsFileEntry(
      bytes: Uint8List.fromList(bytes),
      modified: DateTime.now(),
    );
    _persistVfs();
  }

  String readAsStringSync({dynamic encoding}) {
    final codec = (encoding is Encoding) ? encoding : utf8;
    final bytes = readAsBytesSync();
    return codec.decode(bytes);
  }

  Future<String> readAsString({dynamic encoding}) async =>
      readAsStringSync(encoding: encoding);

  Future<Uint8List> readAsBytes() async => readAsBytesSync();

  Uint8List readAsBytesSync() {
    _ensureVfsReady();
    final entry = _vfsFiles[path];
    if (entry == null) {
      throw StateError('File not found: $path');
    }
    return Uint8List.fromList(entry.bytes);
  }

  Future<List<String>> readAsLines({dynamic encoding}) async {
    return const LineSplitter().convert(readAsStringSync(encoding: encoding));
  }

  Future<int> length() async => readAsBytesSync().length;

  FileStat statSync() {
    _ensureVfsReady();
    final entry = _vfsFiles[path];
    return FileStat(entry?.modified ?? DateTime.fromMillisecondsSinceEpoch(0));
  }

  IOSink openWrite({dynamic mode, dynamic encoding}) {
    final codec = (encoding is Encoding) ? encoding : utf8;
    return IOSink((data) async {
      await writeAsBytes(data);
      return;
    }, codec: codec);
  }

  Stream<List<int>> openRead([int? start, int? end]) async* {
    final bytes = readAsBytesSync();
    final from = (start ?? 0).clamp(0, bytes.length);
    final to = end == null ? bytes.length : (end + 1).clamp(from, bytes.length);
    yield bytes.sublist(from, to);
  }

  Future<void> delete({bool recursive = false}) async {
    deleteSync(recursive: recursive);
  }

  void deleteSync({bool recursive = false}) {
    _ensureVfsReady();
    _vfsFiles.remove(path);
    _persistVfs();
  }

  Future<void> deleteIgnoreError({bool recursive = false}) async {
    try {
      deleteSync(recursive: recursive);
    } catch (_) {}
  }

  Future<void> deleteIfExists({bool recursive = false}) async {
    if (existsSync()) {
      deleteSync(recursive: recursive);
    }
  }

  void deleteIfExistsSync({bool recursive = false}) {
    if (existsSync()) {
      deleteSync(recursive: recursive);
    }
  }

  Future<File> copy(String newPath) async {
    final file = File(newPath);
    await file.writeAsBytes(readAsBytesSync());
    return file;
  }

  Future<File> rename(String newPath) async {
    renameSync(newPath);
    return File(newPath);
  }

  void renameSync(String newPath) {
    _ensureVfsReady();
    final entry = _vfsFiles[path];
    if (entry == null) {
      throw StateError('File not found: $path');
    }
    final target = _normalizePath(newPath);
    _ensureDirectory(_parentPath(target));
    _vfsFiles[target] = _VfsFileEntry(
      bytes: Uint8List.fromList(entry.bytes),
      modified: DateTime.now(),
    );
    _vfsFiles.remove(path);
    _persistVfs();
  }
}

class Directory {
  final String path;

  Directory(String rawPath) : path = _normalizePath(rawPath);

  Directory get absolute => Directory(path);

  Directory get parent => Directory(_parentPath(path));

  File joinFile(String name) => File('$path/$name');

  bool existsSync() {
    _ensureVfsReady();
    if (_vfsDirs.contains(path)) return true;
    return _directoryHasChildren(path);
  }

  Future<bool> exists() async => existsSync();

  Future<Directory> create({bool recursive = false}) async {
    createSync(recursive: recursive);
    return this;
  }

  void createSync({bool recursive = false}) {
    _ensureVfsReady();
    if (recursive) {
      _ensureDirectory(path);
      _persistVfs();
      return;
    }
    final parent = _parentPath(path);
    if (!_vfsDirs.contains(parent)) {
      throw StateError('Parent directory does not exist: $parent');
    }
    _vfsDirs.add(path);
    _persistVfs();
  }

  List<dynamic> listSync({bool recursive = false}) {
    _ensureVfsReady();
    final result = <dynamic>[];
    final seen = <String>{};

    final dirCandidates = _vfsDirs.toList()..sort();
    for (final dir in dirCandidates) {
      if (dir == path) continue;
      if (!dir.startsWith(_dirPrefix(path))) continue;
      if (!recursive && !_isDirectChild(path, dir)) continue;
      if (seen.add(dir)) {
        result.add(Directory(dir));
      }
    }

    final fileCandidates = _vfsFiles.keys.toList()..sort();
    for (final file in fileCandidates) {
      if (!file.startsWith(_dirPrefix(path))) continue;
      if (!recursive && !_isDirectChild(path, file)) continue;
      if (seen.add(file)) {
        result.add(File(file));
      }
    }

    return result;
  }

  Stream<dynamic> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    for (final entity in listSync(recursive: recursive)) {
      yield entity;
    }
  }

  Future<void> delete({bool recursive = false}) async {
    deleteSync(recursive: recursive);
  }

  void deleteSync({bool recursive = false}) {
    _ensureVfsReady();
    if (!recursive && _directoryHasChildren(path)) {
      throw StateError('Directory is not empty: $path');
    }
    if (recursive) {
      _deleteDirectoryRecursively(path);
      return;
    }
    _vfsDirs.remove(path);
    _persistVfs();
  }

  Future<void> deleteIgnoreError({bool recursive = false}) async {
    try {
      deleteSync(recursive: recursive);
    } catch (_) {}
  }
}

class IOSink {
  final Future<void> Function(Uint8List bytes) _onClose;
  final Encoding codec;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  IOSink(this._onClose, {this.codec = utf8});

  void add(List<int> data) {
    _builder.add(data);
  }

  void write(Object? object) {
    _builder.add(codec.encode(object?.toString() ?? ''));
  }

  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  Future<void> flush() async {}

  Future<void> close() async {
    final data = _builder.takeBytes();
    await _onClose(Uint8List.fromList(data));
  }
}

class Isolate {
  static Future<T> run<T>(Future<T> Function() computation) => computation();
}

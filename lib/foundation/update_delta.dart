import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'update_bsdiff.dart';
import 'update_manifest.dart';

/// Hashes off the UI isolate; installed APKs and packages reach 100 MB.
Future<String> updateFileDigest(File file) {
  final path = file.path;
  return Isolate.run(() => _digest(File(path), () {}));
}

/// Probes for cancellation at most once per [interval]. A stat per BSDIFF40
/// control tuple dominated Windows preparation time.
void Function() throttledCancellation(
  bool Function() cancelled, {
  Duration interval = const Duration(milliseconds: 100),
}) {
  final clock = Stopwatch()..start();
  var next = Duration.zero;
  return () {
    final now = clock.elapsed;
    if (now < next) return;
    next = now + interval;
    if (cancelled()) throw const FileSystemException('Update cancelled');
  };
}

/// Cancellation is cooperative so no open writer races with attempt cleanup.
Future<File> prepareDeltaUpdate({
  required UpdateDelta delta,
  required String sourcePath,
  required File patch,
  required Directory workDirectory,
  required int fullSize,
  required CancelToken cancelToken,
}) async {
  if (!safeAssetName(delta.fullAsset) ||
      !['android', 'windows'].contains(delta.platform) ||
      fullSize <= 0 ||
      fullSize > maxUpdateFileSize) {
    throw const FormatException('Invalid delta target');
  }
  final output = File(p.join(workDirectory.path, delta.fullAsset));
  if (output.existsSync()) {
    throw const FileSystemException('Update output already exists');
  }
  final cancelFile = File(p.join(workDirectory.path, 'cancel'));
  var active = true;
  unawaitedCancel() async {
    await cancelToken.whenCancel;
    try {
      if (active && workDirectory.existsSync()) {
        cancelFile.writeAsStringSync('');
      }
    } on FileSystemException {
      // A full disk can prevent the signal; still await the worker before cleanup.
    }
  }

  // The completion observer is intentionally independent of the worker.
  unawaitedCancel();
  try {
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    final outputPath = output.path;
    await _runDeltaWorker(
      delta,
      sourcePath,
      patch.path,
      outputPath,
      workDirectory.path,
      cancelFile.path,
      fullSize,
    );
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    return File(outputPath);
  } catch (_) {
    if (output.existsSync()) output.deleteSync();
    rethrow;
  } finally {
    active = false;
    if (cancelFile.existsSync()) cancelFile.deleteSync();
  }
}

Future<void> _runDeltaWorker(
  UpdateDelta delta,
  String sourcePath,
  String patchPath,
  String outputPath,
  String workPath,
  String cancelPath,
  int fullSize,
) => Isolate.run(() {
  final patch = File(patchPath);
  final workDirectory = Directory(workPath);
  final check = throttledCancellation(() => File(cancelPath).existsSync());

  check();
  if (_digest(patch, check) != delta.patchSha256) {
    throw const FormatException('Update patch verification failed');
  }
  if (delta.platform == 'android') {
    final old = File(sourcePath);
    if (_digest(old, check) != delta.oldSha256) {
      throw const FormatException('Installed package does not match delta');
    }
    applyBsdiff(
      oldFile: old,
      patchFile: patch,
      outputFile: File(outputPath),
      expectedSize: fullSize,
      checkCancelled: check,
    );
    if (_digest(File(outputPath), check) != delta.fullSha256) {
      throw const FormatException('Reconstructed package verification failed');
    }
  } else {
    _prepareWindows(
      delta,
      Directory(sourcePath),
      patch,
      File(outputPath),
      workDirectory,
      check,
    );
  }
  check();
});

String _digest(File file, void Function() check) {
  final input = file.openSync();
  final output = _DigestSink();
  final sink = sha256.startChunkedConversion(output);
  try {
    while (true) {
      check();
      final bytes = input.readSync(256 * 1024);
      if (bytes.isEmpty) break;
      sink.add(bytes);
    }
    sink.close();
    return output.value.toString();
  } finally {
    input.closeSync();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

File _installedFile(Directory root, String relative) {
  var current = root.path;
  for (final part in relative.split('/')) {
    current = p.join(current, part);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('Installed update input contains a link');
    }
  }
  final file = File(current);
  if (!p.isWithin(
    root.resolveSymbolicLinksSync(),
    file.resolveSymbolicLinksSync(),
  )) {
    throw const FormatException('Installed update input escapes app directory');
  }
  return file;
}

void _prepareWindows(
  UpdateDelta delta,
  Directory source,
  File patch,
  File output,
  Directory work,
  void Function() check,
) {
  InputFileStream? input;
  ZipFileEncoder? encoder;
  final payload = Directory(p.join(work.path, 'payload'));
  try {
    payload.createSync();
    input = InputFileStream(patch.path);
    final directory = ZipDirectory()..read(input);
    if (directory.fileHeaders.length > 20000) {
      throw const FormatException('Too many update files');
    }
    final entries = <String, ArchiveFile>{};
    for (final header in directory.fileHeaders) {
      final sourceFile = header.file;
      if (sourceFile == null ||
          header.filename != sourceFile.filename ||
          (header.externalFileAttributes >> 16) & 0xf000 == 0xa000 ||
          header.generalPurposeBitFlag & 1 != 0 ||
          header.uncompressedSize != sourceFile.uncompressedSize) {
        throw const FormatException('Unsafe update archive header');
      }
      final file = ArchiveFile.file(
        sourceFile.filename,
        sourceFile.uncompressedSize,
        sourceFile,
      );
      if (!file.isFile ||
          file.isSymbolicLink ||
          !safeUpdatePath(file.name) ||
          entries.containsKey(file.name.toLowerCase()) ||
          file.size < 0 ||
          file.size > maxUpdateFileSize) {
        throw const FormatException('Unsafe update archive');
      }
      entries[file.name.toLowerCase()] = file;
    }
    final metadata = entries.remove('delta.json');
    if (metadata == null || metadata.size > 4 * 1024 * 1024) {
      throw const FormatException('Missing update file list');
    }
    final metadataFile = File(p.join(work.path, 'delta.json'));
    final metadataOutput = BoundedUpdateOutput(
      metadataFile.path,
      metadata.size,
      check,
    );
    try {
      metadata.writeContent(metadataOutput);
      if (metadataOutput.length != metadata.size) {
        throw const FormatException('Truncated update metadata');
      }
    } finally {
      metadataOutput.closeSync();
    }
    final data = jsonDecode(metadataFile.readAsStringSync());
    if (data is! Map ||
        data['schema'] != 1 ||
        data['fromVersion'] != delta.fromVersion ||
        data['toVersion'] != delta.toVersion ||
        data['files'] is! List ||
        (data['files'] as List).length > 10000) {
      throw const FormatException('Invalid update file list');
    }
    final names = <String>{};
    var totalSize = 0;
    for (final item in data['files'] as List) {
      check();
      if (item is! Map ||
          item['path'] is! String ||
          !safeUpdatePath(item['path']) ||
          !names.add((item['path'] as String).toLowerCase()) ||
          item['size'] is! int ||
          item['size'] < 0 ||
          item['size'] > maxUpdateFileSize ||
          !validUpdateDigest(item['sha256']) ||
          p.basename(item['path']).toLowerCase().startsWith('unins')) {
        throw const FormatException('Invalid update file');
      }
      totalSize += item['size'] as int;
      if (totalSize > 2 * 1024 * 1024 * 1024) {
        throw const FormatException('Update too large');
      }
      final target = File(p.join(payload.path, item['path']))
        ..parent.createSync(recursive: true);
      final mode = item['mode'];
      if (mode == 'copy' || mode == 'bsdiff') {
        if (!validUpdateDigest(item['oldSha256'])) {
          throw const FormatException('Missing old digest');
        }
        final old = _installedFile(source, item['path']);
        if (_digest(old, check) != item['oldSha256']) {
          throw const FormatException('Installed file does not match delta');
        }
        if (mode == 'copy') {
          old.copySync(target.path);
        } else {
          final block = _extractBlock(entries, item['payload'], work, check);
          try {
            applyBsdiff(
              oldFile: old,
              patchFile: block,
              outputFile: target,
              expectedSize: item['size'],
              checkCancelled: check,
            );
          } finally {
            block.deleteSync();
          }
        }
      } else if (mode == 'full') {
        final block = _extractBlock(entries, item['payload'], work, check);
        block.renameSync(target.path);
      } else {
        throw const FormatException('Unknown update file mode');
      }
      if (target.lengthSync() != item['size'] ||
          _digest(target, check) != item['sha256']) {
        throw const FormatException('Reconstructed update file mismatch');
      }
    }
    if (entries.isNotEmpty ||
        !names.contains('venera.exe') ||
        !names.contains('data/app.so')) {
      throw const FormatException('Incomplete Windows update');
    }
    encoder = ZipFileEncoder()..create(output.path);
    for (final item in data['files'] as List) {
      check();
      final stream = InputFileStream(p.join(payload.path, item['path']));
      try {
        encoder.addArchiveFile(
          ArchiveFile.stream(item['path'], stream)
            ..compression = CompressionType.none,
        );
      } finally {
        stream.closeSync();
      }
    }
  } finally {
    try {
      encoder?.closeSync();
    } finally {
      try {
        input?.closeSync();
      } finally {
        if (payload.existsSync()) payload.deleteSync(recursive: true);
      }
    }
  }
}

File _extractBlock(
  Map<String, ArchiveFile> entries,
  Object? name,
  Directory work,
  void Function() check,
) {
  if (name is! String || !RegExp(r'^payload/[0-9]+$').hasMatch(name)) {
    throw const FormatException('Invalid update payload name');
  }
  final entry = entries.remove(name);
  if (entry == null) throw const FormatException('Missing update payload');
  final file = File(p.join(work.path, 'block'));
  final stream = BoundedUpdateOutput(file.path, entry.size, check);
  try {
    entry.writeContent(stream);
    if (stream.length != entry.size) {
      throw const FormatException('Invalid payload length');
    }
  } finally {
    stream.closeSync();
  }
  return file;
}

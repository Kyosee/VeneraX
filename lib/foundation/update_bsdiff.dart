import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

const maxUpdateFileSize = 512 * 1024 * 1024;

/// Applies the standard BSDIFF40 format without loading whole packages in RAM.
/// Run in an isolate. The caller authenticates both inputs and the final output.
void applyBsdiff({
  required File oldFile,
  required File patchFile,
  required File outputFile,
  required int expectedSize,
  void Function()? checkCancelled,
}) {
  if (expectedSize < 0 || expectedSize > maxUpdateFileSize) {
    throw const FormatException('Invalid update size');
  }
  final outputPath = p.join(
    outputFile.parent.resolveSymbolicLinksSync(),
    p.basename(outputFile.path),
  );
  if (p.equals(outputPath, oldFile.resolveSymbolicLinksSync()) ||
      p.equals(outputPath, patchFile.resolveSymbolicLinksSync()) ||
      FileSystemEntity.typeSync(outputFile.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
    throw const FileSystemException('Update output must be a new file');
  }
  final scratch = outputFile.parent.createTempSync('bsdiff-');
  final handles = <RandomAccessFile>[];
  InputFileStream? patch;
  var completed = false;
  try {
    patch = InputFileStream(patchFile.path);
    final patchSize = patch.length;
    if (patchSize < 32) {
      throw const FormatException('Truncated BSDIFF40 header');
    }
    final header = patch.readBytes(32).toUint8List();
    if (String.fromCharCodes(header.take(8)) != 'BSDIFF40') {
      throw const FormatException('Invalid BSDIFF40 header');
    }
    final controlSize = _signedOffset(header, 8);
    final diffSize = _signedOffset(header, 16);
    final newSize = _signedOffset(header, 24);
    if (newSize != expectedSize ||
        controlSize < 0 ||
        diffSize < 0 ||
        controlSize > patchSize - 32 ||
        diffSize > patchSize - 32 - controlSize) {
      throw const FormatException('Invalid BSDIFF40 block lengths');
    }
    final lengths = [
      controlSize,
      diffSize,
      patchSize - 32 - controlSize - diffSize,
    ];
    final limits = [
      min(24 * (expectedSize + 1), 24 * 1000000),
      expectedSize,
      expectedSize,
    ];
    var offset = 32;
    for (var i = 0; i < 3; i++) {
      final block = InputFileStream.fromFileStream(
        patch,
        position: offset,
        length: lengths[i],
      );
      checkCancelled?.call();
      final target = BoundedUpdateOutput(
        p.join(scratch.path, '$i'),
        limits[i],
        checkCancelled,
      );
      try {
        if (!BZip2Decoder().decodeStream(block, target, verify: true)) {
          throw const FormatException('Invalid BSDIFF40 compressed block');
        }
      } finally {
        target.closeSync();
      }
      offset += lengths[i];
      handles.add(File(p.join(scratch.path, '$i')).openSync());
    }
    final control = handles[0];
    final diff = handles[1];
    final extra = handles[2];
    if (control.lengthSync() % 24 != 0) {
      throw const FormatException('Invalid BSDIFF40 controls');
    }
    final old = oldFile.openSync();
    handles.add(old);
    final output = outputFile.openSync(mode: FileMode.writeOnly);
    handles.add(output);
    final oldSize = old.lengthSync();
    var oldPosition = 0;
    var newPosition = 0;
    while (newPosition < newSize) {
      checkCancelled?.call();
      final tuple = _readExactly(control, 24);
      final add = _signedOffset(tuple, 0);
      final copy = _signedOffset(tuple, 8);
      final seek = _signedOffset(tuple, 16);
      if (add < 0 ||
          copy < 0 ||
          add > newSize - newPosition ||
          copy > newSize - newPosition - add ||
          (add + copy == 0 && seek == 0) ||
          seek.abs() > maxUpdateFileSize * 2) {
        throw const FormatException('Invalid BSDIFF40 control tuple');
      }
      var remaining = add;
      while (remaining > 0) {
        checkCancelled?.call();
        final count = min(remaining, 64 * 1024);
        final bytes = _readExactly(diff, count);
        final start = max(0, -oldPosition);
        final end = min(count, oldSize - oldPosition);
        if (end > start) {
          old.setPositionSync(oldPosition + start);
          final previous = _readExactly(old, end - start);
          for (var i = start; i < end; i++) {
            bytes[i] = (bytes[i] + previous[i - start]) & 0xff;
          }
        }
        output.writeFromSync(bytes);
        oldPosition += count;
        newPosition += count;
        remaining -= count;
      }
      remaining = copy;
      while (remaining > 0) {
        checkCancelled?.call();
        final count = min(remaining, 64 * 1024);
        output.writeFromSync(_readExactly(extra, count));
        newPosition += count;
        remaining -= count;
      }
      oldPosition += seek;
      if (oldPosition.abs() > maxUpdateFileSize * 2) {
        throw const FormatException('Invalid BSDIFF40 old offset');
      }
    }
    for (final stream in [control, diff, extra]) {
      if (stream.positionSync() != stream.lengthSync()) {
        throw const FormatException('Unused BSDIFF40 block data');
      }
    }
    output.flushSync();
    completed = true;
  } finally {
    for (final handle in handles.reversed) {
      handle.closeSync();
    }
    patch?.closeSync();
    try {
      scratch.deleteSync(recursive: true);
    } finally {
      if (!completed && outputFile.existsSync()) outputFile.deleteSync();
    }
  }
}

int _signedOffset(List<int> bytes, int offset) {
  var result = bytes[offset + 7] & 0x7f;
  for (var i = 6; i >= 0; i--) {
    result = result * 256 + bytes[offset + i];
  }
  return (bytes[offset + 7] & 0x80) != 0 ? -result : result;
}

Uint8List _readExactly(RandomAccessFile file, int length) {
  final bytes = file.readSync(length);
  if (bytes.length != length) {
    throw const FormatException('Truncated BSDIFF40 data');
  }
  return bytes;
}

/// Bounds decompression before disk exhaustion, including malformed controls.
class BoundedUpdateOutput extends OutputStream {
  BoundedUpdateOutput(String path, this.limit, this.checkCancelled)
    : _output = OutputFileStream(path),
      super(byteOrder: ByteOrder.littleEndian);
  final OutputFileStream _output;
  final int limit;
  final void Function()? checkCancelled;
  int _nextCheck = 0;

  @override
  int get length => _output.length;
  void _check(int count) {
    if (length >= _nextCheck) {
      checkCancelled?.call();
      _nextCheck = length + 64 * 1024;
    }
    if (count < 0 || count > limit - length) {
      throw const FormatException('BSDIFF40 block exceeds expected size');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    _output.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    _output.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(stream.readBytes(min(stream.length, 64 * 1024)).toUint8List());
    }
  }

  @override
  void flush() => _output.flush();
  @override
  void closeSync() => _output.closeSync();
  @override
  void clear() => throw UnsupportedError('clear');
  @override
  Uint8List subset(int start, [int? end]) => throw UnsupportedError('subset');
}

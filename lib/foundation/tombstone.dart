import 'dart:convert';
import 'dart:typed_data';

/// A window onto protobuf-encoded bytes.
///
/// Reading stops quietly where the data ends: the trace is cut at a fixed
/// size, usually in the middle of a field.
class _Reader {
  _Reader(this._bytes, [this._pos = 0, int? end]) : _end = end ?? _bytes.length;

  final Uint8List _bytes;
  int _pos;
  final int _end;

  int? _varint() {
    var value = 0;
    for (var shift = 0; shift < 64 && _pos < _end; shift += 7) {
      final byte = _bytes[_pos++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return value;
    }
    return null;
  }

  /// Each field as its number and either an integer or the nested bytes.
  /// Fixed-width fields are skipped; the messages read here have none.
  Iterable<(int, Object)> fields() sync* {
    while (_pos < _end) {
      final tag = _varint();
      if (tag == null) return;
      switch (tag & 7) {
        case 0:
          final value = _varint();
          if (value == null) return;
          yield (tag >> 3, value);
        case 1:
          _pos += 8;
        case 2:
          final length = _varint();
          if (length == null || length < 0 || _pos + length > _end) return;
          yield (tag >> 3, _Reader(_bytes, _pos, _pos + length));
          _pos += length;
        case 5:
          _pos += 4;
        default:
          return;
      }
    }
  }

  String text() => utf8.decode(
    Uint8List.sublistView(_bytes, _pos, _end),
    allowMalformed: true,
  );
}

class _Thread {
  int id = 0;
  String name = '';
  final frames = <String>[];
  final notes = <String>[];
}

const _architectures = ['arm', 'arm64', 'x86', 'x86_64', 'riscv64'];

const _maxFrames = 64;

const _maxOtherThreadFrames = 10;

const _maxLength = 48000;

String _hex(int value, int width) {
  // Addresses are unsigned; a Dart int with the top bit set prints negative.
  final text = value >= 0
      ? value.toRadixString(16)
      : (value >>> 32).toRadixString(16) +
            (value & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return text.padLeft(width, '0');
}

String _frame(_Reader reader, int index, int width) {
  var relPc = 0;
  var functionOffset = 0;
  var mapOffset = 0;
  var function = '';
  var file = '';
  var buildId = '';
  for (final (field, value) in reader.fields()) {
    switch ((field, value)) {
      case (1, final int v):
        relPc = v;
      case (4, final _Reader r):
        function = r.text();
      case (5, final int v):
        functionOffset = v;
      case (6, final _Reader r):
        file = r.text();
      case (7, final int v):
        mapOffset = v;
      case (8, final _Reader r):
        buildId = r.text();
    }
  }
  final buffer = StringBuffer(
    '#${index.toString().padLeft(2, '0')} pc ${_hex(relPc, width)}  '
    '${file.isEmpty ? '<unknown>' : file}',
  );
  if (mapOffset != 0) buffer.write(' (offset 0x${_hex(mapOffset, 0)})');
  if (function.isNotEmpty) buffer.write(' ($function+$functionOffset)');
  if (buildId.isNotEmpty) buffer.write(' (BuildId: $buildId)');
  return buffer.toString();
}

_Thread _thread(_Reader reader, int width, int maxFrames) {
  final thread = _Thread();
  for (final (field, value) in reader.fields()) {
    switch ((field, value)) {
      case (1, final int v):
        thread.id = v;
      case (2, final _Reader r):
        thread.name = r.text();
      case (4, final _Reader r) when thread.frames.length < maxFrames:
        thread.frames.add(_frame(r, thread.frames.length, width));
      case (7, final _Reader r):
        thread.notes.add(r.text());
    }
  }
  return thread;
}

String _signal(_Reader reader, int width) {
  var number = 0;
  var code = 0;
  var name = '';
  var codeName = '';
  var hasAddress = false;
  var address = 0;
  for (final (field, value) in reader.fields()) {
    switch ((field, value)) {
      case (1, final int v):
        number = v;
      case (2, final _Reader r):
        name = r.text();
      case (3, final int v):
        code = v;
      case (4, final _Reader r):
        codeName = r.text();
      case (8, final int v):
        hasAddress = v != 0;
      case (9, final int v):
        address = v;
    }
  }
  return 'signal $number ($name), code $code ($codeName), fault addr '
      '${hasAddress ? '0x${_hex(address, width)}' : '--------'}';
}

/// The parts of an Android tombstone a native crash is diagnosed from: the
/// signal, the abort message and the thread stacks, the crashed thread first.
///
/// Memory dumps, memory maps, open files and the log buffers are left out.
/// They are the bulk of the file, and the logs and memory can hold anything the
/// app had in hand. Null when the bytes hold nothing recognisable.
String? describeTombstone(Uint8List bytes) {
  var arch = 0;
  int? crashedTid;
  int? uptime;
  String? fingerprint;
  String? timestamp;
  String? abortMessage;
  _Reader? signal;
  final command = <String>[];
  final causes = <String>[];
  final threads = <(int, _Reader)>[];
  try {
    for (final (field, value) in _Reader(bytes).fields()) {
      switch ((field, value)) {
        case (1, final int v):
          arch = v;
        case (2, final _Reader r):
          fingerprint = r.text();
        case (4, final _Reader r):
          timestamp = r.text();
        case (6, final int v):
          crashedTid = v;
        case (9, final _Reader r):
          command.add(r.text());
        case (10, final _Reader r):
          signal = r;
        case (14, final _Reader r):
          abortMessage = r.text();
        case (15, final _Reader r):
          for (final (causeField, cause) in r.fields()) {
            if (causeField == 1 && cause is _Reader) causes.add(cause.text());
          }
        case (16, final _Reader r):
          // A map entry: the thread id, then the thread.
          int? id;
          _Reader? thread;
          for (final (entryField, entry) in r.fields()) {
            if (entryField == 1 && entry is int) id = entry;
            if (entryField == 2 && entry is _Reader) thread = entry;
          }
          if (id != null && thread != null) threads.add((id, thread));
        case (20, final int v):
          uptime = v;
      }
    }
  } catch (_) {
    // Whatever was read before the damage still stands.
  }
  if (signal == null && abortMessage == null && threads.isEmpty) return null;

  final width = arch == 1 || arch == 3 || arch == 4 ? 16 : 8;
  final buffer = StringBuffer();
  if (fingerprint != null) buffer.writeln("Build fingerprint: '$fingerprint'");
  buffer.writeln(
    "ABI: '${arch >= 0 && arch < _architectures.length ? _architectures[arch] : arch}'",
  );
  if (timestamp != null) buffer.writeln('Timestamp: $timestamp');
  if (uptime != null) buffer.writeln('Process uptime: ${uptime}s');
  if (command.isNotEmpty) buffer.writeln('Cmdline: ${command.join(' ')}');
  if (signal != null) buffer.writeln(_signal(signal, width));
  if (abortMessage != null && abortMessage.isNotEmpty) {
    buffer.writeln("Abort message: '$abortMessage'");
  }
  for (final cause in causes) {
    buffer.writeln('Cause: $cause');
  }

  void write(_Thread thread, {required bool crashed}) {
    buffer
      ..writeln()
      ..writeln(
        '${crashed ? 'Crashed thread' : 'Thread'} ${thread.id} '
        '(${thread.name}):',
      );
    for (final note in thread.notes) {
      buffer.writeln('  note: $note');
    }
    for (final frame in thread.frames) {
      buffer.writeln('  $frame');
    }
  }

  // The crashed thread in full, then the top of the others while room lasts.
  threads.sort((a, b) {
    if (a.$1 == crashedTid) return -1;
    if (b.$1 == crashedTid) return 1;
    return a.$1.compareTo(b.$1);
  });
  for (final (id, reader) in threads) {
    if (buffer.length > _maxLength) break;
    final crashed = id == crashedTid;
    write(
      _thread(reader, width, crashed ? _maxFrames : _maxOtherThreadFrames),
      crashed: crashed,
    );
  }
  return buffer.toString();
}

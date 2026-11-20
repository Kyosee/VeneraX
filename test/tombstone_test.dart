import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/tombstone.dart';

/// Android hands back a native crash as a protobuf tombstone, cut at a fixed
/// size. The report needs its signal and stacks as text, the crashed thread
/// first, without the memory and log sections that make up most of the file.
void main() {
  List<int> varint(int value) {
    final out = <int>[];
    var rest = value;
    do {
      var byte = rest & 0x7f;
      rest = rest >>> 7;
      if (rest != 0) byte |= 0x80;
      out.add(byte);
    } while (rest != 0);
    return out;
  }

  List<int> number(int field, int value) => [
    ...varint(field << 3),
    ...varint(value),
  ];

  List<int> nested(int field, List<int> bytes) => [
    ...varint(field << 3 | 2),
    ...varint(bytes.length),
    ...bytes,
  ];

  List<int> str(int field, String value) => nested(field, utf8.encode(value));

  List<int> frame(int relPc, String function, int offset, String file) => [
    ...number(1, relPc),
    ...str(4, function),
    ...number(5, offset),
    ...str(6, file),
    ...str(8, 'abc123'),
  ];

  List<int> thread(int id, String name, List<List<int>> frames) => nested(16, [
    ...number(1, id),
    ...nested(2, [
      ...number(1, id),
      ...str(2, name),
      for (final f in frames) ...nested(4, f),
    ]),
  ]);

  List<int> signal({int code = 1}) => nested(10, [
    ...number(1, 11),
    ...str(2, 'SIGSEGV'),
    ...number(3, code),
    ...str(4, 'SEGV_MAPERR'),
    ...number(8, 1),
    ...number(9, 0x10),
  ]);

  final worker = thread(40, 'worker', [
    frame(0x100, 'wait', 8, '/apex/libc.so'),
  ]);
  final crashed = thread(77, 'DartWorker', [
    frame(0xabcde, 'sqlite3_step', 44, '/data/app/lib/arm64/libsqlite3.so'),
    frame(0x1234, '', 0, '/data/app/lib/arm64/libapp.so'),
  ]);

  Uint8List tombstone({List<int>? signalInfo}) => Uint8List.fromList([
    ...number(1, 1),
    ...str(2, 'brand/device:14/UP1A/1:user/release-keys'),
    ...str(4, '2026-11-20 10:00:00'),
    ...number(5, 4321),
    ...number(6, 77),
    ...str(9, 'io.github.kyosee.venera'),
    ...(signalInfo ?? signal()),
    ...str(14, 'double free detected'),
    ...nested(15, str(1, 'heap corruption')),
    ...worker,
    ...crashed,
    ...nested(17, [...number(1, 0x7000), ...str(7, '/data/secret.so')]),
    ...nested(18, str(1, 'log line with https://example.com/secret')),
    ...number(20, 12),
  ]);

  test('the signal and the stacks come out as text', () {
    final text = describeTombstone(tombstone())!;
    expect(text, contains("Build fingerprint: 'brand/device:14/UP1A/1:user"));
    expect(text, contains("ABI: 'arm64'"));
    expect(text, contains('Process uptime: 12s'));
    expect(text, contains('Cmdline: io.github.kyosee.venera'));
    expect(
      text,
      contains(
        'signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), '
        'fault addr 0x0000000000000010',
      ),
    );
    expect(text, contains("Abort message: 'double free detected'"));
    expect(text, contains('Cause: heap corruption'));
    expect(
      text,
      contains(
        '#00 pc 00000000000abcde  /data/app/lib/arm64/libsqlite3.so '
        '(sqlite3_step+44) (BuildId: abc123)',
      ),
    );
    expect(
      text,
      contains(
        '#01 pc 0000000000001234  /data/app/lib/arm64/libapp.so '
        '(BuildId: abc123)',
      ),
    );
  });

  test('the crashed thread leads, wherever it sits in the file', () {
    final text = describeTombstone(tombstone())!;
    expect(text, contains('Crashed thread 77 (DartWorker):'));
    expect(text, contains('Thread 40 (worker):'));
    expect(
      text.indexOf('Crashed thread 77'),
      lessThan(text.indexOf('Thread 40')),
    );
  });

  test('memory maps and logs are left out', () {
    final text = describeTombstone(tombstone())!;
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('example.com')));
  });

  test('a file cut short still yields what came before the cut', () {
    final whole = tombstone();
    // Somewhere inside the second thread.
    final cut = Uint8List.sublistView(whole, 0, whole.length - 150);
    final text = describeTombstone(cut)!;
    expect(text, contains('signal 11 (SIGSEGV)'));
    expect(text, contains('Thread 40 (worker):'));
    for (var end = 1; end < whole.length; end += 7) {
      describeTombstone(Uint8List.sublistView(whole, 0, end));
    }
  });

  test('negative codes and high addresses print as the system shows them', () {
    final text = describeTombstone(
      tombstone(
        signalInfo: nested(10, [
          ...number(1, 6),
          ...str(2, 'SIGABRT'),
          ...number(3, -6),
          ...str(4, 'SI_TKILL'),
          ...number(8, 1),
          ...number(9, -4096),
        ]),
      ),
    )!;
    expect(
      text,
      contains(
        'signal 6 (SIGABRT), code -6 (SI_TKILL), '
        'fault addr 0xfffffffffffff000',
      ),
    );
  });

  test('bytes that are no tombstone give nothing', () {
    expect(describeTombstone(Uint8List(0)), isNull);
    expect(
      describeTombstone(Uint8List.fromList(utf8.encode('plain text here'))),
      isNull,
    );
  });
}

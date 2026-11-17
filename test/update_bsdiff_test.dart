import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/update_bsdiff.dart';

List<int> _offset(int value) {
  final bytes = List<int>.filled(8, 0);
  var magnitude = value.abs();
  for (var i = 0; i < 8; i++) {
    bytes[i] = magnitude & 0xff;
    magnitude >>= 8;
  }
  if (value < 0) bytes[7] |= 0x80;
  return bytes;
}

Uint8List _patch({
  int size = 1,
  List<int> controls = const [0, 1, 0],
  List<int>? rawControls,
  List<int> diff = const [],
  List<int> extra = const [42],
}) {
  final encoder = BZip2Encoder();
  final controlBlock = encoder.encodeBytes(
    rawControls ?? controls.expand(_offset).toList(),
  );
  final diffBlock = encoder.encodeBytes(diff);
  final extraBlock = encoder.encodeBytes(extra);
  return Uint8List.fromList([
    ...ascii.encode('BSDIFF40'),
    ..._offset(controlBlock.length),
    ..._offset(diffBlock.length),
    ..._offset(size),
    ...controlBlock,
    ...diffBlock,
    ...extraBlock,
  ]);
}

Uint8List _replaceOffset(List<int> patch, int position, int value) {
  return Uint8List.fromList(patch)
    ..setRange(position, position + 8, _offset(value));
}

void main() {
  late Directory directory;
  late File oldFile;
  late File patchFile;
  late File outputFile;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('venerax-bsdiff-test-');
    oldFile = File('${directory.path}/old.bin')
      ..writeAsBytesSync(List<int>.generate(256, (i) => i));
    patchFile = File('${directory.path}/update.patch');
    outputFile = File('${directory.path}/new.bin');
  });
  tearDown(() => directory.deleteSync(recursive: true));

  void apply(int expectedSize, {File? output}) => applyBsdiff(
    oldFile: oldFile,
    patchFile: patchFile,
    outputFile: output ?? outputFile,
    expectedSize: expectedSize,
  );

  List<String> entries() =>
      directory.listSync().map((entry) => entry.path).toList()..sort();

  void rejects(List<int> patch, {int expectedSize = 1}) {
    patchFile.writeAsBytesSync(patch);
    final oldBytes = oldFile.readAsBytesSync();
    final existing = entries();
    expect(() => apply(expectedSize), throwsA(anything));
    expect(oldFile.readAsBytesSync(), oldBytes);
    expect(patchFile.readAsBytesSync(), patch);
    expect(outputFile.existsSync(), isFalse);
    expect(
      entries(),
      existing,
      reason: 'Failed updates must remove scratch files',
    );
  }

  final fixtures =
      jsonDecode(
            File('test/fixtures/update_delta/bsdiff4.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  for (final fixture in fixtures['cases'] as List<dynamic>) {
    final values = fixture as Map<String, dynamic>;
    test('applies independent bsdiff4 fixture: ${values['name']}', () {
      final oldBytes = base64Decode(values['old'] as String);
      final newBytes = base64Decode(values['new'] as String);
      final patchBytes = base64Decode(values['patch'] as String);
      oldFile.writeAsBytesSync(oldBytes);
      patchFile.writeAsBytesSync(patchBytes);
      apply(newBytes.length);
      expect(outputFile.readAsBytesSync(), newBytes);
      expect(oldFile.readAsBytesSync(), oldBytes);
      expect(patchFile.readAsBytesSync(), patchBytes);
      expect(
        entries(),
        [
            oldFile.absolute.path,
            patchFile.absolute.path,
            outputFile.absolute.path,
          ].map((path) => path.replaceAll('/', Platform.pathSeparator)).toList()
          ..sort(),
      );
    });
  }

  test('streams across the 64 KiB copy boundary', () {
    final oldBytes = List<int>.generate(140000, (i) => i % 256);
    oldFile.writeAsBytesSync(oldBytes);
    patchFile.writeAsBytesSync(
      _patch(
        size: oldBytes.length,
        controls: [oldBytes.length, 0, 0],
        diff: List<int>.filled(oldBytes.length, 1),
        extra: [],
      ),
    );
    apply(oldBytes.length);
    expect(
      outputFile.readAsBytesSync(),
      oldBytes.map((byte) => (byte + 1) & 0xff).toList(),
    );
  });

  test('handles valid backward seeks and old bytes outside the input', () {
    oldFile.writeAsBytesSync([10, 20]);
    patchFile.writeAsBytesSync(
      _patch(
        size: 5,
        controls: [1, 0, -2, 4, 0, 0],
        diff: [0, 1, 2, 3, 4],
        extra: [],
      ),
    );
    apply(5);
    expect(outputFile.readAsBytesSync(), [10, 1, 12, 23, 4]);
  });

  test('accepts a seek-only tuple before an output tuple', () {
    oldFile.writeAsBytesSync([10, 20, 30]);
    patchFile.writeAsBytesSync(
      _patch(controls: [0, 0, 1, 1, 0, 0], diff: [0], extra: []),
    );
    apply(1);
    expect(outputFile.readAsBytesSync(), [20]);
  });

  for (final length in [0, 7, 8, 24, 31]) {
    test('rejects truncated header of $length bytes', () {
      rejects(_patch().sublist(0, length));
    });
  }
  test('rejects invalid magic', () {
    rejects(_patch()..[0] = 0);
  });
  for (final position in [8, 16, 24]) {
    test('rejects negative header length at $position', () {
      rejects(_replaceOffset(_patch(), position, -1));
    });
  }
  for (final position in [8, 16]) {
    test('rejects compressed block extending past input at $position', () {
      rejects(_replaceOffset(_patch(), position, 1000000));
    });
  }
  test('rejects expected size different from the patch header', () {
    rejects(_patch(), expectedSize: 2);
  });
  test('rejects a negative expected size', () {
    rejects(_patch(), expectedSize: -1);
  });
  test('rejects expected size over 512 MiB', () {
    const oversized = 512 * 1024 * 1024 + 1;
    rejects(_replaceOffset(_patch(), 24, oversized), expectedSize: oversized);
  });
  test('rejects truncated compressed data', () {
    final patch = _patch();
    rejects(patch.sublist(0, patch.length - 8));
  });
  test('rejects a damaged compressed control block', () {
    rejects(_patch()..[32] = 0);
  });
  test('rejects an incomplete control tuple', () {
    rejects(_patch(rawControls: List<int>.filled(23, 0)));
  });
  for (final controls in [
    [-1, 1, 0],
    [1, -1, 0],
    [2, 0, 0],
    [0, 2, 0],
    [0, 0, 0],
    [0, 1, 1024 * 1024 * 1024 + 1],
  ]) {
    test('rejects invalid control tuple $controls', () {
      rejects(_patch(controls: controls));
    });
  }
  test('rejects missing diff bytes and removes partial output', () {
    rejects(_patch(controls: [1, 0, 0], extra: []));
  });
  test('rejects controls exhausted by seek-only tuples', () {
    rejects(_patch(controls: [0, 0, 1]));
  });
  test('rejects missing extra bytes and removes partial output', () {
    rejects(_patch(extra: []));
  });
  test('rejects a missing second tuple after writing some output', () {
    rejects(_patch(size: 2), expectedSize: 2);
  });
  test('rejects decompression beyond expected output size', () {
    rejects(_patch(extra: [42, 43]));
  });
  test('rejects unused control tuples', () {
    rejects(_patch(controls: [0, 1, 0, 0, 1, 0]));
  });
  test('rejects unused diff bytes', () {
    rejects(_patch(diff: [0]));
  });
  test('rejects unused extra bytes', () {
    rejects(_patch(controls: [1, 0, 0], diff: [0]));
  });
  for (final target in ['old', 'patch', 'existing', 'relative-old']) {
    test('rejects output overlapping $target without deleting input', () {
      patchFile.writeAsBytesSync(_patch());
      final oldBytes = oldFile.readAsBytesSync();
      final patchBytes = patchFile.readAsBytesSync();
      final File targetFile;
      switch (target) {
        case 'old':
          targetFile = oldFile;
        case 'patch':
          targetFile = patchFile;
        case 'relative-old':
          targetFile = File('${directory.path}/./old.bin');
        default:
          targetFile = outputFile..writeAsStringSync('existing data');
      }
      final targetBytes = targetFile.readAsBytesSync();
      final existing = entries();
      expect(() => apply(1, output: targetFile), throwsA(anything));
      expect(oldFile.readAsBytesSync(), oldBytes);
      expect(patchFile.readAsBytesSync(), patchBytes);
      expect(targetFile.readAsBytesSync(), targetBytes);
      expect(entries(), existing);
    });
  }
}

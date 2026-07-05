import 'dart:io' show Directory;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/io.dart';

/// copyFileStreaming byte-progress callback (#92): the destination write is the
/// slow step of an export, so it must report real byte progress. Plain
/// temp-file IO — no isolate, no app state.
void main() {
  test('streams the file and reports monotonic byte progress ending at total',
      () async {
    final dir = Directory.systemTemp.createTempSync('venera_copy_test');
    addTearDown(() => dir.deleteSync(recursive: true));

    // ~20 MiB so it spans multiple 8 MiB chunks.
    final srcPath = '${dir.path}/src.bin';
    final dstPath = '${dir.path}/dst.bin';
    final bytes = Uint8List(20 * 1024 * 1024);
    for (var i = 0; i < bytes.length; i += 4096) {
      bytes[i] = i % 256;
    }
    File(srcPath).writeAsBytesSync(bytes);

    final samples = <int>[];
    int? reportedTotal;
    await copyFileStreaming(
      File(srcPath),
      File(dstPath),
      onProgress: (copied, total) {
        samples.add(copied);
        reportedTotal = total;
      },
    );

    // Content copied faithfully.
    expect(File(dstPath).lengthSync(), bytes.length);
    // Progress fired, total is the real file size, and copied is monotonic and
    // finishes exactly at total.
    expect(samples, isNotEmpty);
    expect(reportedTotal, bytes.length);
    expect(samples.last, bytes.length);
    for (var i = 1; i < samples.length; i++) {
      expect(samples[i] >= samples[i - 1], isTrue);
    }
  });

  test('no callback means no length() probe, still copies', () async {
    final dir = Directory.systemTemp.createTempSync('venera_copy_test2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final srcPath = '${dir.path}/s.bin';
    final dstPath = '${dir.path}/d.bin';
    File(srcPath).writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4, 5]));

    await copyFileStreaming(File(srcPath), File(dstPath));
    expect(File(dstPath).readAsBytesSync(), [1, 2, 3, 4, 5]);
  });
}

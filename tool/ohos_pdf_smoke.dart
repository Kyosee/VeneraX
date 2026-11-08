import 'dart:io';
import 'dart:ui' as ui;

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/utils/pdf_import.dart';

import '../test/fixtures/pdf_fixture.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String result;
  try {
    final cache = await getTemporaryDirectory();
    final temporary = await Directory(cache.path).createTemp('pdf_probe_');
    try {
      final source = File('${temporary.path}/comic.pdf')
        ..writeAsBytesSync(pdfFixture(pageCount: 3));
      final comic = await importPdfComic(
        source,
        localPath: temporary.path,
        cachePath: cache.path,
      );
      for (var i = 0; i < 3; i++) {
        final codec = await ui.instantiateImageCodec(
          await File(
            '${temporary.path}/${comic.directory}/${i + 1}.png',
          ).readAsBytes(),
        );
        try {
          final frame = await codec.getNextFrame();
          try {
            final image = frame.image;
            if ((image.width, image.height) !=
                [(200, 400), (400, 200), (2400, 1200)][i]) {
              throw StateError(
                'PDF page $i has size ${image.width} x ${image.height}.',
              );
            }
            final bytes = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            final center =
                ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
            if (!listEquals(
              bytes.buffer.asUint8List(center, 4),
              [
                [255, 0, 0, 255],
                [0, 255, 0, 255],
                [0, 0, 255, 255],
              ][i],
            )) {
              throw StateError('PDF page $i did not preserve its color.');
            }
          } finally {
            frame.image.dispose();
          }
        } finally {
          codec.dispose();
        }
      }
      final originalEntries = temporary.listSync().length;
      var failed = false;
      try {
        await importPdfComic(
          source,
          localPath: temporary.path,
          cachePath: cache.path,
          onProgress: (_) => throw const FileSystemException('probe failure'),
        );
      } on FileSystemException {
        failed = true;
      }
      if (!failed || temporary.listSync().length != originalEntries) {
        throw StateError('Partial PDF import cleanup failed.');
      }
    } finally {
      await temporary.delete(recursive: true);
    }
    final battery = await Battery().batteryLevel;
    final network = await Connectivity().onConnectivityChanged.first.timeout(
      const Duration(seconds: 10),
    );
    const system = MethodChannel('venera/method_channel');
    await system.invokeMethod('setScreenOn', true);
    await system.invokeMethod('setScreenOn', false);
    result =
        'PASS: PDF rotation, pixels, size cap, failed import cleanup; battery $battery; network $network; screen wake.';
  } catch (error, stack) {
    result = 'FAIL: $error\n$stack';
  }
  debugPrint(result);
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText(result),
          ),
        ),
      ),
    ),
  );
}

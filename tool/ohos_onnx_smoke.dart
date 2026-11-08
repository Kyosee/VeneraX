import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void rejects(void Function() operation) {
  try {
    operation();
  } on Exception {
    return;
  }
  throw StateError('Invalid model or tensor was accepted.');
}

String infer(String directory) {
  final model = File('$directory/模型.onnx');
  // Microsoft ONNX Runtime v1.22.0 testdata/mul_1.onnx; see test/fixtures/ONNX-LICENSE.
  // Multiplies X [3, 2] by the constant weights [1, 2, 3, 4, 5, 6].
  model.writeAsBytesSync(
    base64Decode(
      'CAMSBmNoZW50YTpwChUKAVgKAVcSAVkaBW11bF8xIgNNdWwSCG11bCB0ZXN0'
      'KiMIAwgCEAEiGAAAgD8AAABAAABAQAAAgEAAAKBAAADAQEIBV1oTCgFYEg4KDAgB'
      'EggKAggDCgIIAmITCgFZEg4KDAgBEggKAggDCgIIAkIECgAQBw==',
    ),
  );
  final badModel = File('$directory/invalid.onnx')
    ..writeAsStringSync('invalid');
  rejects(() => OrtFfiSession.open(badModel.path));
  for (var round = 0; round < 3; round++) {
    final session = OrtFfiSession.open(model.path, intraOpThreads: 2);
    try {
      check(listEquals(session.inputNames, ['X']), 'Input names mismatch.');
      check(listEquals(session.outputNames, ['Y']), 'Output names mismatch.');
      final input = {
        'X': OrtInput.float32(Float32List.fromList([-1, 0, .5, 2, -3, 4]), [
          3,
          2,
        ]),
      };
      for (var run = 0; run < 20; run++) {
        final output = session.run(input)['Y']!;
        check(listEquals(output.shape, [3, 2]), 'Output shape mismatch.');
        check(
          listEquals(output.data, [-1, 0, 1.5, 8, -15, 24]),
          'Inference mismatch.',
        );
      }
      check(
        session.runArgmaxLastRow(input, 'Y') == 1,
        'Greedy decoding mismatch.',
      );
      rejects(
        () => session.run({
          'X': OrtInput.float32(Float32List(6), [2, 3]),
        }),
      );
      check(
        session.run(input)['Y']!.data.last == 24,
        'Session did not recover.',
      );
    } finally {
      session.close();
    }
  }
  return 'CPU inference, Unicode model path, worker isolate, model and tensor '
      'rejection, repeated sessions, output shapes and greedy decoding';
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Directory? temporary;
  String result;
  try {
    final cache = await getTemporaryDirectory();
    temporary = await Directory(cache.path).createTemp('onnx_probe_');
    final checked = await compute(infer, temporary.path);
    result = 'PASS: ONNX $checked.';
  } catch (error, stack) {
    result = 'FAIL: $error\n$stack';
  } finally {
    await temporary?.delete(recursive: true);
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

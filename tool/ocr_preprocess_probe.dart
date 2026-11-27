import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'ocr_preprocess_benchmark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  try {
    final report = await Isolate.run(
      () => runOcrPreprocessBenchmark(
        backend: const String.fromEnvironment(
          'VENERAX_BENCH_BACKEND',
          defaultValue: 'compare',
        ),
        rounds: const int.fromEnvironment(
          'VENERAX_BENCH_ROUNDS',
          defaultValue: 15,
        ),
        warmups: const int.fromEnvironment(
          'VENERAX_BENCH_WARMUPS',
          defaultValue: 3,
        ),
      ),
    );
    // Keep each line below the device logger's message limit.
    final encoded = jsonEncode(report);
    for (var start = 0; start < encoded.length; start += 1000) {
      final end = math.min(start + 1000, encoded.length);
      print('VENERAX_OCR_BENCHMARK_PART=${encoded.substring(start, end)}');
    }
    print('VENERAX_OCR_BENCHMARK_DONE');
  } catch (error, stack) {
    print('VENERAX_OCR_BENCHMARK_ERROR=${jsonEncode('$error\n$stack')}');
  }
}

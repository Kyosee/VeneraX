import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_translation/detector_preprocess.dart';

import 'ocr_preprocess_benchmark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  try {
    final report = await Isolate.run(
      () => runOcrPreprocessBenchmark(
        backend:
            !rustDetectorAvailable &&
                const bool.fromEnvironment('VENERAX_BENCH_ALLOW_MISSING')
            ? 'dart'
            : const String.fromEnvironment(
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
    report['buildMode'] = kReleaseMode
        ? 'release'
        : (kProfileMode ? 'profile' : 'debug');
    printOcrBenchmarkReport(report);
  } catch (error, stack) {
    print('VENERAX_OCR_BENCHMARK_ERROR=${jsonEncode('$error\n$stack')}');
  }
}

void printOcrBenchmarkReport(Map<String, Object?> report) {
  // Flutter's Android logger truncates messages before logcat's own limit.
  final encoded = jsonEncode(report);
  for (var start = 0; start < encoded.length; start += 500) {
    final end = math.min(start + 500, encoded.length);
    print('VENERAX_OCR_BENCHMARK_PART=${encoded.substring(start, end)}');
  }
  print('VENERAX_OCR_BENCHMARK_DONE');
}

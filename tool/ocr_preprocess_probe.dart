import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';

import 'ocr_preprocess_benchmark.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  Map<String, Object?> report;
  try {
    report = await Isolate.run(
      () => runOcrPreprocessBenchmark(
        backend: const String.fromEnvironment(
          'VENERAX_BENCH_BACKEND',
          defaultValue: 'compare',
        ),
        allowMissingNative: const bool.fromEnvironment(
          'VENERAX_BENCH_ALLOW_MISSING',
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
    report = {'error': '$error\n$stack'};
    print('VENERAX_OCR_BENCHMARK_ERROR=${jsonEncode(report['error'])}');
  }
  final output = Platform.environment['VENERAX_OCR_REPORT'];
  if (output != null) {
    final temporary = File('$output.tmp');
    await temporary.writeAsString(jsonEncode(report));
    await temporary.rename(output);
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

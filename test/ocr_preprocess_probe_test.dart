import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/detector_preprocess.dart';

import '../tool/ocr_preprocess_benchmark.dart';
import '../tool/ocr_preprocess_probe.dart';

void main() {
  test('probe compares automatic backend selection with Dart', () {
    final report = runOcrPreprocessBenchmark(
      allowMissingNative: true,
      rounds: 1,
      warmups: 1,
      caseName: 'scaled',
    );
    expect(report['backend'], 'compare');
    expect(report['nativeAvailable'], rustDetectorAvailable);
    final result = (report['cases'] as List).single as Map;
    expect(result['bitwiseEqual'], true);
    expect(result['rustUsed'], rustDetectorAvailable);
    expect(result['comparedFloat32Elements'], 3686400);
    if (!rustDetectorAvailable) {
      expect(runOcrPreprocessBenchmark, throwsStateError);
    }
  });

  test('long benchmark report survives the device log message limit', () {
    final report = <String, Object?>{
      'nativeAvailable': true,
      'cases': List.generate(
        4,
        (index) => {
          'name': 'case_$index',
          'bitwiseEqual': true,
          'samplesMs': {
            'dart': List.generate(150, (round) => 100.123 + round),
            'rust': List.generate(150, (round) => 20.456 + round),
          },
        },
      ),
    };
    final messages = <String>[];
    runZoned(
      () => printOcrBenchmarkReport(report),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, message) => messages.add(message),
      ),
    );
    expect(messages.last, 'VENERAX_OCR_BENCHMARK_DONE');
    const marker = 'VENERAX_OCR_BENCHMARK_PART=';
    final parts = messages.take(messages.length - 1).map((message) {
      expect(utf8.encode(message).length, lessThan(1000));
      expect(message, startsWith(marker));
      return message.substring(marker.length);
    });
    expect(jsonDecode(parts.join()), report);
  });
}

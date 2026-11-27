import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:venera/foundation/image_translation/detector_input.dart';
import 'package:venera/foundation/image_translation/detector_preprocess.dart';
import 'package:venera/foundation/image_translation/ort_ffi.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

/// Measures detector preprocessing, including the native buffer allocation and
/// copy performed by OrtFfiSession. It does not measure OCR inference or UI.
Map<String, Object?> runOcrPreprocessBenchmark({
  String backend = 'compare',
  int rounds = 15,
  int warmups = 3,
}) {
  if (!const ['compare', 'dart', 'rust'].contains(backend)) {
    throw ArgumentError.value(backend, 'backend', 'Use compare, dart or rust');
  }
  if (rounds < 1 || warmups < 1) {
    throw ArgumentError('rounds and warmups must be positive');
  }
  if (backend != 'dart' && !rustDetectorAvailable) {
    throw StateError('The packaged Rust OCR library is unavailable');
  }
  final rssBefore = ProcessInfo.currentRss;
  final results = <Map<String, Object?>>[];
  for (final fixture in const [
    (name: 'ordinary', width: 800, height: 1152, rotate: false),
    (name: 'scaled', width: 1600, height: 1200, rotate: false),
    (name: 'rotated', width: 1217, height: 823, rotate: true),
    (name: 'wide_fallback', width: 4096, height: 64, rotate: false),
  ]) {
    final pixels = Uint8List(fixture.width * fixture.height * 4);
    for (var i = 0; i < pixels.length ~/ 4; i++) {
      final row = i ~/ fixture.width;
      pixels[4 * i] = (i * 37 + row * 17) & 255;
      pixels[4 * i + 1] = (i * 71 + row * 13) & 255;
      pixels[4 * i + 2] = (i * 19 + row * 53) & 255;
      pixels[4 * i + 3] = 255;
    }
    final image = RgbaImage(fixture.width, fixture.height, pixels);
    var nativeUsed = false;
    var shape = <int>[];
    final samples = <String, List<double>>{
      if (backend != 'rust') 'dart': [],
      if (backend != 'dart') 'rust': [],
    };
    if (backend == 'compare') {
      _verifyEqual(image, fixture.rotate);
    }
    var consumedValue = 0.0;
    for (var round = -warmups; round < rounds; round++) {
      // Alternate the first backend to reduce order and thermal bias.
      final order = round.isEven
          ? samples.keys.toList()
          : samples.keys.toList().reversed.toList();
      for (final name in order) {
        final measurement = _measure(image, fixture.rotate, name == 'rust');
        shape = measurement.shape;
        nativeUsed |= measurement.nativeUsed;
        consumedValue = measurement.value;
        if (round >= 0) {
          samples[name]!.add(measurement.ms);
        }
      }
    }
    if (!consumedValue.isFinite) {
      throw StateError('Invalid output in ${fixture.name}');
    }
    if (backend == 'compare') {
      _verifyEqual(image, fixture.rotate);
    }
    final medians = samples.map(
      (name, values) => MapEntry(name, _median(values)),
    );
    results.add({
      'name': fixture.name,
      'width': fixture.width,
      'height': fixture.height,
      'rotate': fixture.rotate,
      'shape': shape,
      'rustUsed': nativeUsed,
      'comparedFloat32Elements': backend == 'compare'
          ? shape.reduce((a, b) => a * b)
          : 0,
      'bitwiseEqual': backend == 'compare' ? true : null,
      'samplesMs': samples,
      'medianMs': medians,
      if (backend == 'compare' && nativeUsed)
        'timeReductionPercent': (1 - medians['rust']! / medians['dart']!) * 100,
    });
  }
  return {
    'scope': 'ocr_detector_preprocessing',
    'inputs': 'deterministic_synthetic_rgba',
    'backend': backend,
    'platform': Platform.operatingSystem,
    'abi': Abi.current().toString(),
    'dartVersion': Platform.version.split(' ').first,
    'nativeAvailable': rustDetectorAvailable,
    'rounds': rounds,
    'warmups': warmups,
    'memory': {
      'mode': backend == 'compare' ? 'combined_backends' : 'single_backend',
      'rssBeforeBytes': rssBefore,
      'rssAfterBytes': ProcessInfo.currentRss,
      'processPeakRssBytes': ProcessInfo.maxRss,
    },
    'cases': results,
  };
}

({double ms, double value, List<int> shape, bool nativeUsed}) _measure(
  RgbaImage image,
  bool rotate,
  bool allowRust,
) {
  final watch = Stopwatch()..start();
  final input = prepareDetectorInput(
    image,
    rotate: rotate,
    allowRust: allowRust,
  );
  final count = input.shape.reduce((a, b) => a * b);
  final output = calloc<Float>(count);
  late double value;
  try {
    _fill(input, output, count);
    value = output[count ~/ 2];
  } finally {
    calloc.free(output);
  }
  watch.stop();
  return (
    ms: watch.elapsedMicroseconds / 1000,
    value: value,
    shape: input.shape,
    nativeUsed: input.fill != null,
  );
}

void _fill(OrtInput input, Pointer<Float> output, int count) {
  if (input.fill case final fill?) {
    fill(output, count);
  } else {
    output.asTypedList(count).setAll(0, input.f32Data!);
  }
}

void _verifyEqual(RgbaImage image, bool rotate) {
  final reference = prepareDetectorInput(
    image,
    rotate: rotate,
    allowRust: false,
  );
  final count = reference.shape.reduce((a, b) => a * b);
  final dart = calloc<Float>(count);
  final native = calloc<Float>(count);
  try {
    _fill(reference, dart, count);
    final selected = prepareDetectorInput(image, rotate: rotate);
    _fill(selected, native, count);
    final expected = dart.cast<Uint32>().asTypedList(count);
    final actual = native.cast<Uint32>().asTypedList(count);
    for (var i = 0; i < count; i++) {
      if (expected[i] != actual[i]) {
        throw StateError(
          'Dart/Rust mismatch at float $i for '
          '${image.width}x${image.height}, rotate=$rotate',
        );
      }
    }
    if (selected.fill != null &&
        !fillRustDetectorTensor(
          image.pixels,
          image.width,
          image.height,
          selected.shape[3],
          selected.shape[2],
          native,
          count,
          rotate: rotate,
        )) {
      throw StateError('Rust rejected a benchmark input');
    }
  } finally {
    calloc.free(dart);
    calloc.free(native);
  }
}

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

void main(List<String> arguments) {
  var backend = 'compare';
  var rounds = 15;
  var warmups = 3;
  String? output;
  for (final argument in arguments) {
    if (argument.startsWith('--backend=')) {
      backend = argument.substring('--backend='.length);
    } else if (argument.startsWith('--rounds=')) {
      rounds = int.parse(argument.substring('--rounds='.length));
    } else if (argument.startsWith('--warmups=')) {
      warmups = int.parse(argument.substring('--warmups='.length));
    } else if (argument.startsWith('--output=')) {
      output = argument.substring('--output='.length);
    } else {
      throw ArgumentError('Unknown argument $argument');
    }
  }
  final report = jsonEncode(
    runOcrPreprocessBenchmark(
      backend: backend,
      rounds: rounds,
      warmups: warmups,
    ),
  );
  if (output != null) File(output).writeAsStringSync(report, flush: true);
  stdout.writeln(report);
}

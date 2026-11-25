import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/detector_preprocess.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

const _requireNative = bool.fromEnvironment('VENERAX_TEST_OCR_NATIVE');

Float32List _reference(
  Uint8List pixels,
  int width,
  int height,
  int outWidth,
  int outHeight,
  bool rotate,
) {
  final rgba = resizeTextLine(
    RgbaImage(width, height, pixels),
    IntRect(0, 0, width, height),
    outWidth,
    outHeight,
    rotate: rotate,
  );
  const means = [0.485, 0.456, 0.406];
  const deviations = [0.229, 0.224, 0.225];
  final plane = outWidth * outHeight;
  final result = Float32List(3 * plane);
  for (var channel = 0; channel < 3; channel++) {
    for (var i = 0; i < plane; i++) {
      result[channel * plane + i] =
          (rgba[4 * i + channel] / 255.0 - means[channel]) /
          deviations[channel];
    }
  }
  return result;
}

void _expectSameBits(Float32List result, Float32List reference, String label) {
  final actual = Uint32List.sublistView(result);
  final expected = Uint32List.sublistView(reference);
  expect(actual.length, expected.length, reason: label);
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != expected[i]) {
      fail('$label at float $i: ${result[i]} != ${reference[i]}');
    }
  }
}

void _compare(
  Uint8List pixels,
  int width,
  int height,
  int outWidth,
  int outHeight,
) {
  for (final rotate in [false, true]) {
    final label = '${width}x$height -> ${outWidth}x$outHeight, rotate=$rotate';
    final image = RgbaImage(width, height, pixels);
    final input = prepareDetectorInput(image, rotate: rotate);
    final [_, _, inH, inW] = input.shape;
    final modelReference = _reference(pixels, width, height, inW, inH, rotate);
    if (input.f32Data case final data?) {
      _expectSameBits(data, modelReference, 'Dart detector $label');
    } else {
      final buffer = calloc<Float>(modelReference.length);
      try {
        input.fill!(buffer, modelReference.length);
        _expectSameBits(
          buffer.asTypedList(modelReference.length),
          modelReference,
          'Native detector $label',
        );
      } finally {
        calloc.free(buffer);
      }
    }
    if (!rustDetectorAvailable) continue;
    final expected = _reference(
      pixels,
      width,
      height,
      outWidth,
      outHeight,
      rotate,
    );
    final buffer = calloc<Float>(expected.length);
    try {
      final filled = fillRustDetectorTensor(
        pixels,
        width,
        height,
        outWidth,
        outHeight,
        buffer,
        expected.length,
        rotate: rotate,
      );
      expect(filled, isTrue, reason: 'Rust $label');
      _expectSameBits(
        buffer.asTypedList(expected.length),
        expected,
        'Rust $label',
      );
    } finally {
      calloc.free(buffer);
    }
  }
}

void main() {
  if (const bool.hasEnvironment('VENERAX_TEST_OCR_NATIVE')) {
    test('loads the expected OCR backend', () {
      expect(rustDetectorAvailable, _requireNative);
    });
  }

  test('very wide source tiles keep the lower-memory Dart path', () {
    expect(canUseRustDetector(1280 * 1280 * 12 + 4, 1280 * 1280 * 3), isFalse);
    expect(
      canUseRustDetector(1280 * 1280 * 12, 1280 * 1280 * 3),
      rustDetectorAvailable,
    );
    final wide = RgbaImage(4096, 64, Uint8List(4096 * 64 * 4));
    for (final rotate in [false, true]) {
      final input = prepareDetectorInput(wide, rotate: rotate);
      expect(input.shape, rotate ? [1, 3, 1280, 32] : [1, 3, 32, 1280]);
      expect(input.fill, isNull);
      expect(input.f32Data, hasLength(1280 * 32 * 3));
    }
    final ordinary = RgbaImage(32, 64, Uint8List(32 * 64 * 4));
    expect(prepareDetectorInput(ordinary).fill != null, rustDetectorAvailable);
  });

  test('rejects truncated, oversized and null buffers before writing', () {
    final output = calloc<Float>(3);
    try {
      final input = Uint8List(4);
      output[0] = 17;
      expect(fillRustDetectorTensor(input, 2, 1, 1, 1, output, 3), isFalse);
      expect(fillRustDetectorTensor(input, 1, 1, 1, 1, output, 2), isFalse);
      expect(fillRustDetectorTensor(input, 1, 1, 1281, 1, output, 3), isFalse);
      expect(fillRustDetectorTensor(input, 1, 1, 1, 1, nullptr, 3), isFalse);
      expect(output[0], 17);
    } finally {
      calloc.free(output);
    }
  });

  test('matches the original detector for one-pixel axes and mixed scales', () {
    final random = Random(319);
    for (final (w, h, outW, outH) in [
      (1, 1, 32, 32),
      (1, 63, 32, 64),
      (65, 1, 64, 32),
      (5, 9, 32, 64),
      (97, 83, 32, 64),
      (32, 64, 32, 64),
      (1313, 3, 1280, 32),
    ]) {
      final pixels = Uint8List.fromList(
        List.generate(w * h * 4, (_) => random.nextInt(256)),
      );
      _compare(pixels, w, h, outW, outH);
    }
  });

  test('rounds interpolated half-bytes before normalizing RGB', () {
    final pixels = Uint8List(64 * 32 * 4);
    for (var i = 0; i < pixels.length ~/ 4; i++) {
      pixels[i * 4] = i.isEven ? 0 : 1;
      pixels[i * 4 + 1] = i.isEven ? 253 : 254;
      pixels[i * 4 + 2] = i.isEven ? 255 : 0;
      pixels[i * 4 + 3] = i.isEven ? 0 : 255;
    }
    _compare(pixels, 64, 32, 32, 32);
  });

  test('reads the second tile of a tall page from its view offset', () {
    const width = 17;
    const height = 1301;
    const tileTop = 1280 - 128;
    final random = Random(712);
    final page = Uint8List.fromList(
      List.generate(width * height * 4, (_) => random.nextInt(256)),
    );
    final before = Uint8List.fromList(page);
    final tile = Uint8List.sublistView(page, tileTop * width * 4);
    _compare(tile, width, height - tileTop, 32, 160);
    expect(page, orderedEquals(before));
  });
}

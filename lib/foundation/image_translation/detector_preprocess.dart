import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _ResizeNative =
    Uint8 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Uint32,
      Pointer<Float>,
      Size,
      Uint32,
      Uint32,
      Uint8,
    );
typedef _Resize =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      Pointer<Float>,
      int,
      int,
      int,
      int,
    );

_Resize? _loadKernel() {
  const testLibrary = String.fromEnvironment('VENERAX_TEST_OCR_LIBRARY');
  if (testLibrary.isEmpty &&
      (!Platform.isWindows || Abi.current() != Abi.windowsX64)) {
    return null;
  }
  final path = testLibrary.isNotEmpty
      ? testLibrary
      : File(
          Platform.resolvedExecutable,
        ).parent.uri.resolve('venera_ocr.dll').toFilePath();
  try {
    return DynamicLibrary.open(
      path,
    ).lookupFunction<_ResizeNative, _Resize>('venera_ocr_detector_rgb');
  } on ArgumentError {
    return null;
  }
}

final _resize = _loadKernel();
bool get rustDetectorAvailable => _resize != null;

/// The input copy must fit within the Dart float tensor it replaces.
bool canUseRustDetector(int sourceBytes, int outputElements) =>
    rustDetectorAvailable && sourceBytes <= outputElements * sizeOf<Float>();

/// Writes directly into ONNX's input buffer during a synchronous worker call.
bool fillRustDetectorTensor(
  Uint8List pixels,
  int width,
  int height,
  int outWidth,
  int outHeight,
  Pointer<Float> output,
  int outputLength, {
  bool rotate = false,
}) {
  final resize = _resize;
  if (resize == null ||
      width < 1 ||
      height < 1 ||
      width > 0xffffffff ||
      height > 0xffffffff ||
      outWidth < 1 ||
      outWidth > 1280 ||
      outHeight < 1 ||
      outHeight > 1280 ||
      output == nullptr ||
      outputLength != outWidth * outHeight * 3 ||
      pixels.lengthInBytes ~/ 4 ~/ width != height ||
      pixels.lengthInBytes != width * height * 4) {
    return false;
  }
  // A non-leaf call lets the VM collect other isolates while Rust resamples.
  final source = malloc<Uint8>(pixels.length);
  try {
    source.asTypedList(pixels.length).setAll(0, pixels);
    return resize(
          source,
          pixels.length,
          width,
          height,
          output,
          outputLength,
          outWidth,
          outHeight,
          rotate ? 1 : 0,
        ) ==
        1;
  } finally {
    malloc.free(source);
  }
}

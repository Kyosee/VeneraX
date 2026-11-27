import 'dart:async';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show ImageDecoderCallback;
import 'package:flutter/services.dart';
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/utils/file_type.dart';

Future<ui.Codec> decodeComicImage(
  Uint8List bytes, {
  ImageDecoderCallback decode = ui.instantiateImageCodecWithSize,
  ui.TargetImageSizeCallback? getTargetSize,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  if (!isAvifImage(bytes)) return decode(buffer, getTargetSize: getTargetSize);

  try {
    // Some engines accept the header but cannot decompress the first frame.
    return await _prime(await decode(buffer, getTargetSize: getTargetSize));
  } catch (_) {
    final page = await _softwarePixels(bytes);
    final raw = await ui.ImmutableBuffer.fromUint8List(page.pixels);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = ui.ImageDescriptor.raw(
        raw,
        width: page.width,
        height: page.height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final size = getTargetSize?.call(page.width, page.height);
      return await _prime(
        await descriptor.instantiateCodec(
          targetWidth: size?.width,
          targetHeight: size?.height,
        ),
      );
    } finally {
      descriptor?.dispose();
      raw.dispose();
    }
  }
}

Future<ui.Codec> _prime(ui.Codec codec) async {
  try {
    return _PrimedCodec(codec, await codec.getNextFrame());
  } catch (_) {
    codec.dispose();
    rethrow;
  }
}

class _PrimedCodec implements ui.Codec {
  _PrimedCodec(this._codec, this._first);

  final ui.Codec _codec;
  ui.FrameInfo? _first;

  @override
  int get frameCount => _codec.frameCount;
  @override
  int get repetitionCount => _codec.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    final first = _first;
    _first = null;
    return first ?? await _codec.getNextFrame();
  }

  @override
  void dispose() {
    _first?.image.dispose();
    _first = null;
    _codec.dispose();
  }
}

// Reader prefetch can request many pages at once. Limit the full-size software
// working buffers to one page at a time, even when several decodes fail.
Future<void> _softwareQueue = Future<void>.value();

Future<_AvifPixels> _softwarePixels(Uint8List bytes) async {
  final previous = _softwareQueue;
  final finished = Completer<void>();
  _softwareQueue = finished.future;
  await previous;
  try {
    final script = await rootBundle.loadString('assets/avif/decode.js');
    return await Isolate.run(() => _decodePixels(script, bytes));
  } finally {
    finished.complete();
  }
}

typedef _AvifPixels = ({int width, int height, Uint8List pixels});

Future<_AvifPixels> _decodePixels(String script, Uint8List bytes) async {
  const maxPixels = 32 * 1024 * 1024;
  final engine = FlutterQjs(
    stackSize: 2 * 1024 * 1024,
    memoryLimit: 512 * 1024 * 1024,
  );
  unawaited(engine.dispatch());
  JSInvokable? decode;
  try {
    engine.evaluate(script);
    decode = engine.evaluate('decodeAvifPage') as JSInvokable;
    final page = await decode([bytes, maxPixels]) as Map;
    final width = page['width'] as int;
    final height = page['height'] as int;
    final pixels = page['pixels'] as Uint8List;
    if (width <= 0 ||
        height <= 0 ||
        width * height > maxPixels ||
        pixels.length != width * height * 4) {
      throw const FormatException('Invalid AVIF dimensions');
    }
    // ImageDescriptor.raw expects premultiplied RGBA.
    for (var i = 0; i < pixels.length; i += 4) {
      final alpha = pixels[i + 3];
      if (alpha == 255) continue;
      for (var channel = i; channel < i + 3; channel++) {
        pixels[channel] = (pixels[channel] * alpha + 127) ~/ 255;
      }
    }
    return (width: width, height: height, pixels: pixels);
  } finally {
    decode?.free();
    engine.port.close();
    engine.close();
  }
}

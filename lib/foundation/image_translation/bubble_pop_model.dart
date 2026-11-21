import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

const bubblePopWidth = 576;
const bubblePopHeight = 768;
const bubblePopRuntimeFileName = 'bubble_pop_576.onnx';

/// Adapts the five decoder sizes and both NHWC declarations in letmutex's
/// fixed FP16 export. The original weights and download stay intact.
Future<void> prepareBubblePopModel(String path) => Isolate.run(() async {
  final source = File(path);
  final bytes = await source.readAsBytes();
  for (final height in [64, 128, 256, 512, 1024]) {
    // TensorProto: dims=[2], data_type=INT64, raw_data=two little-endian sizes.
    List<int> sizes(int h, int w) {
      final raw = ByteData(16)
        ..setInt64(0, h, Endian.little)
        ..setInt64(8, w, Endian.little);
      return [8, 2, 16, 7, 74, 16, ...raw.buffer.asUint8List()];
    }

    _replaceFields(
      bytes,
      sizes(height, height * 3 ~/ 4),
      sizes(height * bubblePopHeight ~/ 1024, height * bubblePopWidth ~/ 1024),
      1,
    );
  }
  // TensorShapeProto dimensions [1, 1024, 768, C] share this prefix in
  // both image and logits. The new varints occupy exactly the same space.
  List<int> shape(int h, int w) => [
    10,
    2,
    8,
    1,
    10,
    3,
    8,
    128 | (h & 127),
    h >> 7,
    10,
    3,
    8,
    128 | (w & 127),
    w >> 7,
  ];
  _replaceFields(
    bytes,
    shape(1024, 768),
    shape(bubblePopHeight, bubblePopWidth),
    2,
  );

  final temp = await source.parent.createTemp('.bubble-pop-');
  try {
    final output = File.fromUri(temp.uri.resolve(bubblePopRuntimeFileName));
    await output.writeAsBytes(bytes, flush: true);
    await output.rename(
      File.fromUri(source.uri.resolve(bubblePopRuntimeFileName)).path,
    );
  } finally {
    await temp.delete(recursive: true);
  }
});

void _replaceFields(
  Uint8List bytes,
  List<int> oldField,
  List<int> newField,
  int expected,
) {
  var count = 0;
  for (var i = 0; i <= bytes.length - oldField.length; i++) {
    if (bytes[i] != oldField.first) continue;
    var j = 1;
    while (j < oldField.length && bytes[i + j] == oldField[j]) {
      j++;
    }
    if (j != oldField.length) continue;
    bytes.setRange(i, i + oldField.length, newField);
    count++;
    i += oldField.length - 1;
  }
  if (count != expected) {
    throw const FormatException('Unrecognized BubblePop model');
  }
}

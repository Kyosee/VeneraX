import 'dart:typed_data';
import 'dart:ui' as ui;

class Image {
  final Uint32List _data;
  final int width;
  final int height;

  Image(this._data, this.width, this.height) {
    if (_data.length != width * height) {
      throw ArgumentError(
        'Invalid argument: data length must be equal to width * height.',
      );
    }
  }

  Image.empty(this.width, this.height) : _data = Uint32List(width * height);

  static Future<Image> decodeImage(Uint8List data) async {
    final codec = await ui.instantiateImageCodec(data);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final info = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    if (info == null) {
      throw Exception('Failed to decode image');
    }
    final image = Image(
      info.buffer.asUint32List(),
      frame.image.width,
      frame.image.height,
    );
    frame.image.dispose();
    return image;
  }

  Color getPixelAtIndex(int index) {
    if (index < 0 || index >= _data.length) {
      throw ArgumentError(
        'Invalid argument: index must be in the range of [0, ${_data.length}).',
      );
    }
    return Color.fromValue(_data[index]);
  }

  Image copyRange(int x, int y, int width, int height) {
    final data = Uint32List(width * height);
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        data[j * width + i] = _data[(j + y) * this.width + i + x];
      }
    }
    return Image(data, width, height);
  }

  void fillImageAt(int x, int y, Image image) {
    for (var j = 0; j < image.height && (j + y) < height; j++) {
      for (var i = 0; i < image.width && (i + x) < width; i++) {
        _data[(j + y) * width + i + x] = image._data[j * image.width + i];
      }
    }
  }

  void fillImageRangeAt(
    int x,
    int y,
    Image image,
    int srcX,
    int srcY,
    int width,
    int height,
  ) {
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        _data[(j + y) * this.width + i + x] =
            image._data[(j + srcY) * image.width + i + srcX];
      }
    }
  }

  Image copyAndRotate90() {
    final data = Uint32List(width * height);
    for (var j = 0; j < height; j++) {
      for (var i = 0; i < width; i++) {
        data[i * height + height - j - 1] = _data[j * width + i];
      }
    }
    return Image(data, height, width);
  }

  Color getPixel(int x, int y) => Color.fromValue(_data[y * width + x]);

  void setPixel(int x, int y, Color color) {
    _data[y * width + x] = color.value;
  }

  Uint8List encodePng() {
    throw UnsupportedError('Image PNG encoding is not available on web.');
  }
}

class Color {
  final int value;

  Color(int r, int g, int b, [int a = 255])
    : value = (a << 24) | (r << 16) | (g << 8) | b;

  Color.fromValue(this.value);

  int get r => value & 0xFF;

  int get g => (value >> 8) & 0xFF;

  int get b => (value >> 16) & 0xFF;

  int get a => (value >> 24) & 0xFF;
}

Future<Uint8List> modifyImageWithScript(Uint8List data, String script) async {
  return data;
}

import 'package:mime/mime.dart';

class FileType {
  final String ext;
  final String mime;

  const FileType(this.ext, this.mime);

  static FileType fromExtension(String ext) {
    if(ext.startsWith('.')) {
      ext = ext.substring(1);
    }
    var mime = lookupMimeType('no-file.$ext') ?? 'application/octet-stream';
    // Android doesn't support some mime types
    mime = switch(mime) {
      'text/javascript' => 'application/octet-stream',
      'application/x-cbr' => 'application/octet-stream',
      _ => mime,
    };
    return FileType(".$ext", mime);
  }
}

final _resolver = MimeTypeResolver()
  // zip
  ..addMagicNumber([0x50, 0x4B], 'application/zip')
  // 7z
  ..addMagicNumber([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], 'application/x-7z-compressed')
  // rar
  ..addMagicNumber([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07], 'application/vnd.rar');

/// AVIF may declare its brand as the major brand or a compatible brand.
bool isAvifImage(List<int> data) {
  int uint32At(int offset) =>
      (data[offset] << 24) |
      (data[offset + 1] << 16) |
      (data[offset + 2] << 8) |
      data[offset + 3];

  if (data.length < 16 || uint32At(4) != 0x66747970) return false; // ftyp
  var size = uint32At(0);
  var majorBrand = 8;
  if (size == 1) {
    size = uint32At(8) * 0x100000000 + uint32At(12);
    majorBrand = 16;
  }
  if (size < majorBrand + 8 || size > data.length || size % 4 != 0) {
    return false;
  }
  bool isAvifBrand(int offset) {
    final brand = uint32At(offset);
    return brand == 0x61766966 || brand == 0x61766973; // avif, avis
  }

  if (isAvifBrand(majorBrand)) return true;
  // The major brand is followed by a four-byte minor version.
  for (var offset = majorBrand + 8; offset < size; offset += 4) {
    if (isAvifBrand(offset)) return true;
  }
  return false;
}

FileType detectFileType(List<int> data) {
  if (isAvifImage(data)) return const FileType('.avif', 'image/avif');
  var mime = _resolver.lookup('no-file', headerBytes: data);
  var ext = mime == null ? '' : extensionFromMime(mime);
  if(ext == 'jpe') {
    ext = 'jpg';
  }
  return FileType(".$ext", mime ?? 'application/octet-stream');
}

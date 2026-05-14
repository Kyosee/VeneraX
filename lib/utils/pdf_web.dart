import 'package:venera/foundation/local.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/utils/io.dart';

typedef DecodeImage = Future<Image> Function(Uint8List data);

Future<File> createPdfFromComicIsolate(LocalComic comic, String savePath) async {
  throw UnsupportedError('PDF export is not supported on web yet.');
}

class PdfGenerator {
  final String title;
  final String author;
  final List<String> imagePaths;
  final String outputPath;
  final DecodeImage decodeImage;

  static const double a4Width = 595.0;
  static const double a4Height = 842.0;

  PdfGenerator({
    required this.title,
    required this.author,
    required this.imagePaths,
    required this.outputPath,
    required this.decodeImage,
  });

  Future<void> generate() async {
    throw UnsupportedError('PDF export is not supported on web yet.');
  }
}

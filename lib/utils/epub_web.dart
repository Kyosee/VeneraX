import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

class EpubData {
  final String title;
  final String author;
  final File cover;
  final Map<String, List<File>> chapters;

  const EpubData({
    required this.title,
    required this.author,
    required this.cover,
    required this.chapters,
  });
}

Future<File> createEpubComic(
  EpubData data,
  String cacheDir,
  String outFilePath,
) async {
  throw UnsupportedError('EPUB export is not supported on web yet.');
}

Future<File> createEpubWithLocalComic(LocalComic comic, String outFilePath) async {
  throw UnsupportedError('EPUB export is not supported on web yet.');
}

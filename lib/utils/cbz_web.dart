import 'package:venera/foundation/local.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';

class ComicMetaData {
  final String title;
  final String author;
  final List<String> tags;
  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      author = json['author'],
      tags = List<String>.from(json['tags']),
      chapters = json['chapters'] == null
          ? null
          : List<ComicChapter>.from(
              json['chapters'].map((e) => ComicChapter.fromJson(e)),
            );

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.chapters,
  });
}

class ComicChapter {
  final String title;
  final int start;
  final int end;

  Map<String, dynamic> toJson() => {'title': title, 'start': start, 'end': end};

  ComicChapter.fromJson(Map<String, dynamic> json)
    : title = json['title'],
      start = json['start'],
      end = json['end'];

  ComicChapter({required this.title, required this.start, required this.end});
}

abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    throw UnsupportedError('CBZ import is handled by web_helper on web.');
  }

  static Future<void> extractArchive(File file, Directory out) async {
    throw UnsupportedError('CBZ extraction is handled by web_helper on web.');
  }

  static Future<LocalComic> import(File file) async {
    throw UnsupportedError('CBZ import is handled by web_helper on web.');
  }

  static Future<File> export(LocalComic comic, String outFilePath) async {
    throw UnsupportedError('CBZ export is not supported on web yet.');
  }
}

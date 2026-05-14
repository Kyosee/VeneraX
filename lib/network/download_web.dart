import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';

abstract class DownloadTask with ChangeNotifier {
  double get progress;
  bool get isError;
  bool get isPaused;
  int get speed;
  String get title;
  String? get cover;
  String get message;
  String? path;
  String get id;
  ComicType get comicType;

  void cancel();
  void pause();
  void resume();
  Map<String, dynamic> toJson();
  LocalComic toLocalComic();

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    return null;
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask {
  final ComicSource source;
  final String comicId;
  final ComicDetails? comic;
  final List<String>? chapters;
  final String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    return null;
  }

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  double get progress => 0;

  @override
  bool get isError => true;

  @override
  bool get isPaused => true;

  @override
  int get speed => 0;

  @override
  String get title => comic?.title ?? comicTitle ?? comicId;

  @override
  String? get cover => comic?.cover;

  @override
  String get message => 'Web download is handled by web_helper.';

  @override
  void cancel() {}

  @override
  void pause() {}

  @override
  void resume() {
    notifyListeners();
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'ImagesDownloadTask',
      'source': source.key,
      'comicId': comicId,
      'chapters': chapters,
      'comicTitle': comicTitle,
    };
  }

  @override
  LocalComic toLocalComic() {
    final details = comic;
    return LocalComic(
      id: details?.id ?? comicId,
      title: details?.title ?? comicTitle ?? comicId,
      subtitle: details?.subTitle ?? '',
      tags: details?.tags.entries
              .expand((entry) => entry.value.map((value) => '${entry.key}:$value'))
              .toList() ??
          const [],
      directory: path ?? comicId,
      chapters: details?.chapters,
      cover: details?.cover ?? '',
      comicType: comicType,
      downloadedChapters: chapters ?? details?.chapters?.ids.toList() ?? const [],
      createdAt: DateTime.now(),
    );
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;
  final ComicDetails comic;

  ArchiveDownloadTask(this.archiveUrl, this.comic);

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    return null;
  }

  @override
  String get id => comic.id;

  @override
  ComicType get comicType => ComicType(comic.sourceKey.hashCode);

  @override
  double get progress => 0;

  @override
  bool get isError => true;

  @override
  bool get isPaused => true;

  @override
  int get speed => 0;

  @override
  String get title => comic.title;

  @override
  String? get cover => comic.cover;

  @override
  String get message => 'Archive download is handled by web_helper.';

  @override
  void cancel() {}

  @override
  void pause() {}

  @override
  void resume() {
    notifyListeners();
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      'type': 'ArchiveDownloadTask',
      'archiveUrl': archiveUrl,
      'comic': comic.toJson(),
      'path': path,
    };
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: comic.title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries
          .expand((entry) => entry.value.map((value) => '${entry.key}:$value'))
          .toList(),
      directory: path ?? comic.id,
      chapters: null,
      cover: comic.cover,
      comicType: comicType,
      downloadedChapters: const [],
      createdAt: DateTime.now(),
    );
  }
}

import 'dart:convert';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/utils/io.dart';

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  final String directory;

  final ComicChapters? chapters;

  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
  });

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => directory;

  bool get hasChapters => chapters != null;

  @override
  String get description => '';

  @override
  String get sourceKey => comicType.sourceKey;

  @override
  int? get maxPage => null;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;

  @override
  HistoryType get historyType => comicType;

  void read() {}

  @override
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'cover': cover,
      'id': id,
      'subTitle': subtitle,
      'tags': tags,
      'description': description,
      'sourceKey': sourceKey,
      'chapters': chapters?.toJson(),
    };
  }
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  final List<LocalComic> _comics = [];
  final List<dynamic> downloadingTasks = [];
  bool isInitialized = false;
  String path = '/local';

  Directory get directory => Directory(path);

  Future<void> init() async {
    isInitialized = true;
  }

  Future<String?> setNewPath(String newPath) async {
    path = newPath;
    notifyListeners();
    return null;
  }

  String findValidId(ComicType type) {
    final ids = _comics
        .where((comic) => comic.comicType == type)
        .map((comic) => int.tryParse(comic.id) ?? 0);
    final maxId = ids.isEmpty ? 0 : ids.reduce((a, b) => a > b ? a : b);
    return (maxId + 1).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    final next = id == null
        ? comic
        : LocalComic(
            id: id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: comic.chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
          );
    _comics.removeWhere(
      (item) => item.id == next.id && item.comicType == next.comicType,
    );
    _comics.add(next);
    notifyListeners();
  }

  void remove(String id, ComicType comicType) {
    _comics.removeWhere(
      (item) => item.id == id && item.comicType == comicType,
    );
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    final result = List<LocalComic>.from(_comics);
    result.sort((a, b) {
      if (sortType == LocalSortType.name) {
        return a.title.compareTo(b.title);
      }
      final value = a.createdAt.compareTo(b.createdAt);
      return sortType == LocalSortType.timeAsc ? value : -value;
    });
    return result;
  }

  LocalComic? find(String id, ComicType comicType) {
    return _comics.firstWhereOrNull(
      (item) => item.id == id && item.comicType == comicType,
    );
  }

  LocalComic? findByName(String name) {
    return _comics.firstWhereOrNull(
      (item) => item.title == name || item.directory == name,
    );
  }

  List<LocalComic> getRecent() {
    return getComics(LocalSortType.timeDesc).take(20).toList();
  }

  int get count => _comics.length;

  List<LocalComic> search(String keyword) {
    return _comics
        .where(
          (item) =>
              item.title.contains(keyword) ||
              item.subtitle.contains(keyword) ||
              item.tags.any((tag) => tag.contains(keyword)),
        )
        .toList();
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    return const [];
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    return false;
  }

  bool isDownloading(String id, ComicType type) => false;

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    return Directory(FilePath.join(path, getChapterDirectoryName(name)))
      ..createSync(recursive: true);
  }

  void completeTask(dynamic task) {
    downloadingTasks.remove(task);
    notifyListeners();
  }

  void removeTask(dynamic task) {
    downloadingTasks.remove(task);
    notifyListeners();
  }

  void moveToFirst(dynamic task) {
    if (downloadingTasks.remove(task)) {
      downloadingTasks.insert(0, task);
      notifyListeners();
    }
  }

  Future<void> saveCurrentDownloadingTasks() async {
    final data = jsonEncode(downloadingTasks);
    await File(FilePath.join('/local', 'downloading_tasks.json'))
        .writeAsString(data);
  }

  void restoreDownloadingTasks() {}

  void addTask(dynamic task) {
    downloadingTasks.add(task);
    notifyListeners();
  }

  void deleteComic(LocalComic comic, [bool removeFileOnDisk = true]) {
    remove(comic.id, comic.comicType);
  }

  void deleteComicChapters(LocalComic comic, List<String> chapters) {}

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    for (final comic in comics) {
      remove(comic.id, comic.comicType);
    }
  }

  void notifyChanges() {
    notifyListeners();
  }

  @override
  void dispose() {
    isInitialized = false;
    super.dispose();
  }

  static String getChapterDirectoryName(String name) {
    var result = name;
    for (final char in ['/', '\\', ':', '*', '?', '"', '<', '>', '|']) {
      result = result.replaceAll(char, '_');
    }
    return result;
  }
}

extension _FirstWhereOrNull<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T item) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}

enum LocalSortType {
  name('name'),
  timeAsc('time_asc'),
  timeDesc('time_desc');

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (final type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}

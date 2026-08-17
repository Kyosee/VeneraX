import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/local_comic_scanner.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('venera_local_refresh_');
  });

  tearDown(() {
    root.deleteSync(recursive: true);
  });

  void writeMetadata({
    required String title,
    required String author,
    required List<String> tags,
  }) {
    File(FilePath.join(root.path, 'details.json')).writeAsStringSync(
      jsonEncode({
        'title': title,
        'author': author,
        'description': 'Updated description',
        'genre': tags,
        'status': '2',
      }),
    );
  }

  test(
    'refreshes metadata, cover, and chapters while preserving identity',
    () async {
      File(FilePath.join(root.path, 'cover.jpg')).writeAsBytesSync([1]);
      final chapter1 = Directory(FilePath.join(root.path, 'chapter 1'))
        ..createSync();
      final chapter2 = Directory(FilePath.join(root.path, 'chapter 2'))
        ..createSync();
      File(FilePath.join(chapter1.path, '001.jpg')).writeAsBytesSync([1]);
      File(FilePath.join(chapter2.path, '001.jpg')).writeAsBytesSync([1]);
      writeMetadata(
        title: 'New title',
        author: 'New author',
        tags: ['New tag'],
      );

      final createdAt = DateTime(2024, 1, 2);
      final previous = LocalComic(
        id: '42',
        title: 'Old title',
        subtitle: 'Old author',
        tags: const ['Old tag'],
        directory: root.path,
        chapters: ComicChapters(const {'chapter 1': 'chapter 1'}),
        cover: 'old-cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: const ['chapter 1'],
        createdAt: createdAt,
        description: 'Old description',
      );

      final first = await scanLocalComicDirectory(root, previous: previous);

      expect(first, isNotNull);
      expect(first!.id, '42');
      expect(first.createdAt, createdAt);
      expect(first.title, 'New title');
      expect(first.subtitle, 'New author');
      expect(first.tags, containsAll(['New tag', 'Status:Completed']));
      expect(first.description, 'Updated description');
      expect(first.cover, 'cover.jpg');
      expect(first.chapters!.ids, ['chapter 1', 'chapter 2']);

      chapter1.deleteSync(recursive: true);
      File(FilePath.join(root.path, 'cover.jpg')).deleteSync();
      File(FilePath.join(root.path, 'poster.png')).writeAsBytesSync([2]);
      final chapter3 = Directory(FilePath.join(root.path, 'chapter 3'))
        ..createSync();
      File(FilePath.join(chapter3.path, '001.png')).writeAsBytesSync([2]);

      final second = await scanLocalComicDirectory(root, previous: first);

      expect(second, isNotNull);
      expect(second!.id, '42');
      expect(second.createdAt, createdAt);
      expect(second.cover, 'poster.png');
      expect(second.chapters!.ids, ['chapter 2', 'chapter 3']);
      expect(second.downloadedChapters, ['chapter 2', 'chapter 3']);
    },
  );

  test('uses the first chapter image when the root has no cover', () async {
    final chapter = Directory(FilePath.join(root.path, 'chapter'))
      ..createSync();
    File(FilePath.join(chapter.path, '001.webp')).writeAsBytesSync([1]);

    final comic = await scanLocalComicDirectory(root, rejectExisting: false);

    expect(comic, isNotNull);
    expect(comic!.cover, FilePath.join('chapter', '001.webp'));
  });

  test('returns null when the directory no longer exists', () async {
    final missing = Directory(FilePath.join(root.path, 'missing'));

    expect(
      await scanLocalComicDirectory(missing, rejectExisting: false),
      isNull,
    );
  });

  test('remaps reading position and read marks by stable chapter ID', () {
    LocalComic comic(List<String> chapters, {String title = 'Title'}) {
      return LocalComic(
        id: '42',
        title: title,
        subtitle: 'Author',
        tags: const [],
        directory: root.path,
        chapters: ComicChapters(Map.fromIterables(chapters, chapters)),
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: chapters,
        createdAt: DateTime(2024),
      );
    }

    final previous = comic(['chapter 1', 'chapter 2']);
    final refreshed = comic([
      'new chapter',
      'chapter 1',
      'chapter 2',
    ], title: 'Updated title');
    final history = History.fromModel(
      model: previous,
      ep: 2,
      page: 5,
      readChapters: {'1', '2'},
    );
    final originalTime = history.time;

    remapLocalComicHistory(history, previous, refreshed);

    expect(history.ep, 3);
    expect(history.page, 5);
    expect(history.readEpisode, {'2', '3'});
    expect(history.title, 'Updated title');
    expect(history.time, originalTime);
  });

  test('clears chapter history when all chapters are removed', () {
    LocalComic comic(List<String> chapters) {
      return LocalComic(
        id: '42',
        title: 'Title',
        subtitle: 'Author',
        tags: const [],
        directory: root.path,
        chapters: ComicChapters(Map.fromIterables(chapters, chapters)),
        cover: 'cover.jpg',
        comicType: ComicType.local,
        downloadedChapters: chapters,
        createdAt: DateTime(2024),
      );
    }

    final previous = comic(['chapter 1', 'chapter 2']);
    final refreshed = comic([]);
    final history = History.fromModel(
      model: previous,
      ep: 2,
      page: 5,
      readChapters: {'1', '2'},
    );

    remapLocalComicHistory(history, previous, refreshed);

    expect(history.ep, 0);
    expect(history.page, 0);
    expect(history.readEpisode, isEmpty);
  });
}

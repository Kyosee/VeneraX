import 'dart:convert';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_7zip/flutter_7zip.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/comic_metadata_resolver.dart';
import 'package:zip_flutter/zip_flutter.dart';

class ComicMetaData {
  final String title;

  final String author;

  final String artist;

  final String description;

  /// mihon status: "" / "0".."6" 或 ComicInfo 原文
  final String status;

  final List<String> tags;

  final List<ComicChapter>? chapters;

  Map<String, dynamic> toJson() => {
    'title': title,
    'author': author,
    'artist': artist,
    'description': description,
    'status': status,
    'tags': tags,
    'chapters': chapters?.map((e) => e.toJson()).toList(),
  };

  ComicMetaData.fromJson(Map<String, dynamic> json)
    : title = json['title'] ?? '',
      author = json['author'] ?? '',
      artist = json['artist'] ?? '',
      description = json['description'] ?? '',
      status = json['status'] ?? '',
      tags = List<String>.from(json['tags'] ?? const []),
      chapters = json['chapters'] == null
          ? null
          : List<ComicChapter>.from(
              json['chapters'].map((e) => ComicChapter.fromJson(e)),
            );

  ComicMetaData({
    required this.title,
    required this.author,
    required this.tags,
    this.artist = '',
    this.description = '',
    this.status = '',
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

/// Comic Book Archive. Currently supports CBZ, ZIP and 7Z formats.
abstract class CBZ {
  static Future<FileType> checkType(File file) async {
    var header = <int>[];
    await for (var bytes in file.openRead()) {
      header.addAll(bytes);
      if (header.length >= 32) break;
    }
    return detectFileType(header);
  }

  static Future<void> extractArchive(File file, Directory out) async {
    var fileType = await checkType(file);
    if (fileType.mime == 'application/zip') {
      await ZipFile.openAndExtractAsync(file.path, out.path, 4);
    } else if (fileType.mime == "application/x-7z-compressed") {
      await SZArchive.extractIsolates(file.path, out.path, 4);
    } else {
      throw Exception('Unsupported archive type');
    }
  }

  /// Image extensions recognised as comic pages, lower-case, no dot.
  static const _imageExts = {
    'jpg',
    'jpeg',
    'jpe',
    'png',
    'webp',
    'gif',
    'bmp',
    'avif',
  };

  /// Whether [name] is a comic page by extension. Case-insensitive: archives
  /// from other tools often carry `.JPG`.
  @visibleForTesting
  static bool isImageName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExts.contains(name.substring(dot + 1).toLowerCase());
  }

  static bool _isImage(File f) => isImageName(f.name);

  /// Images directly inside [dir], in natural order.
  static List<File> _imagesIn(Directory dir) {
    var files = dir.listSync().whereType<File>().where(_isImage).toList();
    files.sort((a, b) => naturalCompare(a.name, b.name));
    return files;
  }

  /// `2.jpg` before `10.jpg`, and case-insensitive elsewhere. Archives written
  /// by other tools rarely zero-pad, so a plain string sort scrambles pages.
  @visibleForTesting
  static int naturalCompare(String a, String b) {
    final ra = RegExp(r'\d+|\D+').allMatches(a).map((m) => m[0]!).toList();
    final rb = RegExp(r'\d+|\D+').allMatches(b).map((m) => m[0]!).toList();
    for (var i = 0; i < ra.length && i < rb.length; i++) {
      final na = int.tryParse(ra[i]), nb = int.tryParse(rb[i]);
      final c = (na != null && nb != null)
          ? na.compareTo(nb)
          : ra[i].toLowerCase().compareTo(rb[i].toLowerCase());
      if (c != 0) return c;
    }
    return ra.length.compareTo(rb.length);
  }

  /// Descends through single-child wrapper directories, so an archive whose
  /// pages sit under `<name>/` (or `<name>/<name>/`) is treated as flat.
  static Directory _unwrap(Directory dir) {
    for (var i = 0; i < 8; i++) {
      var entries = dir.listSync();
      if (entries.length != 1 || entries.first is! Directory) return dir;
      dir = entries.first as Directory;
    }
    return dir;
  }

  /// Imports every comic contained in [file]. Usually one, but an archive that
  /// bundles several comics (each in its own subdirectory, or nested archives)
  /// yields one entry per comic instead of failing as "no images".
  static Future<List<LocalComic>> importAll(File file) async {
    var cache = Directory(
      FilePath.join(
        App.cachePath,
        'cbz_import_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync(recursive: true);
    try {
      await extractArchive(file, cache);
      var root = _unwrap(cache);
      var fallbackTitle = file.name.contains('.')
          ? file.name.substring(0, file.name.lastIndexOf('.'))
          : file.name;
      return await _importDir(root, fallbackTitle);
    } finally {
      await cache.deleteIgnoreError(recursive: true);
    }
  }

  /// Turns one extracted directory into comics. [fallbackTitle] is used when the
  /// directory carries no metadata of its own.
  static Future<List<LocalComic>> _importDir(
    Directory dir,
    String fallbackTitle,
  ) async {
    var entries = dir.listSync();
    var subDirs = entries.whereType<Directory>().toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    var nestedArchives = entries
        .whereType<File>()
        .where((e) => archiveExts.contains(e.extension.toLowerCase()))
        .toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    var rootImages = _imagesIn(dir);
    var metaData = resolveMetadataOrNull(dir);

    // Pages at this level, or metadata describing this level: one comic, whose
    // chapters are the subdirectories when it has any. Let failures propagate —
    // there is a single comic here, so its error is the archive's error.
    if (rootImages.isNotEmpty || metaData != null) {
      var comic = await _importSingle(
        dir,
        metaData ?? ComicMetaData(title: fallbackTitle, author: '', tags: []),
        rootImages,
        subDirs,
      );
      if (comic != null) return [comic];
    }

    // Otherwise every subdirectory and every nested archive is its own comic.
    // A failing member is skipped so it can't take the rest of the batch down.
    var result = <LocalComic>[];
    for (var sub in subDirs) {
      try {
        result.addAll(await _importDir(_unwrap(sub), sub.name));
      } catch (e, s) {
        Log.error('Import Comic', e.toString(), s);
      }
    }
    for (var nested in nestedArchives) {
      try {
        result.addAll(await importAll(nested));
      } catch (e, s) {
        Log.error('Import Comic', e.toString(), s);
      }
    }
    if (result.isEmpty && subDirs.isEmpty && nestedArchives.isEmpty) {
      throw Exception('No images found in the archive');
    }
    return result;
  }

  /// Archive extensions that may appear nested inside an archive.
  static const archiveExts = {'cbz', 'zip', '7z', 'cb7'};

  /// Copies one comic out of [dir] into the local library. Returns null when
  /// there is nothing importable (no pages anywhere under [dir]).
  static Future<LocalComic?> _importSingle(
    Directory dir,
    ComicMetaData metaData,
    List<File> rootImages,
    List<Directory> subDirs,
  ) async {
    // Chapter layout: subdirectories holding images. Preferred over the
    // metadata's index ranges, since the directories are the actual truth.
    var chapterFiles = <String, List<File>>{};
    for (var sub in subDirs) {
      var images = _imagesIn(_unwrap(sub));
      if (images.isNotEmpty) {
        chapterFiles[sub.name] = images;
      }
    }

    var files = rootImages.toList();
    File? coverFile = files.firstWhereOrNull(
      (e) => e.basenameWithoutExt.toLowerCase() == 'cover',
    );
    if (coverFile != null) {
      files.remove(coverFile);
    }
    // An archive holding only a cover has no pages to read; don't register it.
    if (files.isEmpty && chapterFiles.isEmpty) return null;
    coverFile ??= files.firstOrNull ?? chapterFiles.values.first.first;

    var title = metaData.title.isNotEmpty ? metaData.title : dir.name;
    if (LocalManager().findByName(title) != null) {
      throw Exception('Comic with name $title already exists');
    }

    Map<String, String>? cpMap;
    var dest = Directory(
      FilePath.join(
        LocalManager().path,
        findValidDirectoryName(LocalManager().path, title),
      ),
    );
    dest.createSync(recursive: true);
    await coverFile.copyMem(
      FilePath.join(dest.path, 'cover.${coverFile.extension}'),
    );

    if (chapterFiles.isNotEmpty) {
      // Root images alongside chapter directories (other than the cover) would
      // have no chapter to live in; fold them into a leading chapter under a
      // name no subdirectory already claims.
      if (files.isNotEmpty) {
        var name = title;
        while (chapterFiles.containsKey(name)) {
          name = '$name ';
        }
        chapterFiles = {name: files, ...chapterFiles};
      }
      cpMap = <String, String>{};
      var i = 0;
      for (var chapter in chapterFiles.entries) {
        cpMap[i.toString()] = chapter.key;
        var chapterDir = Directory(FilePath.join(dest.path, i.toString()));
        chapterDir.createSync();
        await _copyPages(chapter.value, chapterDir);
        i++;
      }
    } else if (metaData.chapters != null &&
        metaData.chapters!.isNotEmpty &&
        rangesFit(metaData.chapters!, files.length)) {
      // Flat archive whose metadata splits the pages into chapters by index.
      cpMap = <String, String>{};
      var i = 0;
      for (var chapter in metaData.chapters!) {
        cpMap[i.toString()] = chapter.title;
        var chapterDir = Directory(FilePath.join(dest.path, i.toString()));
        chapterDir.createSync();
        await _copyPages(files.sublist(chapter.start - 1, chapter.end), chapterDir);
        i++;
      }
    } else {
      await _copyPages(files, dest);
    }

    return LocalComic(
      id: LocalManager().findValidId(ComicType.local),
      title: title,
      subtitle: metaData.author.isNotEmpty ? metaData.author : metaData.artist,
      tags: metaData.tags,
      comicType: ComicType.local,
      directory: dest.name,
      chapters: ComicChapters.fromJsonOrNull(cpMap),
      downloadedChapters: cpMap?.keys.toList() ?? [],
      cover: 'cover.${coverFile.extension}',
      createdAt: DateTime.now(),
      description: metaData.description,
    );
  }

  /// Whether every chapter range stays inside a page list of [total] entries.
  /// A mismatch means the metadata does not describe this archive's pages, and
  /// slicing by it would throw.
  @visibleForTesting
  static bool rangesFit(List<ComicChapter> chapters, int total) {
    for (var c in chapters) {
      if (c.start < 1 || c.end < c.start || c.end > total) return false;
    }
    return true;
  }

  static Future<void> _copyPages(List<File> pages, Directory dest) async {
    for (var i = 0; i < pages.length; i++) {
      var src = pages[i];
      await src.copyMem(
        FilePath.join(dest.path, '${i + 1}.${src.extension}'),
      );
    }
  }

  static Future<File> export(LocalComic comic, String outFilePath) async {
    // Unique per-call staging dir + guaranteed cleanup: the old fixed
    // 'cbz_export' dir was left behind whenever an export threw mid-way
    // (large libraries copy every image, so a disk-full/IO error is real),
    // and only got cleared on the next export's entry.
    var cache = Directory(
      FilePath.join(
        App.cachePath,
        'cbz_export_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    if (cache.existsSync()) cache.deleteSync(recursive: true);
    cache.createSync();
    try {
      List<ComicChapter>? chapters;
      if (comic.chapters == null) {
        var images = await LocalManager().getImages(
          comic.id,
          comic.comicType,
          1,
        );
        int i = 1;
        for (var image in images) {
          var src = File(image.replaceFirst('file://', ''));
          var width = images.length.toString().length;
          var dstName =
              '${i.toString().padLeft(width, '0')}.${image.split('.').last}';
          var dst = File(FilePath.join(cache.path, dstName));
          await src.copyMem(dst.path);
          i++;
        }
      } else {
        chapters = [];
        var allImages = <String>[];
        for (var c in comic.downloadedChapters) {
          var chapterName = comic.chapters![c];
          var images = await LocalManager().getImages(
            comic.id,
            comic.comicType,
            c,
          );
          allImages.addAll(images);
          var chapter = ComicChapter(
            title: chapterName!,
            start: chapters.length + 1,
            end: chapters.length + images.length,
          );
          chapters.add(chapter);
        }
        int i = 1;
        for (var image in allImages) {
          var src = File(image);
          var width = allImages.length.toString().length;
          var dstName =
              '${i.toString().padLeft(width, '0')}.${image.split('.').last}';
          var dst = File(FilePath.join(cache.path, dstName));
          await src.copyMem(dst.path);
          i++;
        }
      }
      var cover = comic.coverFile;
      await cover.copyMem(
        FilePath.join(cache.path, 'cover.${cover.path.split('.').last}'),
      );
      final statusTag = comic.tags.firstWhere(
        (t) => t.startsWith('Status:'),
        orElse: () => '',
      );
      final metaData = ComicMetaData(
        title: comic.title,
        author: comic.subtitle,
        tags: comic.tags,
        chapters: chapters,
        description: comic.description,
        status: statusTag.isEmpty ? '' : statusTag.substring('Status:'.length),
      );
      await File(
        FilePath.join(cache.path, 'metadata.json'),
      ).writeAsString(jsonEncode(metaData));
      await File(
        FilePath.join(cache.path, 'ComicInfo.xml'),
      ).writeAsString(_buildComicInfoXml(metaData));
      var cbz = File(outFilePath);
      if (cbz.existsSync()) cbz.deleteSync();
      await _compress(cache.path, cbz.path);
      return cbz;
    } finally {
      cache.deleteIgnoreError(recursive: true);
    }
  }

  static String _buildComicInfoXml(ComicMetaData data) {
    final buffer = StringBuffer();
    buffer.writeln('<?xml version="1.0" encoding="utf-8"?>');
    buffer.writeln(
      '<ComicInfo xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">',
    );

    buffer.writeln('  <Title>${_escapeXml(data.title)}</Title>');
    buffer.writeln('  <Series>${_escapeXml(data.title)}</Series>');

    if (data.author.isNotEmpty) {
      buffer.writeln('  <Writer>${_escapeXml(data.author)}</Writer>');
    }

    if (data.artist.isNotEmpty) {
      buffer.writeln('  <Penciller>${_escapeXml(data.artist)}</Penciller>');
    }

    if (data.description.isNotEmpty) {
      buffer.writeln('  <Summary>${_escapeXml(data.description)}</Summary>');
    }

    if (data.status.isNotEmpty) {
      buffer.writeln('  <Status>${_escapeXml(data.status)}</Status>');
    }

    if (data.tags.isNotEmpty) {
      var tags = data.tags;
      if (tags.length > 5) {
        tags = tags.sublist(0, 5);
      }
      buffer.writeln('  <Genre>${_escapeXml(tags.join(', '))}</Genre>');
    }

    if (data.chapters != null && data.chapters!.isNotEmpty) {
      final chaptersInfo = data.chapters!
          .map(
            (chapter) =>
                '${_escapeXml(chapter.title)}: ${chapter.start}-${chapter.end}',
          )
          .join('; ');
      buffer.writeln('  <Notes>Chapters: $chaptersInfo</Notes>');
    }

    buffer.writeln('  <Manga>Unknown</Manga>');
    buffer.writeln('  <BlackAndWhite>Unknown</BlackAndWhite>');

    final now = DateTime.now();
    buffer.writeln('  <Year>${now.year}</Year>');

    buffer.writeln('</ComicInfo>');
    return buffer.toString();
  }

  static String _escapeXml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  static _compress(String src, String dst) async {
    await ZipFile.compressFolderAsync(src, dst, 4);
  }
}

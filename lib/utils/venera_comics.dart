import 'dart:convert';
import 'dart:isolate';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

class VeneraComicsManifest {
  final int version;
  final int exportedAt;
  final List<VeneraComicEntry> comics;

  VeneraComicsManifest({
    required this.version,
    required this.exportedAt,
    required this.comics,
  });

  factory VeneraComicsManifest.fromJson(Map<String, dynamic> json) {
    return VeneraComicsManifest(
      version: json['version'] as int,
      exportedAt: json['exportedAt'] as int,
      comics: (json['comics'] as List)
          .map((e) => VeneraComicEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'exportedAt': exportedAt,
        'comics': comics.map((e) => e.toJson()).toList(),
      };
}

class VeneraComicEntry {
  final String id;
  final int comicType;
  final String title;
  final bool hasImages;

  VeneraComicEntry({
    required this.id,
    required this.comicType,
    required this.title,
    required this.hasImages,
  });

  factory VeneraComicEntry.fromJson(Map<String, dynamic> json) {
    return VeneraComicEntry(
      id: json['id'] as String,
      comicType: json['comicType'] as int,
      title: json['title'] as String,
      hasImages: json['hasImages'] as bool,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'comicType': comicType,
        'title': title,
        'hasImages': hasImages,
      };
}

/// Packs selected comics into a .venera_comics zip file.
/// Returns the created file in cache directory.
Future<File> exportVeneraComics(
  List<LocalComic> comics, {
  bool includeImages = true,
  void Function(int current, int total)? onProgress,
}) async {
  final exportDir = Directory(
    FilePath.join(App.cachePath, 'venera_comics_export'),
  );
  if (exportDir.existsSync()) {
    exportDir.deleteSync(recursive: true);
  }
  exportDir.createSync(recursive: true);

  // Build manifest
  final entries = <VeneraComicEntry>[];
  for (final comic in comics) {
    final hasImages = includeImages &&
        comic.status == LocalComicStatus.downloaded;
    entries.add(VeneraComicEntry(
      id: comic.id,
      comicType: comic.comicType.value,
      title: comic.title,
      hasImages: hasImages,
    ));
  }

  final manifest = VeneraComicsManifest(
    version: 1,
    exportedAt: DateTime.now().millisecondsSinceEpoch,
    comics: entries,
  );

  // Write manifest
  final manifestFile = File(FilePath.join(exportDir.path, 'manifest.json'));
  manifestFile.writeAsStringSync(jsonEncode(manifest.toJson()));

  // Write each comic
  for (var i = 0; i < comics.length; i++) {
    final comic = comics[i];
    final entry = entries[i];
    final comicDir = Directory(
      FilePath.join(exportDir.path, 'comics',
          '${comic.id}_${comic.comicType.value}'),
    );
    comicDir.createSync(recursive: true);

    // Write meta.json
    final meta = <String, dynamic>{
      'id': comic.id,
      'title': comic.title,
      'subtitle': comic.subtitle,
      'tags': comic.tags,
      'directory': comic.directory,
      'chapters': comic.chapters?.toJson(),
      'cover': comic.cover,
      'comicType': comic.comicType.value,
      'downloadedChapters': comic.downloadedChapters,
      'createdAt': comic.createdAt.millisecondsSinceEpoch,
    };
    File(FilePath.join(comicDir.path, 'meta.json'))
        .writeAsStringSync(jsonEncode(meta));

    // Copy cover
    final coverFile = comic.coverFile;
    if (coverFile.existsSync()) {
      coverFile.copySync(FilePath.join(comicDir.path, comic.cover));
    }

    // Copy chapter images if needed
    if (entry.hasImages) {
      final baseDir = Directory(comic.baseDir);
      if (baseDir.existsSync()) {
        for (final entity in baseDir.listSync()) {
          if (entity is Directory) {
            final chapterId = entity.name;
            final destChapter = Directory(
              FilePath.join(comicDir.path, chapterId),
            );
            destChapter.createSync();
            for (final file in entity.listSync()) {
              if (file is File) {
                file.copySync(FilePath.join(destChapter.path, file.name));
              }
            }
          }
        }
      }
    }

    onProgress?.call(i + 1, comics.length);
  }

  // Create zip
  final time = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final zipPath = FilePath.join(App.cachePath, '$time.venera_comics');
  final exportDirPath = exportDir.path;
  await Isolate.run(() {
    final zipFile = ZipFile.open(zipPath);
    _addDirectoryToZip(zipFile, exportDirPath, exportDirPath);
    zipFile.close();
  });

  // Clean up temp dir
  exportDir.deleteSync(recursive: true);
  return File(zipPath);
}

void _addDirectoryToZip(ZipFile zipFile, String dirPath, String basePath) {
  final dir = Directory(dirPath);
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is File) {
      final relativePath = entity.path
          .substring(basePath.length + 1)
          .replaceAll('\\', '/');
      zipFile.addFile(relativePath, entity.path);
    }
  }
}

/// Reads manifest from a .venera_comics file without full extraction.
Future<VeneraComicsManifest> readVeneraComicsManifest(File file) async {
  final tempDir = Directory(
    FilePath.join(App.cachePath, 'venera_comics_preview'),
  );
  if (tempDir.existsSync()) {
    tempDir.deleteSync(recursive: true);
  }
  tempDir.createSync(recursive: true);

  final tempDirPath = tempDir.path;
  final filePath = file.path;
  await Isolate.run(() {
    ZipFile.openAndExtract(filePath, tempDirPath);
  });

  final manifestFile = File(FilePath.join(tempDirPath, 'manifest.json'));
  final json = jsonDecode(manifestFile.readAsStringSync());
  final manifest =
      VeneraComicsManifest.fromJson(json as Map<String, dynamic>);

  tempDir.deleteSync(recursive: true);
  return manifest;
}

/// Moves [src] to [destPath], falling back to copy when the move fails.
///
/// Importing extracts files into a temporary directory and then transfers them
/// into the local library. Using rename (move) instead of copy+delete keeps the
/// operation atomic on the same volume and avoids the high-volume
/// create/modify/delete file pattern that antivirus heuristics (e.g. 360) flag
/// as ransomware. When the move fails — most commonly because the cache and
/// data directories live on different volumes — we fall back to the original
/// copy behavior so the import still succeeds.
void _moveOrCopyFile(File src, String destPath) {
  try {
    src.renameSync(destPath);
  } catch (_) {
    src.copySync(destPath);
  }
}

/// Imports comics from a .venera_comics file.
/// Returns the number of successfully imported comics.
Future<int> importVeneraComics(
  File file, {
  void Function(int current, int total)? onProgress,
}) async {
  final importDir = Directory(
    FilePath.join(App.cachePath, 'venera_comics_import'),
  );
  if (importDir.existsSync()) {
    importDir.deleteSync(recursive: true);
  }
  importDir.createSync(recursive: true);

  final importDirPath = importDir.path;
  final filePath = file.path;
  await Isolate.run(() {
    ZipFile.openAndExtract(filePath, importDirPath);
  });

  final manifestFile = File(FilePath.join(importDirPath, 'manifest.json'));
  final json = jsonDecode(manifestFile.readAsStringSync());
  final manifest =
      VeneraComicsManifest.fromJson(json as Map<String, dynamic>);

  var imported = 0;
  final total = manifest.comics.length;

  for (var i = 0; i < total; i++) {
    final entry = manifest.comics[i];
    final comicDirName = '${entry.id}_${entry.comicType}';
    final comicDir = Directory(
      FilePath.join(importDirPath, 'comics', comicDirName),
    );
    if (!comicDir.existsSync()) continue;

    final metaFile = File(FilePath.join(comicDir.path, 'meta.json'));
    if (!metaFile.existsSync()) continue;

    final meta =
        jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;

    final comic = LocalComic(
      id: meta['id'] as String,
      title: meta['title'] as String,
      subtitle: (meta['subtitle'] as String?) ?? '',
      tags: List<String>.from(meta['tags'] ?? []),
      directory: comicDirName,
      chapters: ComicChapters.fromJsonOrNull(meta['chapters']),
      cover: (meta['cover'] as String?) ?? 'cover.jpg',
      comicType: ComicType(meta['comicType'] as int),
      downloadedChapters:
          List<String>.from(meta['downloadedChapters'] ?? []),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (meta['createdAt'] as int?) ?? 0,
      ),
    );

    await LocalManager().add(comic);

    // Copy files to local comics directory
    final destDir = Directory(
      FilePath.join(LocalManager().path, comicDirName),
    );
    if (!destDir.existsSync()) {
      destDir.createSync(recursive: true);
    }

    // Move cover file (falls back to copy across volumes)
    final coverName = (meta['cover'] as String?) ?? 'cover.jpg';
    final srcCover = File(FilePath.join(comicDir.path, coverName));
    if (srcCover.existsSync()) {
      _moveOrCopyFile(srcCover, FilePath.join(destDir.path, coverName));
    }

    // Move chapter directories if hasImages
    if (entry.hasImages) {
      for (final entity in comicDir.listSync()) {
        if (entity is Directory) {
          final dirName = entity.name;
          if (dirName == 'meta.json') continue;
          final destChapter = Directory(
            FilePath.join(destDir.path, dirName),
          );
          if (!destChapter.existsSync()) {
            destChapter.createSync();
          }
          for (final file in entity.listSync()) {
            if (file is File) {
              _moveOrCopyFile(file, FilePath.join(destChapter.path, file.name));
            }
          }
        }
      }
    }

    imported++;
    onProgress?.call(i + 1, total);
  }

  // Clean up
  importDir.deleteSync(recursive: true);
  return imported;
}
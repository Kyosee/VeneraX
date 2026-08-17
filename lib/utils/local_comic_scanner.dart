import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/comic_metadata_resolver.dart';
import 'package:venera/utils/io.dart';

const _localComicImageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'};

bool _isLocalComicImage(File file) {
  final name = file.name.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot >= 0 &&
      _localComicImageExtensions.contains(name.substring(dot + 1));
}

/// Scans a local comic directory without writing any application state.
///
/// Passing [previous] refreshes an existing comic: stable identity and storage
/// fields are preserved while metadata, cover, and chapters come from disk.
Future<LocalComic?> scanLocalComicDirectory(
  Directory directory, {
  LocalComic? previous,
  String? id,
  String? title,
  String? subtitle,
  List<String>? tags,
  DateTime? createTime,
  bool useRelativePath = false,
  bool rejectExisting = true,
}) async {
  if (!await directory.exists()) return null;

  final metadata = resolveMetadataOrNull(directory);
  final resolvedTitle =
      title ??
      ((metadata?.title.isNotEmpty ?? false)
          ? metadata!.title
          : previous?.title ?? directory.name);
  if (previous == null &&
      rejectExisting &&
      LocalManager().findByName(resolvedTitle) != null) {
    Log.info('Import Comic', 'Comic already exists: $resolvedTitle');
    return null;
  }

  final chapterDirectories = <Directory>[];
  final rootImages = <File>[];
  await for (final entry in directory.list()) {
    if (entry is Directory) {
      await for (final child in entry.list()) {
        if (child is Directory) {
          Log.info(
            'Import Comic',
            'Invalid Chapter: ${entry.name}\nA directory is found in the chapter directory.',
          );
          return null;
        }
      }
      chapterDirectories.add(entry);
    } else if (entry is File && _isLocalComicImage(entry)) {
      rootImages.add(entry);
    }
  }

  chapterDirectories.sort((a, b) => a.name.compareTo(b.name));
  rootImages.sort((a, b) => a.name.compareTo(b.name));

  String? coverPath;
  for (final image in rootImages) {
    if (image.name.toLowerCase().startsWith('cover')) {
      coverPath = image.name;
      break;
    }
  }
  coverPath ??= rootImages.isEmpty ? null : rootImages.first.name;

  if (coverPath == null && chapterDirectories.isNotEmpty) {
    for (final chapterDirectory in chapterDirectories) {
      final chapterImages = <File>[];
      await for (final entry in chapterDirectory.list()) {
        if (entry is File && _isLocalComicImage(entry)) {
          chapterImages.add(entry);
        }
      }
      chapterImages.sort((a, b) => a.name.compareTo(b.name));
      if (chapterImages.isNotEmpty) {
        coverPath = FilePath.join(
          chapterDirectory.name,
          chapterImages.first.name,
        );
        break;
      }
    }
  }

  if (coverPath == null) {
    Log.info(
      'Import Comic',
      'Invalid Comic: $resolvedTitle\nNo cover image found.',
    );
    return null;
  }

  final chapterNames = chapterDirectories.map((dir) => dir.name).toList();
  final resolvedSubtitle = (subtitle?.isNotEmpty ?? false)
      ? subtitle!
      : metadata != null
      ? (metadata.author.isNotEmpty ? metadata.author : metadata.artist)
      : previous?.subtitle ?? '';
  final resolvedTags = (tags?.isNotEmpty ?? false)
      ? List<String>.from(tags!)
      : metadata != null
      ? List<String>.from(metadata.tags)
      : List<String>.from(previous?.tags ?? const []);
  final storedDirectory =
      previous?.directory ??
      (useRelativePath ? directory.name : directory.path);

  return LocalComic(
    id: id ?? previous?.id ?? '0',
    title: resolvedTitle,
    subtitle: resolvedSubtitle,
    tags: resolvedTags,
    directory: storedDirectory,
    chapters: chapterNames.isEmpty
        ? null
        : ComicChapters(Map.fromIterables(chapterNames, chapterNames)),
    cover: coverPath,
    comicType: previous?.comicType ?? ComicType.local,
    downloadedChapters: chapterNames,
    createdAt: createTime ?? previous?.createdAt ?? DateTime.now(),
    description: metadata?.description ?? previous?.description ?? '',
  );
}

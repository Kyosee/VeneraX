import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/local_comic_scanner.dart';
import 'base_image_provider.dart';
import 'local_comic_image.dart' as image_provider;

class LocalComicImageProvider
    extends BaseImageProvider<image_provider.LocalComicImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const LocalComicImageProvider(this.comic);

  final LocalComic comic;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    // A placeholder for a queued download task (merged into the local comics
    // grid before it is scheduled) has no directory yet. Its `baseDir` would
    // resolve to the downloads root, and the fallback scan below would then
    // return the first downloaded comic's cover for EVERY such placeholder
    // (issue #53). Without a real own directory there is no cover to load.
    if (comic.directory.isEmpty) {
      throw "Error: Cover not found.";
    }
    File? file = comic.coverFile;
    if(! await file.exists()) {
      file = null;
      var dir = Directory(comic.baseDir);
      if (! await dir.exists()) {
        throw "Error: Comic not found.";
      }
      Directory? firstDir;
      await for (var entity in dir.list()) {
        if (entity is File && isLocalComicImage(entity)) {
          file = entity;
          break;
        } else if (entity is Directory) {
          firstDir ??= entity;
        }
      }
      if(file == null && firstDir != null) {
        await for (var entity in firstDir.list()) {
          if (entity is File && isLocalComicImage(entity)) {
            file = entity;
            break;
          }
        }
      }
    }
    if(file == null) {
      throw "Error: Cover not found.";
    }
    checkStop();
    var data = await file.readAsBytes();
    if(data.isEmpty) {
      throw "Exception: Empty file(${file.path}).";
    }
    return data;
  }

  @override
  Future<LocalComicImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "local${comic.id}${comic.comicType.value}";
}

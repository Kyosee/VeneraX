import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera/foundation/appdata.dart';

/// Resolves the reader's translated variant without coupling the decision to
/// image loading. A non-null result is displayed immediately; otherwise a
/// ready local engine may continue the existing background translation path.
@visibleForTesting
Future<Uint8List?> resolveReaderTranslation({
  required Future<Uint8List?> Function() renderStored,
  required bool isEngineReady,
  required VoidCallback schedule,
}) async {
  final rendered = await renderStored();
  if (rendered != null) {
    return rendered;
  }
  if (isEngineReady) {
    schedule();
  }
  return null;
}

class ReaderImageProvider
    extends BaseImageProvider<image_provider.ReaderImageProvider> {
  /// Image provider for normal image.
  const ReaderImageProvider(
    this.imageKey,
    this.sourceKey,
    this.cid,
    this.eid,
    this.page, {
    this.enableResize = false,
    this.translationKey,
    this.translationConfig,
    this.translated = false,
    this.comicTitle = '',
    this.comicCover = '',
    this.chapterTitle = '',
  });

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  /// Cache key of the offline-translated variant of this page, or null when
  /// translation is off. When set, a cached or synced stored translation is
  /// shown before falling back to the original and background translation.
  final String? translationKey;

  /// This comic's own language pair + text-removal mode. Non-null exactly when
  /// [translationKey] is.
  final TranslationConfig? translationConfig;

  /// Whether the translated page is already known to exist. Only used to
  /// change the provider identity so the reader can swap the image in place
  /// once a background translation completes.
  final bool translated;

  final String comicTitle;
  final String comicCover;
  final String chapterTitle;

  @override
  final bool enableResize;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    Uint8List? imageBytes;
    if (imageKey.startsWith('file://')) {
      var file = File(imageKey);
      if (await file.exists()) {
        imageBytes = await readLocalPage(file);
      } else {
        throw "Error: File not found.";
      }
    } else {
      await for (var event in ImageDownloader.loadComicImage(
        imageKey,
        sourceKey,
        cid,
        eid,
      )) {
        checkStop();
        chunkEvents.add(
          ImageChunkEvent(
            cumulativeBytesLoaded: event.currentBytes,
            expectedTotalBytes: event.totalBytes,
          ),
        );
        if (event.imageBytes != null) {
          imageBytes = event.imageBytes;
          break;
        }
      }
    }
    if (imageBytes == null) {
      throw "Error: Empty response body.";
    }
    if (translationKey != null) {
      var config = translationConfig ?? TranslationConfig.of(cid, sourceKey);
      var chapter = ImageTranslationService.chapterIdentity(
        cid: cid,
        sourceKey: sourceKey,
        eid: eid,
        config: config,
        comicTitle: comicTitle,
        comicCover: comicCover,
        chapterTitle: chapterTitle,
      );
      var translatedFile = await ImageTranslationService.instance
          .findTranslated(translationKey!, config.mode);
      if (translatedFile != null) {
        ImageTranslationService.instance.markTranslated(
          translationKey!,
          config.mode,
        );
        return await translatedFile.readAsBytes();
      }
      var rendered = await resolveReaderTranslation(
        renderStored: () => ImageTranslationService.instance.renderStoredPage(
          translationKey!,
          imageBytes!,
          config.mode,
          chapter: chapter,
        ),
        isEngineReady: ImageTranslationService.isReadyForLang(
          config.sourceLang,
        ),
        schedule: () {
          // No synced result exists, but local models are usable: show the
          // original for now and translate it in the background. When it lands
          // the provider cache is evicted and the next resolve picks it up.
          ImageTranslationService.instance.schedule(
            translationKey!,
            cid,
            sourceKey,
            imageBytes!,
            config,
            () {
              ImageTranslationService.evictImage(this);
            },
            chapter: chapter,
          );
        },
      );
      if (rendered != null) {
        return rendered;
      }
    }
    if (appdata.settings['enableCustomImageProcessing']) {
      var script = appdata.settings['customImageProcessing'].toString();
      if (!script.contains('function processImage')) {
        return imageBytes;
      }
      var func = JsEngine().runCode('''
        (() => {
          $script
          return processImage;
        })()
      ''');
      if (func is JSInvokable) {
        var autoFreeFunc = JSAutoFreeFunction(func);
        var result = autoFreeFunc([imageBytes, cid, eid, page, sourceKey]);
        if (result is Uint8List) {
          imageBytes = result;
        } else if (result is Future) {
          var futureResult = await result;
          if (futureResult is Uint8List) {
            imageBytes = futureResult;
          }
        } else if (result is Map) {
          var image = result['image'];
          if (image is Uint8List) {
            imageBytes = image;
          } else if (image is Future) {
            JSAutoFreeFunction? onCancel;
            if (result['onCancel'] is JSInvokable) {
              onCancel = JSAutoFreeFunction(result['onCancel']);
            }
            if (onCancel == null) {
              var futureImage = await image;
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            } else {
              dynamic futureImage;
              image.then((value) {
                futureImage = value;
                futureImage ??= Uint8List(0);
              });
              while (futureImage == null) {
                try {
                  checkStop();
                } catch (e) {
                  onCancel([]);
                  rethrow;
                }
                await Future.delayed(Duration(milliseconds: 50));
              }
              if (futureImage is Uint8List) {
                imageBytes = futureImage;
              }
            }
          }
        }
      }
    }
    return imageBytes!;
  }

  @override
  Future<ReaderImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key =>
      "$imageKey@$sourceKey@$cid@$eid@$enableResize"
      "${translationKey == null ? '' : '@tr:$translated'}";
}

/// Reads one page file from the local library.
///
/// Zero bytes does not mean the page is blank: on Android, a library kept in a
/// folder granted through the system file picker reports a failed read as zero
/// bytes rather than as an error. Retry first — that clears the transient
/// failures — then let the file's own size decide whether it is truly blank.
Future<Uint8List> readLocalPage(File file) async {
  const attempts = 3;
  for (var i = 0; i < attempts; i++) {
    if (i > 0) {
      await Future.delayed(Duration(milliseconds: 50 * i));
    }
    var bytes = await file.readAsBytes();
    if (bytes.isNotEmpty) {
      return bytes;
    }
  }
  int size;
  try {
    size = await file.length();
  } catch (_) {
    size = -1; // unknown: treat as a failed read, not as a blank file
  }
  if (size == 0) {
    throw ImageLoadingPermanentException(
      "${"Image file is empty".tl}: ${file.name}",
    );
  }
  throw "${"Failed to read image file".tl}: ${file.name}";
}

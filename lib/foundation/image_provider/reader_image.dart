import 'dart:async' show Future;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/io.dart';
import 'base_image_provider.dart';
import 'reader_image.dart' as image_provider;
import 'package:venera/foundation/appdata.dart';

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
  });

  final String imageKey;

  final String? sourceKey;

  final String cid;

  final String eid;

  final int page;

  /// Cache key of the offline-translated variant of this page, or null when
  /// translation is off. When set, a cached translated page is shown instead
  /// of the original; otherwise the original is shown and a translation is
  /// scheduled in the background.
  final String? translationKey;

  /// This comic's own language pair + text-removal mode. Non-null exactly when
  /// [translationKey] is.
  final TranslationConfig? translationConfig;

  /// Whether the translated page is already known to exist. Only used to
  /// change the provider identity so the reader can swap the image in place
  /// once a background translation completes.
  final bool translated;

  @override
  final bool enableResize;

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    Uint8List? imageBytes;
    if (imageKey.startsWith('file://')) {
      var file = File(imageKey);
      if (await file.exists()) {
        imageBytes = await file.readAsBytes();
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
      var translatedFile = await ImageTranslationService.instance
          .findTranslated(translationKey!, config.mode);
      if (translatedFile != null) {
        ImageTranslationService.instance.markTranslated(
          translationKey!,
          config.mode,
        );
        return await translatedFile.readAsBytes();
      }
      if (ImageTranslationService.isReadyForLang(config.sourceLang)) {
        // Models are usable: show the original for now and translate in the
        // background. When it lands the reader is notified, this provider's
        // cache entry is evicted and the next resolve picks up the translated
        // file above.
        ImageTranslationService.instance.schedule(
          translationKey!,
          cid,
          sourceKey,
          imageBytes,
          config,
          () {
            ImageTranslationService.evictImage(this);
          },
        );
      } else {
        // No models installed (e.g. a device that received translations over
        // WebDAV): render straight from a synced stored result if there is one.
        // Nothing is translated here — a page with no stored result just shows
        // the original.
        var rendered = await ImageTranslationService.instance.renderStoredPage(
          translationKey!,
          imageBytes,
          config.mode,
        );
        if (rendered != null) {
          return rendered;
        }
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

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/page_renderer.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/opencc.dart';

/// Result of the analysis stage: render-ready regions plus the language
/// distribution of ALL translatable blocks (including ones skipped for
/// already being in the target language) — the service uses the votes to
/// lock a comic's dominant language.
class PageAnalysis {
  PageAnalysis(this.regions, this.languageVotes, [this.newGlossary = const {}]);

  final List<TranslatedRegion> regions;
  final Map<String, int> languageVotes;

  /// Name/proper-noun translations the model reported for this page, to be
  /// merged into the comic's running glossary for later pages.
  final Map<String, String> newGlossary;
}

/// Result of the OCR-only stage ([PageTranslationPipeline.ocrPage]): everything
/// known about a page before the LLM is called. Split out so a batch caller can
/// OCR several pages, send their [pending] blocks in ONE translation request,
/// then fold the results back per page. [ready] holds regions that need no LLM
/// (an already-target-language block converted zh→zh-TW).
class PageOcr {
  PageOcr(this.ready, this.pending, this.languageVotes);

  /// Regions already finalized without translation (e.g. zh→zh-TW conversion).
  final List<TranslatedRegion> ready;

  /// Blocks awaiting LLM translation, in order. Empty means the page needs no
  /// request; combined with an empty [ready] it means nothing translatable.
  final List<OcrBlock> pending;

  final Map<String, int> languageVotes;

  bool get isEmpty => ready.isEmpty && pending.isEmpty;
}

/// Per-page translation orchestrator. Runs on the main isolate but does no
/// heavy work itself: image decoding goes through the engine, detection/OCR
/// run inside the worker isolate, and translation is one request to the
/// user-configured LLM endpoint.
class PageTranslationPipeline {
  PageTranslationPipeline();

  /// OCR + translation. Returns render-ready regions; an empty list means
  /// the page has no text worth translating.
  Future<PageAnalysis> analyzePage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
    Map<String, String> glossary = const {},
  }) async {
    var ocr = await ocrPage(
      imageBytes,
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
    if (ocr.pending.isEmpty) {
      return PageAnalysis(ocr.ready, ocr.languageVotes, const {});
    }
    var result = await LlmTranslator.translateBatch(
      ocr.pending.map((b) => b.text).toList(),
      targetLang,
      glossary: glossary,
    );
    var regions = [
      ...ocr.ready,
      ...regionsFromTranslation(ocr.pending, result.texts),
    ];
    return PageAnalysis(regions, ocr.languageVotes, result.glossary);
  }

  /// OCR-only stage: decode, recognize, vote on language and apply the
  /// no-LLM zh→zh-TW conversion, returning the blocks still awaiting the model.
  /// Shared by [analyzePage] (reader, one page) and the batch pre-translation
  /// path (several pages, one request).
  Future<PageOcr> ocrPage(
    Uint8List imageBytes, {
    required String sourceLang,
    required String targetLang,
  }) async {
    var image = await _decode(imageBytes);
    var paths = TranslationModels.workerPaths();
    var blocks = await TranslationWorker.instance.ocrPage(
      image,
      sourceLang: sourceLang,
      paths: paths,
    );
    blocks = blocks.where((b) => _isTranslatable(b.text)).toList();
    var votes = <String, int>{};
    for (var block in blocks) {
      votes[block.language] = (votes[block.language] ?? 0) + 1;
    }
    if (blocks.isEmpty) {
      return PageOcr(const [], const [], votes);
    }

    var targetBase = targetLang == 'zh-TW' ? 'zh' : targetLang;
    var ready = <TranslatedRegion>[];
    var pending = <OcrBlock>[];
    for (var block in blocks) {
      if (block.language == targetBase) {
        // Already in the target language. The only useful transform left is
        // the simplified/traditional conversion.
        if (targetLang == 'zh-TW' && block.language == 'zh') {
          var converted = OpenCC.simplifiedToTraditional(block.text);
          if (converted != block.text) {
            ready.add(_region(block, converted));
          }
        }
        continue;
      }
      pending.add(block);
    }
    return PageOcr(ready, pending, votes);
  }

  /// Turns [pending] blocks and their aligned [texts] into render-ready
  /// regions, dropping empties and no-ops. [texts] must align with [pending]
  /// (extra entries are ignored, missing ones treated as empty).
  List<TranslatedRegion> regionsFromTranslation(
    List<OcrBlock> pending,
    List<String> texts,
  ) {
    var regions = <TranslatedRegion>[];
    for (var i = 0; i < pending.length; i++) {
      var text = (i < texts.length ? texts[i] : '').trim();
      if (text.isEmpty || text == pending[i].text) continue;
      regions.add(_region(pending[i], text));
    }
    return regions;
  }

  /// Renders [regions] over the page. Split from [analyzePage] so a page
  /// whose rendered image was evicted can be rebuilt from the cached text
  /// results alone.
  Future<Uint8List> renderPage(
    Uint8List imageBytes,
    List<TranslatedRegion> regions,
  ) async {
    var image = await _decode(imageBytes);
    return await renderTranslatedPage(imageBytes, image, regions);
  }

  TranslatedRegion _region(OcrBlock block, String text) {
    return TranslatedRegion(
      rect: block.rect,
      text: text,
      backgroundColor: block.backgroundColor,
      textColor: block.textColor,
    );
  }

  bool _isTranslatable(String text) {
    if (text.length < 2) return false;
    // Pure digits/punctuation (page numbers, sfx dashes) are not worth a
    // translation pass.
    return text.runes.any((r) {
      return r > 0x2E80 || (r >= 0x41 && r <= 0x7A);
    });
  }

  Future<RgbaImage> _decode(Uint8List bytes) async {
    var buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    var descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Bound decoded size: huge pages (webtoon strips) are downscaled so the
    // pipeline's RGBA buffers stay within a sane memory budget, and no
    // dimension exceeds common GPU texture limits (the rendered result goes
    // through Picture.toImage).
    const maxPixels = 12 * 1024 * 1024;
    const maxDimension = 8000;
    var w = descriptor.width;
    var h = descriptor.height;
    var scale = 1.0;
    if (w * h > maxPixels) {
      scale = math.sqrt(maxPixels / (w * h));
    }
    if (math.max(w, h) * scale > maxDimension) {
      scale = maxDimension / math.max(w, h);
    }
    int? targetW;
    int? targetH;
    if (scale < 1.0) {
      // Both dimensions must be passed: instantiateCodec does not derive the
      // missing one from the aspect ratio.
      targetW = math.max(1, (w * scale).round());
      targetH = math.max(1, (h * scale).round());
    }
    var codec = await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
    var frame = await codec.getNextFrame();
    var image = frame.image;
    try {
      var data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        throw Exception('Failed to read image pixels');
      }
      return RgbaImage(image.width, image.height, data.buffer.asUint8List());
    } finally {
      image.dispose();
      codec.dispose();
      descriptor.dispose();
      buffer.dispose();
    }
  }

  Future<void> release() async {
    TranslationWorker.instance.release();
  }
}

/// Kept for logging clarity when a page fails half-way; the worker reports
/// errors as exceptions already, so this is only used by the service layer.
void logTranslationFailure(Object error, StackTrace stack) {
  Log.error('Image Translation', error.toString(), stack);
}

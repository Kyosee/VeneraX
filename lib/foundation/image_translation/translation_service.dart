import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

class _TranslationTask {
  _TranslationTask(this.cacheKey, this.comicKey, this.imageBytes);

  final String cacheKey;

  /// Identifies the comic ('cid@sourceKey') for the per-comic language lock.
  final String comicKey;
  final Uint8List imageBytes;
  final listeners = <VoidCallback>[];
}

/// Schedules page translations, caches results and notifies the reader when
/// a page is ready so it can swap the displayed image.
///
/// Two cache levels keep repeat reads free:
/// - the rendered page image (30 days, large, may be LRU-evicted), and
/// - the text-level result (regions + translations, ~KB, 90 days): when only
///   the image was evicted the page is re-rendered locally without paying
///   for OCR or another translation request.
class ImageTranslationService with ChangeNotifier {
  ImageTranslationService._();

  static final instance = ImageTranslationService._();

  static const _imageCacheDuration = 30 * 24 * 60 * 60 * 1000;
  static const _textCacheDuration = 90 * 24 * 60 * 60 * 1000;
  static const _maxQueueLength = 16;
  static const _failureRetryDelay = Duration(minutes: 5);
  static const _idleReleaseDelay = Duration(seconds: 90);

  final _queue = <_TranslationTask>[];
  final _active = <_TranslationTask>{};
  final _failures = <String, DateTime>{};
  final _completed = <String>{};

  /// Pages known (via the text cache) to contain nothing translatable.
  final _noContent = <String>{};
  PageTranslationPipeline? _pipeline;
  Timer? _releaseTimer;

  /// Whether a translated page is known to exist for [cacheKey]. Feeds the
  /// provider identity so a finished background translation produces a new
  /// provider and the visible image swaps in place.
  bool isTranslated(String cacheKey) => _completed.contains(cacheKey);

  void markTranslated(String cacheKey) => _completed.add(cacheKey);

  static String get sourceLang =>
      appdata.settings['imageTranslationSource'] as String? ?? 'auto';

  static String get targetLang =>
      appdata.settings['imageTranslationTarget'] as String? ?? 'zh';

  /// LLM translation is network-bound, so a second page's OCR can run in the
  /// worker while the first waits for its response.
  int get _maxConcurrent => 2;

  /// Whether detection/OCR models AND the user's LLM endpoint are usable
  /// right now.
  static bool get isReady {
    if (!TranslationModels.isReadyFor(sourceLang)) {
      return false;
    }
    return LlmTranslator.isConfigured;
  }

  /// Whether translation should run for a comic right now (per-comic reader
  /// setting + usable engine).
  static bool enabledFor(String cid, String sourceKey) {
    return appdata.settings.getReaderSetting(
              cid,
              sourceKey,
              'enableImageTranslation',
            ) ==
            true &&
        isReady;
  }

  static String get _cachePrefix =>
      'pageTranslation@$sourceLang>$targetLang@';

  /// Cache key of the translated variant of one page. It embeds the
  /// language pair so changing settings re-translates instead of serving
  /// stale pages.
  static String cacheKeyFor(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return '$_cachePrefix$imageKey@$sourceKey@$cid@$eid';
  }

  static String _textKeyOf(String cacheKey) => 'text:$cacheKey';

  Future<File?> findTranslated(String cacheKey) {
    return CacheManager().findCache(cacheKey);
  }

  /// Whether a fully rendered translated page (not just the text result) is
  /// already cached. Used by the pre-translation task manager to skip pages
  /// that were done in an earlier run or read online.
  Future<bool> hasRenderedPage(String cacheKey) async {
    return await CacheManager().findCache(cacheKey) != null;
  }

  /// Translates one page synchronously (awaitable), writing both cache levels,
  /// and returns whether a translated page was produced. Unlike [schedule]
  /// this does not go through the reader's bounded/LRU queue — the
  /// pre-translation task manager drives its own pacing and needs to await
  /// each page. Reuses the shared pipeline and language lock.
  ///
  /// Returns true when a translated page image is now cached (or already was),
  /// false when the page has no translatable text.
  Future<bool> translateOne(
    String cacheKey,
    String comicKey,
    Uint8List imageBytes, {
    bool Function()? shouldCancel,
  }) async {
    if (await CacheManager().findCache(cacheKey) != null) {
      _completed.add(cacheKey);
      return true;
    }
    var pipeline = _pipeline ??= PageTranslationPipeline();
    var regions = await _loadTextCache(cacheKey);
    if (regions == null) {
      var analysis = await pipeline.analyzePage(
        imageBytes,
        sourceLang: _effectiveSourceFor(comicKey),
        targetLang: targetLang,
      );
      _updateLanguageLock(comicKey, analysis.languageVotes);
      regions = analysis.regions;
      await CacheManager().writeCache(
        _textKeyOf(cacheKey),
        utf8.encode(jsonEncode([for (var r in regions) r.toJson()])),
        _textCacheDuration,
      );
    }
    if (shouldCancel?.call() ?? false) {
      throw const PipelineCanceled();
    }
    if (regions.isEmpty) {
      _noContent.add(cacheKey);
      return false;
    }
    var rendered = await pipeline.renderPage(imageBytes, regions);
    await CacheManager().writeCache(cacheKey, rendered, _imageCacheDuration);
    _completed.add(cacheKey);
    return true;
  }

  /// Releases pipeline/model memory when no reader is scheduling and the
  /// pre-translation manager has finished a batch. Safe to call any time.
  void releaseIfIdle() {
    if (_active.isEmpty && _queue.isEmpty) {
      _scheduleRelease();
    }
  }

  /// Queues a page for translation. [onTranslated] fires (once per caller)
  /// after the translated page is cached, right before listeners are
  /// notified — providers use it to evict their stale image cache entry.
  void schedule(
    String cacheKey,
    String comicKey,
    Uint8List imageBytes,
    VoidCallback onTranslated,
  ) {
    if (_noContent.contains(cacheKey)) {
      return;
    }
    var failedAt = _failures[cacheKey];
    if (failedAt != null) {
      if (DateTime.now().difference(failedAt) < _failureRetryDelay) {
        return;
      }
      _failures.remove(cacheKey);
    }
    var existing = _queue.where((t) => t.cacheKey == cacheKey).firstOrNull;
    if (existing != null) {
      existing.listeners.add(onTranslated);
      return;
    }
    if (_queue.length >= _maxQueueLength) {
      // Prefer recent requests: the reader schedules pages in reading order,
      // so the oldest not-yet-started page is the one furthest behind.
      var oldest = _queue.where((t) => !_active.contains(t)).firstOrNull;
      if (oldest == null) {
        return;
      }
      _queue.remove(oldest);
    }
    _queue.add(
      _TranslationTask(cacheKey, comicKey, imageBytes)
        ..listeners.add(onTranslated),
    );
    _releaseTimer?.cancel();
    _pump();
  }

  void _pump() {
    while (_active.length < _maxConcurrent) {
      var next = _queue.where((t) => !_active.contains(t)).firstOrNull;
      if (next == null) break;
      _active.add(next);
      unawaited(_process(next));
    }
  }

  Future<void> _process(_TranslationTask task) async {
    try {
      // The settings may have changed while queued; skip stale entries.
      if (!task.cacheKey.startsWith(_cachePrefix)) {
        return;
      }
      if (await CacheManager().findCache(task.cacheKey) != null) {
        _notifyDone(task);
        return;
      }
      var pipeline = _pipeline ??= PageTranslationPipeline();

      var regions = await _loadTextCache(task.cacheKey);
      if (regions == null) {
        var analysis = await pipeline.analyzePage(
          task.imageBytes,
          sourceLang: _effectiveSourceFor(task.comicKey),
          targetLang: targetLang,
        );
        _updateLanguageLock(task.comicKey, analysis.languageVotes);
        regions = analysis.regions;
        await CacheManager().writeCache(
          _textKeyOf(task.cacheKey),
          utf8.encode(jsonEncode([for (var r in regions) r.toJson()])),
          _textCacheDuration,
        );
      }
      if (regions.isEmpty) {
        // Nothing translatable; the cached empty result keeps this page from
        // being re-analyzed, even across restarts.
        _noContent.add(task.cacheKey);
        return;
      }
      var rendered = await pipeline.renderPage(task.imageBytes, regions);
      await CacheManager().writeCache(
        task.cacheKey,
        rendered,
        _imageCacheDuration,
      );
      _notifyDone(task);
    } on PipelineCanceled {
      // ignore
    } catch (e, s) {
      _failures[task.cacheKey] = DateTime.now();
      Log.error('Image Translation', 'Failed to translate page: $e', s);
    } finally {
      _queue.remove(task);
      _active.remove(task);
      if (_queue.isEmpty && _active.isEmpty) {
        _scheduleRelease();
      } else {
        _pump();
      }
    }
  }

  Future<List<TranslatedRegion>?> _loadTextCache(String cacheKey) async {
    try {
      var file = await CacheManager().findCache(_textKeyOf(cacheKey));
      if (file == null) return null;
      var data = jsonDecode(await file.readAsString());
      if (data is! List) return null;
      return [
        for (var item in data)
          TranslatedRegion.fromJson(Map<String, dynamic>.from(item)),
      ];
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------
  // Per-comic language lock
  // ---------------------------------------------------------------------

  /// A comic is almost always written in a single language. Once enough
  /// blocks agree, the detected language is remembered for the comic so
  /// later pages skip the multi-engine fallback chain entirely.
  static const _comicLangsKey = 'imageTranslationComicLangs';
  Map<String, String>? _comicLangs;

  Map<String, String> get _langLocks {
    if (_comicLangs == null) {
      var stored = appdata.implicitData[_comicLangsKey];
      _comicLangs = stored is Map
          ? stored.map((k, v) => MapEntry(k.toString(), v.toString()))
          : <String, String>{};
    }
    return _comicLangs!;
  }

  String _effectiveSourceFor(String comicKey) {
    if (sourceLang != 'auto') {
      return sourceLang;
    }
    return _langLocks[comicKey] ?? 'auto';
  }

  void _updateLanguageLock(String comicKey, Map<String, int> votes) {
    if (sourceLang != 'auto' || _langLocks.containsKey(comicKey)) {
      return;
    }
    var total = votes.values.fold(0, (a, b) => a + b);
    if (total < 4) return;
    var dominant = votes.entries.reduce(
      (a, b) => a.value >= b.value ? a : b,
    );
    if (dominant.value / total < 0.75) return;
    var locks = _langLocks;
    locks[comicKey] = dominant.key;
    // Bound the persisted map; entries are tiny but unbounded growth in
    // implicitData is never OK.
    while (locks.length > 300) {
      locks.remove(locks.keys.first);
    }
    appdata.implicitData[_comicLangsKey] = locks;
    appdata.writeImplicitData();
    Log.info(
      'Image Translation',
      'Locked language "${dominant.key}" for $comicKey',
    );
  }

  void _notifyDone(_TranslationTask task) {
    _completed.add(task.cacheKey);
    for (var listener in task.listeners) {
      try {
        listener();
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Frees model memory after the reader has been idle for a while.
  void _scheduleRelease() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_idleReleaseDelay, () {
      if (_active.isNotEmpty || _queue.isNotEmpty) return;
      var pipeline = _pipeline;
      _pipeline = null;
      unawaited(pipeline?.release());
    });
  }

  /// Drops queued-but-not-started work (e.g. when leaving the reader).
  void clearQueue() {
    _queue.removeWhere((task) => !_active.contains(task));
    if (_queue.isEmpty && _active.isEmpty) {
      _scheduleRelease();
    }
  }

  /// Evicts a provider's stale image-cache entry so the next resolve loads
  /// the translated page.
  static void evictImage(ImageProvider provider) {
    scheduleMicrotask(() {
      PaintingBinding.instance.imageCache.evict(provider);
    });
  }
}

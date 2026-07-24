import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_store.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

/// Per-page translation state exposed to the reader UI for status feedback.
enum PageTranslationStatus {
  /// Not queued, not done — nothing to show.
  idle,

  /// Queued or actively being translated.
  translating,

  /// A translated page is cached and shown.
  translated,

  /// The page has no translatable text (shown as-is).
  noContent,

  /// Translation failed; the reader offers a retry.
  failed,
}

/// Result of the shared translation core [_translateToCache].
enum _TranslateOutcome {
  /// A rendered translated page was already in the cache.
  alreadyCached,

  /// A translated page was produced and written to the cache this call.
  translated,

  /// The page has no translatable text; an empty text-result was cached.
  noContent,
}

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
  static const _maxQueueLength = 16;
  static const _failureRetryDelay = Duration(minutes: 5);
  static const _idleReleaseDelay = Duration(seconds: 90);

  final _queue = <_TranslationTask>[];
  final _active = <_TranslationTask>{};
  final _failures = <String, DateTime>{};
  final _completed = <String>{};

  /// Last error message per failed page, for the reader's retry affordance.
  final _errors = <String, String>{};

  /// Pages known (via the text cache) to contain nothing translatable.
  final _noContent = <String>{};
  PageTranslationPipeline? _pipeline;
  Timer? _releaseTimer;

  /// Whether a translated page is known to exist for [cacheKey]. Feeds the
  /// provider identity so a finished background translation produces a new
  /// provider and the visible image swaps in place.
  bool isTranslated(String cacheKey) => _completed.contains(cacheKey);

  void markTranslated(String cacheKey) => _completed.add(cacheKey);

  /// Current per-page translation state, for the reader status badge.
  PageTranslationStatus statusOf(String cacheKey) {
    if (_completed.contains(cacheKey)) return PageTranslationStatus.translated;
    if (_noContent.contains(cacheKey)) return PageTranslationStatus.noContent;
    if (_active.any((t) => t.cacheKey == cacheKey)) {
      return PageTranslationStatus.translating;
    }
    if (_failures.containsKey(cacheKey)) return PageTranslationStatus.failed;
    if (_queue.any((t) => t.cacheKey == cacheKey)) {
      return PageTranslationStatus.translating;
    }
    return PageTranslationStatus.idle;
  }

  /// Last failure message for [cacheKey], if the page failed to translate.
  String? errorOf(String cacheKey) => _errors[cacheKey];

  /// Clears the failure back-off for [cacheKey] so the reader can retry it
  /// immediately instead of waiting out [_failureRetryDelay].
  void clearFailure(String cacheKey) {
    _failures.remove(cacheKey);
    _errors.remove(cacheKey);
  }

  /// Trims an exception to a short, single-line message for display.
  static String _briefError(Object e) {
    var text = e.toString().replaceAll('\n', ' ').trim();
    const prefix = 'Exception: ';
    if (text.startsWith(prefix)) {
      text = text.substring(prefix.length);
    }
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

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

  /// The implicitData keys holding per-comic translation preferences: the
  /// per-comic enable switch, the learned language locks, the glossary and the
  /// blocked terms. These are serialized into the backup explicitly (they live
  /// in implicitData, which is not part of appdata.json) and merged back on
  /// import — see the export/import paths in utils/data.dart.
  static const syncedPrefKeys = [
    _enabledComicsKey,
    _comicLangsKey,
    _comicGlossaryKey,
    _blockedTermsKey,
  ];

  /// Drops the lazy in-memory caches of the per-comic preference maps so the
  /// next access re-reads implicitData. Called after an import replaces those
  /// maps underneath us — without it the service would keep serving the
  /// pre-import glossary / language locks / blocked terms.
  void reloadSyncedPrefs() {
    _comicLangs = null;
    _glossaries = null;
    _blockedTerms = null;
    notifyListeners();
  }

  /// Comics the user explicitly turned translation on for. This is a dedicated
  /// per-comic store — NOT the reader-settings channel, which falls back to a
  /// single global value when a comic has no per-comic override. Translation
  /// spends tokens, so it must never be globally "on": enabling it for one
  /// comic must not translate every other comic the user opens.
  static const _enabledComicsKey = 'imageTranslationEnabledComics';

  /// Whether the user turned translation on for this specific comic.
  static bool isEnabledForComic(String cid, String sourceKey) {
    var stored = appdata.implicitData[_enabledComicsKey];
    if (stored is! Map) return false;
    return stored['$cid@$sourceKey'] == true;
  }

  /// Turns translation on/off for one comic only.
  static void setEnabledForComic(String cid, String sourceKey, bool enabled) {
    var stored = appdata.implicitData[_enabledComicsKey];
    var map = stored is Map
        ? Map<String, dynamic>.from(stored)
        : <String, dynamic>{};
    var comicKey = '$cid@$sourceKey';
    if (enabled) {
      map[comicKey] = true;
    } else {
      map.remove(comicKey);
    }
    appdata.implicitData[_enabledComicsKey] = map;
    appdata.writeImplicitData();
    instance.notifyListeners();
  }

  /// Whether translation should run for a comic right now (per-comic switch +
  /// usable engine).
  static bool enabledFor(String cid, String sourceKey) {
    return isEnabledForComic(cid, sourceKey) && isReady;
  }

  static String get _cachePrefix =>
      'pageTranslation@$sourceLang>$targetLang@';

  /// Prefix covering every cached page of one comic, for the current language
  /// pair. The comic/chapter identity comes BEFORE the per-image part so a
  /// whole comic — or a single chapter — can be invalidated with one prefix
  /// delete (see [CacheManager.deleteByPrefix]).
  static String comicScopePrefix(String? sourceKey, String cid) {
    return '$_cachePrefix$sourceKey@$cid@';
  }

  /// Prefix covering every cached page of one chapter.
  static String chapterScopePrefix(String? sourceKey, String cid, String eid) {
    return '${comicScopePrefix(sourceKey, cid)}$eid@';
  }

  /// Cache key of the translated variant of one page. It embeds the
  /// language pair so changing settings re-translates instead of serving
  /// stale pages. Scope (source/comic/chapter) comes first, image key last,
  /// so a comic or chapter forms a deletable key prefix.
  static String cacheKeyFor(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return '${chapterScopePrefix(sourceKey, cid, eid)}$imageKey';
  }

  /// Removes the rendered-image cache AND the durable stored text for every
  /// page under [scopePrefix], so the next view/pre-translate re-runs from
  /// scratch. Also clears the in-memory "done/empty/failed" markers for those
  /// keys. The store keys on the same prefix, so one call drops both levels.
  Future<int> invalidateScope(String scopePrefix) async {
    var removed = await CacheManager().deleteByPrefix(scopePrefix);
    TranslationStore().deleteByPrefix(scopePrefix);
    _completed.removeWhere((k) => k.startsWith(scopePrefix));
    _noContent.removeWhere((k) => k.startsWith(scopePrefix));
    _failures.removeWhere((k, _) => k.startsWith(scopePrefix));
    return removed;
  }

  /// Re-translates a whole comic: drops every stored page + rendered image for
  /// the current language pair AND the comic's learned glossary, so the next
  /// read / pre-translate starts clean. [eid] limits it to one chapter, in
  /// which case the glossary is kept (other chapters still rely on it).
  Future<void> retranslate(String cid, String sourceKey, {String? eid}) async {
    if (eid != null) {
      await invalidateScope(chapterScopePrefix(sourceKey, cid, eid));
    } else {
      await invalidateScope(comicScopePrefix(sourceKey, cid));
      _clearGlossary('$cid@$sourceKey');
    }
    notifyListeners();
  }

  /// Clears every translated page across all comics: the rendered-image cache
  /// and the durable stored text both go. The learned per-comic language locks
  /// and glossaries are left intact. Returns the rendered-image count removed.
  Future<int> clearAllTranslationCache() async {
    var removed = await CacheManager().deleteByPrefix('pageTranslation@');
    TranslationStore().clearAll();
    _completed.clear();
    _noContent.clear();
    _failures.clear();
    notifyListeners();
    return removed;
  }

  Future<File?> findTranslated(String cacheKey) {
    return CacheManager().findCache(cacheKey);
  }

  /// Whether a fully rendered translated page (not just the text result) is
  /// already cached. Used by the pre-translation task manager to skip pages
  /// that were done in an earlier run or read online.
  Future<bool> hasRenderedPage(String cacheKey) async {
    return await CacheManager().findCache(cacheKey) != null;
  }

  /// How many pages of one chapter already have a stored text result — the
  /// durable, WebDAV-synced source of truth (empty-result "no text" pages count
  /// too). This is what lets a device show a chapter as already translated after
  /// receiving another device's translations, without needing that device's
  /// (non-synced) task records. Language-pair scoped, same as every cache key.
  static int storedPageCount(String cid, String sourceKey, String eid) {
    return TranslationStore().countByPrefix(
      chapterScopePrefix(sourceKey, cid, eid),
    );
  }

  /// Renders a page purely from an already-stored text result — no OCR, no LLM,
  /// no models. This is what lets a device that received another device's
  /// translations over WebDAV show them even without any translation models
  /// installed: the durable [TranslationStore] rows synced across, and the
  /// renderer only needs the page bytes + regions + the app font.
  ///
  /// Returns the rendered PNG bytes when a stored result produced a visible
  /// page (and caches it), or null when there is no stored result for this page
  /// or the stored result is empty (the page has no translatable text) — in
  /// both null cases the caller should show the original image. Never triggers
  /// a translation; a page missing from the store stays untranslated here.
  Future<Uint8List?> renderStoredPage(
    String cacheKey,
    Uint8List imageBytes,
  ) async {
    var cached = await CacheManager().findCache(cacheKey);
    if (cached != null) {
      _completed.add(cacheKey);
      return await cached.readAsBytes();
    }
    var regions = TranslationStore().get(cacheKey);
    if (regions == null) {
      // Never translated on any device that synced here; show the original.
      return null;
    }
    if (regions.isEmpty) {
      // Stored "no translatable text" result; nothing to render.
      _noContent.add(cacheKey);
      return null;
    }
    var pipeline = _pipeline ??= PageTranslationPipeline();
    var rendered = await pipeline.renderPage(imageBytes, regions);
    await CacheManager().writeCache(cacheKey, rendered, _imageCacheDuration);
    _completed.add(cacheKey);
    return rendered;
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
    var outcome = await _translateToCache(
      cacheKey,
      comicKey,
      imageBytes,
      shouldCancel: shouldCancel,
    );
    if (outcome == _TranslateOutcome.noContent) {
      return false;
    }
    _completed.add(cacheKey);
    return true;
  }

  /// The shared translation core used by both the awaitable [translateOne]
  /// (pre-translation manager) and the queued [_process] (reader). It performs
  /// the cache probe, OCR/translation analysis (with the text-level cache),
  /// language lock + glossary updates and the final render, writing both cache
  /// levels. Callers layer their own bookkeeping (queue management, listener
  /// notification, failure tracking) on top of the returned outcome.
  Future<_TranslateOutcome> _translateToCache(
    String cacheKey,
    String comicKey,
    Uint8List imageBytes, {
    bool Function()? shouldCancel,
  }) async {
    if (await CacheManager().findCache(cacheKey) != null) {
      return _TranslateOutcome.alreadyCached;
    }
    var pipeline = _pipeline ??= PageTranslationPipeline();
    // The store is the durable source of truth: a hit (local, or merged from
    // another device via WebDAV) skips OCR and the paid LLM request entirely.
    var regions = TranslationStore().get(cacheKey);
    if (regions == null) {
      var analysis = await pipeline.analyzePage(
        imageBytes,
        sourceLang: _effectiveSourceFor(comicKey),
        targetLang: targetLang,
        glossary: _glossaryFor(comicKey),
      );
      _updateLanguageLock(comicKey, analysis.languageVotes);
      _mergeGlossary(comicKey, analysis.newGlossary);
      regions = analysis.regions;
      TranslationStore().put(cacheKey, regions);
    }
    if (shouldCancel?.call() ?? false) {
      throw const PipelineCanceled();
    }
    if (regions.isEmpty) {
      // Nothing translatable; the cached empty result keeps this page from
      // being re-analyzed, even across restarts.
      _noContent.add(cacheKey);
      return _TranslateOutcome.noContent;
    }
    var rendered = await pipeline.renderPage(imageBytes, regions);
    await CacheManager().writeCache(cacheKey, rendered, _imageCacheDuration);
    return _TranslateOutcome.translated;
  }

  /// Translates a group of pages with ONE shared LLM request — used only by
  /// the background pre-translation manager (the reader keeps its per-page
  /// queue in [schedule]/[_process]). Pages already rendered, served from the
  /// text cache, or found to hold no translatable text need no request; the
  /// rest have their recognized bubbles concatenated into a single
  /// [LlmTranslator.translateBatch] call, so the model sees cross-page context
  /// and the comic spends one request per group instead of one per page.
  ///
  /// OCR, rendering and both cache levels stay per-page (only the translation
  /// request is grouped), so a partially finished group resumes cleanly. If the
  /// shared request fails, every page that needed it is reported failed for
  /// this run (to retry later) while pages resolved from cache still succeed.
  ///
  /// Returns a success flag per input page, aligned with [pages]; it only
  /// throws [PipelineCanceled] when [shouldCancel] fires between pages.
  Future<List<bool>> translatePageGroup(
    List<({String cacheKey, Uint8List imageBytes})> pages,
    String comicKey, {
    bool Function()? shouldCancel,
  }) async {
    var success = List.filled(pages.length, false);
    if (pages.isEmpty) return success;
    var pipeline = _pipeline ??= PageTranslationPipeline();
    var sourceLang = _effectiveSourceFor(comicKey);

    // Final regions per page once known; null = a fresh-OCR page still awaiting
    // the LLM (composed in stage 2) or a page that failed and is skipped.
    var regionsOf = List<List<TranslatedRegion>?>.filled(pages.length, null);
    // Freshly OCR'd pages awaiting translation; null = resolved from cache,
    // already rendered, or failed during OCR.
    var pendingOcr = List<PageOcr?>.filled(pages.length, null);
    // Text cache is (re)written only for freshly OCR'd pages, matching
    // [_translateToCache]; cache-sourced regions are never rewritten.
    var freshOcr = List<bool>.filled(pages.length, false);
    // Pages needing no further work (rendered-cache hit or OCR failure).
    var settled = List<bool>.filled(pages.length, false);

    // Stage 1 — resolve each page as far as possible without the LLM.
    for (var i = 0; i < pages.length; i++) {
      if (shouldCancel?.call() ?? false) throw const PipelineCanceled();
      var p = pages[i];
      try {
        if (await CacheManager().findCache(p.cacheKey) != null) {
          _completed.add(p.cacheKey);
          success[i] = true;
          settled[i] = true;
          continue;
        }
        var stored = TranslationStore().get(p.cacheKey);
        if (stored != null) {
          regionsOf[i] = stored;
          continue;
        }
        pendingOcr[i] = await pipeline.ocrPage(
          p.imageBytes,
          sourceLang: sourceLang,
          targetLang: targetLang,
        );
        freshOcr[i] = true;
      } catch (e, s) {
        Log.warning('Image Translation', 'Batch OCR failed: $e\n$s');
        settled[i] = true; // failed; success[i] stays false
      }
    }

    // Stage 2 — one request for the whole group's pending bubbles. Language
    // votes and glossary updates fold across the group, then results are
    // sliced back to each page.
    var votes = <String, int>{};
    for (var po in pendingOcr) {
      po?.languageVotes.forEach((k, v) => votes[k] = (votes[k] ?? 0) + v);
    }
    _updateLanguageLock(comicKey, votes);

    var texts = <String>[];
    var sliceAt = List<int>.filled(pages.length, 0);
    for (var i = 0; i < pages.length; i++) {
      var po = pendingOcr[i];
      if (po == null) continue;
      sliceAt[i] = texts.length;
      texts.addAll(po.pending.map((b) => b.text));
    }

    var batchOk = true;
    var translated = const <String>[];
    if (texts.isNotEmpty) {
      if (shouldCancel?.call() ?? false) throw const PipelineCanceled();
      try {
        var result = await LlmTranslator.translateBatch(
          texts,
          targetLang,
          glossary: _glossaryFor(comicKey),
        );
        _mergeGlossary(comicKey, result.glossary);
        translated = result.texts;
      } catch (e, s) {
        Log.warning('Image Translation', 'Batch translate failed: $e\n$s');
        batchOk = false;
      }
    }

    for (var i = 0; i < pages.length; i++) {
      var po = pendingOcr[i];
      if (po == null) continue;
      if (!batchOk && po.pending.isNotEmpty) {
        settled[i] = true; // request failed; retry this page on a later run
        continue;
      }
      var slice = po.pending.isEmpty || !batchOk
          ? const <String>[]
          : translated.sublist(
              sliceAt[i].clamp(0, translated.length),
              (sliceAt[i] + po.pending.length).clamp(0, translated.length),
            );
      regionsOf[i] = [
        ...po.ready,
        ...pipeline.regionsFromTranslation(po.pending, slice),
      ];
    }

    // Stage 3 — render + cache each resolved page.
    for (var i = 0; i < pages.length; i++) {
      if (settled[i]) continue;
      var regions = regionsOf[i];
      if (regions == null) continue;
      if (shouldCancel?.call() ?? false) throw const PipelineCanceled();
      var p = pages[i];
      try {
        if (freshOcr[i]) {
          TranslationStore().put(p.cacheKey, regions);
        }
        if (regions.isEmpty) {
          _noContent.add(p.cacheKey);
          success[i] = true; // no translatable text still counts as handled
          continue;
        }
        var rendered = await pipeline.renderPage(p.imageBytes, regions);
        await CacheManager().writeCache(
          p.cacheKey,
          rendered,
          _imageCacheDuration,
        );
        _completed.add(p.cacheKey);
        success[i] = true;
      } catch (e, s) {
        Log.warning('Image Translation', 'Batch render failed: $e\n$s');
        // success[i] stays false
      }
    }
    return success;
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
      var outcome = await _translateToCache(
        task.cacheKey,
        task.comicKey,
        task.imageBytes,
      );
      _errors.remove(task.cacheKey);
      if (outcome != _TranslateOutcome.noContent) {
        _notifyDone(task);
      }
    } on PipelineCanceled {
      // ignore
    } catch (e, s) {
      _failures[task.cacheKey] = DateTime.now();
      _errors[task.cacheKey] = _briefError(e);
      Log.error('Image Translation', 'Failed to translate page: $e', s);
      // Let the reader surface a failure badge instead of silently showing the
      // untranslated page forever.
      notifyListeners();
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

  // ---------------------------------------------------------------------
  // Per-comic glossary
  // ---------------------------------------------------------------------

  /// Agreed name/proper-noun translations per comic ('cid@sourceKey' ->
  /// {source term -> translation}). Sent to the LLM on every page so a
  /// character's name renders identically across pages and chapters, and
  /// grown with the terms the model reports back. Persisted so a later
  /// reading session — or the pre-translation of a different chapter —
  /// inherits the same names.
  static const _comicGlossaryKey = 'imageTranslationComicGlossary';

  /// Cap per comic. The glossary is sent verbatim with every page request, so
  /// an oversized one both wastes tokens and risks overflowing the model's
  /// context. It only holds short proper nouns, so a modest cap is plenty;
  /// once full, the oldest entries are dropped.
  static const _maxGlossaryEntries = 80;
  Map<String, Map<String, String>>? _glossaries;

  Map<String, Map<String, String>> get _allGlossaries {
    if (_glossaries == null) {
      var stored = appdata.implicitData[_comicGlossaryKey];
      _glossaries = <String, Map<String, String>>{};
      var cleaned = false;
      if (stored is Map) {
        stored.forEach((k, v) {
          if (v is! Map) return;
          var glossary = <String, String>{};
          v.forEach((ik, iv) {
            var source = ik.toString();
            var translation = iv.toString();
            // Drop entries an earlier version stored before the term filter
            // existed (whole sentences, URLs, numbers) so they stop being fed
            // back to the model and inflating the prompt.
            if (LlmTranslator.isValidGlossaryTerm(source, translation)) {
              glossary[source] = translation;
            } else {
              cleaned = true;
            }
          });
          if (glossary.length > _maxGlossaryEntries) {
            var keys = glossary.keys.toList();
            for (var key in keys.take(glossary.length - _maxGlossaryEntries)) {
              glossary.remove(key);
            }
            cleaned = true;
          }
          _glossaries![k.toString()] = glossary;
        });
      }
      // Persist the cleaned form once so the cost is paid a single time.
      if (cleaned) {
        appdata.implicitData[_comicGlossaryKey] = _glossaries;
        appdata.writeImplicitData();
      }
    }
    return _glossaries!;
  }

  Map<String, String> _glossaryFor(String comicKey) {
    return _allGlossaries[comicKey] ?? const {};
  }

  /// The learned glossary of a comic ('cid@sourceKey'), as an unmodifiable copy
  /// for the per-comic glossary editor.
  Map<String, String> glossaryOf(String cid, String sourceKey) {
    return Map.unmodifiable(_glossaryFor('$cid@$sourceKey'));
  }

  /// Adds or updates one glossary entry for a comic, correcting or seeding a
  /// name translation by hand. Takes effect on the next page/chapter without a
  /// re-translate. Returns false if the term is rejected (too long / URL /
  /// sentence) or the cap is reached for a new key.
  bool setGlossaryEntry(
    String cid,
    String sourceKey,
    String source,
    String translation,
  ) {
    source = source.trim();
    translation = translation.trim();
    if (!LlmTranslator.isValidGlossaryTerm(source, translation)) {
      return false;
    }
    var comicKey = '$cid@$sourceKey';
    var all = _allGlossaries;
    var glossary = all.putIfAbsent(comicKey, () => <String, String>{});
    if (!glossary.containsKey(source) && glossary.length >= _maxGlossaryEntries) {
      return false;
    }
    glossary[source] = translation;
    // Adding a term by hand means the user wants it, so lift any prior block.
    _allBlockedTerms[comicKey]?.remove(source);
    _persistBlockedTerms();
    appdata.implicitData[_comicGlossaryKey] = all;
    appdata.writeImplicitData();
    notifyListeners();
    return true;
  }

  /// Removes one glossary entry for a comic. When [block] is true the source
  /// term is also added to the comic's block list so it will not be re-learned
  /// on later pages (a plain delete would just reappear next time the model
  /// reports it).
  void removeGlossaryEntry(
    String cid,
    String sourceKey,
    String source, {
    bool block = false,
  }) {
    var comicKey = '$cid@$sourceKey';
    var glossary = _allGlossaries[comicKey];
    var removed = glossary != null && glossary.remove(source) != null;
    if (removed) {
      appdata.implicitData[_comicGlossaryKey] = _allGlossaries;
    }
    if (block) {
      _addBlockedTerm(comicKey, source);
    }
    if (removed || block) {
      appdata.writeImplicitData();
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------
  // Per-comic blocked terms
  // ---------------------------------------------------------------------

  /// Source terms the user banned from a comic's glossary. Kept separate from
  /// the glossary so a deleted-and-blocked name is not silently re-learned the
  /// next time the model reports it.
  static const _blockedTermsKey = 'imageTranslationBlockedTerms';
  Map<String, Set<String>>? _blockedTerms;

  Map<String, Set<String>> get _allBlockedTerms {
    if (_blockedTerms == null) {
      var stored = appdata.implicitData[_blockedTermsKey];
      _blockedTerms = <String, Set<String>>{};
      if (stored is Map) {
        stored.forEach((k, v) {
          if (v is List) {
            _blockedTerms![k.toString()] = v.map((e) => e.toString()).toSet();
          }
        });
      }
    }
    return _blockedTerms!;
  }

  void _addBlockedTerm(String comicKey, String source) {
    if (source.isEmpty) return;
    var set = _allBlockedTerms.putIfAbsent(comicKey, () => <String>{});
    set.add(source);
    _persistBlockedTerms();
  }

  void _persistBlockedTerms() {
    appdata.implicitData[_blockedTermsKey] = _allBlockedTerms.map(
      (k, v) => MapEntry(k, v.toList()),
    );
  }

  /// The blocked source terms of a comic, for the glossary editor.
  List<String> blockedTermsOf(String cid, String sourceKey) {
    return _allBlockedTerms['$cid@$sourceKey']?.toList() ?? const [];
  }

  /// Lifts the block on a term so it can be learned/added again.
  void unblockTerm(String cid, String sourceKey, String source) {
    var comicKey = '$cid@$sourceKey';
    var set = _allBlockedTerms[comicKey];
    if (set == null || !set.remove(source)) return;
    _persistBlockedTerms();
    appdata.writeImplicitData();
    notifyListeners();
  }

  bool _isBlocked(String comicKey, String source) {
    return _allBlockedTerms[comicKey]?.contains(source) ?? false;
  }

  void _mergeGlossary(String comicKey, Map<String, String> discovered) {
    if (discovered.isEmpty) return;
    var all = _allGlossaries;
    var glossary = all.putIfAbsent(comicKey, () => <String, String>{});
    var changed = false;
    discovered.forEach((source, translation) {
      // First agreed translation wins: an established name is not overwritten
      // by a later page's rephrasing, which keeps it stable.
      // Validate here too: the parse-time filter is the primary guard, but a
      // future caller of _mergeGlossary must not be able to insert bloat.
      if (!LlmTranslator.isValidGlossaryTerm(source, translation)) return;
      // Blocked terms must never be re-learned, even if the model keeps
      // reporting them.
      if (_isBlocked(comicKey, source)) return;
      if (!glossary.containsKey(source)) {
        glossary[source] = translation;
        changed = true;
      }
    });
    if (!changed) return;
    while (glossary.length > _maxGlossaryEntries) {
      glossary.remove(glossary.keys.first);
    }
    appdata.implicitData[_comicGlossaryKey] = all;
    appdata.writeImplicitData();
  }

  /// Drops a comic's learned glossary. Called on re-translate so a wrong name
  /// established on an earlier run does not get re-fed to the model and
  /// perpetuated.
  void _clearGlossary(String comicKey) {
    var all = _allGlossaries;
    if (all.remove(comicKey) == null) return;
    appdata.implicitData[_comicGlossaryKey] = all;
    appdata.writeImplicitData();
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

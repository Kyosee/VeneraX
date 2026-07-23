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
  static const _textCacheDuration = 90 * 24 * 60 * 60 * 1000;
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

  static String _textKeyOf(String cacheKey) => 'text:$cacheKey';

  /// Removes both cache levels (rendered image + text result) for every page
  /// under [scopePrefix], so the next view/pre-translate re-runs from scratch.
  /// Also clears the in-memory "done/empty/failed" markers for those keys.
  Future<int> invalidateScope(String scopePrefix) async {
    var removed = await CacheManager().deleteByPrefix(scopePrefix);
    await CacheManager().deleteByPrefix('text:$scopePrefix');
    _completed.removeWhere((k) => k.startsWith(scopePrefix));
    _noContent.removeWhere((k) => k.startsWith(scopePrefix));
    _failures.removeWhere((k, _) => k.startsWith(scopePrefix));
    return removed;
  }

  /// Re-translates a whole comic: drops every cached page (both levels) for
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

  /// Clears every translated page across all comics (both cache levels). The
  /// learned per-comic language locks and glossaries are left intact.
  Future<int> clearAllTranslationCache() async {
    var removed = await CacheManager().deleteByPrefix('pageTranslation@');
    await CacheManager().deleteByPrefix('text:pageTranslation@');
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
    var regions = await _loadTextCache(cacheKey);
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
      // Nothing translatable; the cached empty result keeps this page from
      // being re-analyzed, even across restarts.
      _noContent.add(cacheKey);
      return _TranslateOutcome.noContent;
    }
    var rendered = await pipeline.renderPage(imageBytes, regions);
    await CacheManager().writeCache(cacheKey, rendered, _imageCacheDuration);
    return _TranslateOutcome.translated;
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
    appdata.implicitData[_comicGlossaryKey] = all;
    appdata.writeImplicitData();
    notifyListeners();
    return true;
  }

  /// Removes one glossary entry for a comic.
  void removeGlossaryEntry(String cid, String sourceKey, String source) {
    var comicKey = '$cid@$sourceKey';
    var glossary = _allGlossaries[comicKey];
    if (glossary == null || glossary.remove(source) == null) return;
    appdata.implicitData[_comicGlossaryKey] = _allGlossaries;
    appdata.writeImplicitData();
    notifyListeners();
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

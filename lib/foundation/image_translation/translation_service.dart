import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

class _TranslationTask {
  _TranslationTask(this.cacheKey, this.imageBytes);

  final String cacheKey;
  final Uint8List imageBytes;
  final listeners = <VoidCallback>[];
}

/// Schedules page translations, caches results on disk and notifies the
/// reader when a page is ready so it can swap the displayed image.
///
/// Pages run strictly one at a time — the models are heavy and parallel runs
/// would multiply peak memory, not throughput.
class ImageTranslationService with ChangeNotifier {
  ImageTranslationService._();

  static final instance = ImageTranslationService._();

  static const _cacheDuration = 30 * 24 * 60 * 60 * 1000;
  static const _maxQueueLength = 8;
  static const _failureRetryDelay = Duration(minutes: 5);
  static const _idleReleaseDelay = Duration(seconds: 90);

  final _queue = <_TranslationTask>[];
  final _failures = <String, DateTime>{};
  final _completed = <String>{};
  bool _running = false;
  PageTranslationPipeline? _pipeline;
  Timer? _releaseTimer;

  /// Whether a translated page is known to exist for [cacheKey]. Feeds the
  /// provider identity so a finished background translation produces a new
  /// provider and the visible image swaps in place.
  bool isTranslated(String cacheKey) => _completed.contains(cacheKey);

  void markTranslated(String cacheKey) => _completed.add(cacheKey);

  static String get sourceLang =>
      appdata.settings['imageTranslationSource'] as String? ?? 'ja';

  static String get targetLang =>
      appdata.settings['imageTranslationTarget'] as String? ?? 'zh';

  /// Whether every model required by the current settings is installed.
  static bool get isReady => TranslationModels.isReadyFor(sourceLang);

  /// Whether translation should run for a comic right now (per-comic reader
  /// setting + installed models).
  static bool enabledFor(String cid, String sourceKey) {
    return appdata.settings.getReaderSetting(
              cid,
              sourceKey,
              'enableImageTranslation',
            ) ==
            true &&
        isReady;
  }

  /// Cache key of the translated variant of one page. It embeds the language
  /// pair so changing settings re-translates instead of serving stale pages.
  static String cacheKeyFor(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid,
  ) {
    return 'pageTranslation@$sourceLang>$targetLang@$imageKey@$sourceKey@$cid@$eid';
  }

  Future<File?> findTranslated(String cacheKey) {
    return CacheManager().findCache(cacheKey);
  }

  /// Queues a page for translation. [onTranslated] fires (once per caller)
  /// after the translated page is cached, right before listeners are
  /// notified — providers use it to evict their stale image cache entry.
  void schedule(
    String cacheKey,
    Uint8List imageBytes,
    VoidCallback onTranslated,
  ) {
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
      // so the oldest queued page is the one furthest behind.
      _queue.removeAt(_running ? 1 : 0);
    }
    _queue.add(_TranslationTask(cacheKey, imageBytes)..listeners.add(onTranslated));
    _releaseTimer?.cancel();
    unawaited(_drain());
  }

  Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        var task = _queue.first;
        try {
          // The settings may have changed while queued; skip stale entries.
          var expectedPrefix = 'pageTranslation@$sourceLang>$targetLang@';
          if (!task.cacheKey.startsWith(expectedPrefix)) {
            continue;
          }
          if (await CacheManager().findCache(task.cacheKey) != null) {
            _notifyDone(task);
            continue;
          }
          var pipeline = _pipeline ??= PageTranslationPipeline();
          var rendered = await pipeline.translatePage(
            task.imageBytes,
            sourceLang: sourceLang,
            targetLang: targetLang,
          );
          if (rendered == null) {
            // No translatable text: remember so the page is not re-analyzed
            // on every view, but nothing to swap in.
            _failures[task.cacheKey] = DateTime.now();
            continue;
          }
          await CacheManager().writeCache(
            task.cacheKey,
            rendered,
            _cacheDuration,
          );
          _notifyDone(task);
        } on PipelineCanceled {
          // ignore
        } catch (e, s) {
          _failures[task.cacheKey] = DateTime.now();
          Log.error('Image Translation', 'Failed to translate page: $e', s);
        } finally {
          _queue.remove(task);
        }
      }
    } finally {
      _running = false;
      _scheduleRelease();
    }
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
      if (_running || _queue.isNotEmpty) return;
      var pipeline = _pipeline;
      _pipeline = null;
      unawaited(pipeline?.release());
    });
  }

  /// Drops queued-but-not-started work (e.g. when leaving the reader).
  void clearQueue() {
    if (_queue.isEmpty) return;
    _queue.removeRange(_running ? 1 : 0, _queue.length);
    _scheduleRelease();
  }

  /// Evicts a provider's stale image-cache entry so the next resolve loads
  /// the translated page.
  static void evictImage(ImageProvider provider) {
    scheduleMicrotask(() {
      PaintingBinding.instance.imageCache.evict(provider);
    });
  }
}

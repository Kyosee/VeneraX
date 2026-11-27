import 'dart:async' show Future, StreamController, scheduleMicrotask;
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/file_type.dart';
import 'avif_fallback.dart';
import 'comic_image_codec.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static const int maxImagePixel = 2560 * 1440;

  static TargetImageSize _getTargetSize(int width, int height) {
    // ignore invalid size
    if (width <= 0 || height <= 0) {
      return TargetImageSize(width: width, height: height);
    }
    // ignore too wide or too tall image
    final imageRatio = width / height;
    if (imageRatio > 2 || imageRatio < 0.5) {
      return TargetImageSize(width: width, height: height);
    }
    // resize if too large
    if (width * height > maxImagePixel) {
      final ratio = sqrt(maxImagePixel / (width * height));
      return TargetImageSize(width: (width * ratio).round(), height: (height * ratio).round());
    }
    return TargetImageSize(width: width, height: height);
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadBufferAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      int retryTime = 1;

      bool stop = false;

      chunkEvents.onCancel = () {
        stop = true;
      };

      Uint8List? data;

      while (data == null && !stop) {
        try {
          data = await load(chunkEvents, () {
            if (stop) {
              throw const _ImageLoadingStopException();
            }
          });
        } on _ImageLoadingStopException {
          rethrow;
        } on ImageLoadingPermanentException {
          // Retrying cannot help; report it now instead of sitting out the backoff.
          rethrow;
        } catch (e) {
          if (e.toString().contains("Invalid Status Code: 404")) {
            rethrow;
          }
          if (e.toString().contains("Invalid Status Code: 403")) {
            rethrow;
          }
          // Local file errors (e.g. the comic's image pack has not been
          // downloaded yet) are not transient; retrying is pointless and would
          // keep the image in a perpetual loading state while spamming logs.
          // Rethrow immediately so the cache entry is evicted and the load can
          // self-heal once the files appear.
          if (e.toString().contains("Comic not found") ||
              e.toString().contains("Cover not found")) {
            rethrow;
          }
          if (e.toString().contains("handshake")) {
            if (retryTime < 5) {
              retryTime = 5;
            }
          }
          retryTime <<= 1;
          if (retryTime > (1 << 3) || stop) {
            rethrow;
          }
          await Future.delayed(Duration(seconds: retryTime));
        }
      }

      if (stop) {
        throw const _ImageLoadingStopException();
      }

      if (data!.isEmpty) {
        // Zero bytes are as unusable as undecodable ones and equally sticky:
        // a truncated write stays cached and every later load replays it.
        await evictCorruptedCache();
        throw Exception("Empty image data: ${this.key}");
      }

      try {
        final codec = await decodeComicImage(
          data,
          decode: decode,
          getTargetSize: enableResize ? _getTargetSize : null,
        );
        // The framework can still encounter a bad frame after the codec opens.
        return _GuardedCodec(codec, _onFrameDecodeFailed);
      } catch (e) {
        if (isAvifImage(data)) {
          await _onFrameDecodeFailed(e);
        } else {
          await evictCorruptedCache();
        }
        if (data.length < 2 * 1024) {
          // data is too short, it's likely that the data is text, not image
          try {
            var text =
                const Utf8Codec(allowMalformed: false).decoder.convert(data);
            throw Exception("Expected image data, but got text: $text");
          } catch (e) {
            // ignore
          }
        }
        rethrow;
      }
    } on _ImageLoadingStopException {
      rethrow;
    } catch (e, s) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      Log.error("Image Loading", e, s);
      rethrow;
    } finally {
      chunkEvents.close();
    }
  }

  /// Handles a pixel-decode failure raised after [loadImage] already returned.
  ///
  /// Nothing can rescue the frame being decoded — the framework has already
  /// reported it. What this does is stop the failure repeating: the cached bytes
  /// go away, and a URL with a known alternative encoding is recorded so the
  /// next load asks for that instead.
  Future<void> _onFrameDecodeFailed(Object error) async {
    Log.error("Image Loading", "Frame decode failed for $key: $error");
    // A local file has no server-side alternative to ask for, and rewriting its
    // path would only point at a file that does not exist.
    final url = fallbackUrl;
    if (url != null && !url.startsWith('file://')) {
      AvifFallbackRegistry.instance.markFailed(url);
    }
    try {
      await evictCorruptedCache();
    } catch (e) {
      // Eviction is best-effort: a provider may key a sidecar copy off fields
      // this load never resolved. Losing it must not swallow the decode error.
      Log.error("Image Loading", "Cache eviction failed for $key: $e");
    }
    scheduleMicrotask(() {
      PaintingBinding.instance.imageCache.evict(this);
    });
  }

  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  );

  String get key;

  /// The request URL behind this image, when it is one whose encoding the server
  /// also publishes in another format. Providers that load from the network
  /// override this; a null result just means no redirect is possible.
  String? get fallbackUrl => null;

  /// Key of the on-disk [CacheManager] entry, when it differs from [key].
  ///
  /// [key] is this provider's identity in Flutter's in-memory image cache and
  /// must not be repurposed: several providers build it from fields that never
  /// reach the disk cache key. Override this wherever the two diverge, or a
  /// corrupted entry can never be evicted.
  String get diskCacheKey => key;

  /// Drop every cached copy that could have produced undecodable bytes, so the
  /// next load re-fetches instead of replaying the same failure forever.
  ///
  /// A provider with its own sidecar cache must override this: that copy is
  /// read before [CacheManager] and would keep serving the bad bytes.
  Future<void> evictCorruptedCache() => CacheManager().delete(diskCacheKey);

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }

  bool get enableResize => false;
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);

/// Forwards to a real codec, reporting a frame-decode failure before rethrowing.
///
/// [MultiFrameImageStreamCompleter] calls [getNextFrame] itself and routes any
/// error to [FlutterError], so this is the only place a provider can still learn
/// that the bytes it supplied were undecodable.
class _GuardedCodec implements ui.Codec {
  _GuardedCodec(this._inner, this._onError);

  final ui.Codec _inner;
  final Future<void> Function(Object error) _onError;
  bool _reported = false;

  @override
  int get frameCount => _inner.frameCount;

  @override
  int get repetitionCount => _inner.repetitionCount;

  @override
  Future<FrameInfo> getNextFrame() async {
    try {
      return await _inner.getNextFrame();
    } catch (e) {
      // An animated image decodes many frames; report only the first failure so
      // one broken file cannot flood the log or the eviction path.
      if (!_reported) {
        _reported = true;
        // Not awaited: the framework disposes this codec as soon as the error
        // surfaces, so holding the rethrow for disk work would report the
        // failure late and leave the reader on a spinner until it finished.
        // The URL is recorded before the first await inside the handler, so the
        // redirect is in place even though the eviction completes later.
        _onError(e);
      }
      rethrow;
    }
  }

  @override
  void dispose() => _inner.dispose();
}

class _ImageLoadingStopException implements Exception {
  const _ImageLoadingStopException();
}

/// Thrown by [BaseImageProvider.load] when retrying cannot help — a broken file
/// rather than a transient failure.
class ImageLoadingPermanentException implements Exception {
  const ImageLoadingPermanentException(this.message);

  final String message;

  @override
  String toString() => message;
}

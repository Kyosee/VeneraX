import 'dart:typed_data';

/// Raw RGBA bitmap that can cross isolate boundaries.
class RgbaImage {
  RgbaImage(this.width, this.height, this.pixels);

  final int width;
  final int height;
  final Uint8List pixels;
}

/// Integer rectangle (isolate-friendly, no dart:ui types).
class IntRect {
  IntRect(this.left, this.top, this.right, this.bottom);

  int left, top, right, bottom;

  int get width => right - left;
  int get height => bottom - top;
  int get area => width * height;

  bool intersects(IntRect other) {
    return left < other.right &&
        other.left < right &&
        top < other.bottom &&
        other.top < bottom;
  }

  IntRect inflated(int dx, int dy, int maxW, int maxH) {
    return IntRect(
      (left - dx).clamp(0, maxW),
      (top - dy).clamp(0, maxH),
      (right + dx).clamp(0, maxW),
      (bottom + dy).clamp(0, maxH),
    );
  }
}

/// One recognized text block, produced by the worker isolate.
class OcrBlock {
  OcrBlock({
    required this.rect,
    required this.text,
    required this.language,
    required this.backgroundColor,
    required this.textColor,
  });

  final IntRect rect;

  /// Recognized source text.
  final String text;

  /// Detected source language ('ja', 'zh', 'ko', 'en').
  final String language;

  final int backgroundColor;
  final int textColor;
}

/// A translated text block ready for rendering.
class TranslatedRegion {
  TranslatedRegion({
    required this.rect,
    required this.text,
    required this.backgroundColor,
    required this.textColor,
  });

  final IntRect rect;
  final String text;
  final int backgroundColor;
  final int textColor;

  /// Compact JSON for the text-level result cache: lets a page be re-rendered
  /// after the rendered image was evicted, without re-running OCR or paying
  /// for another translation request.
  Map<String, dynamic> toJson() => {
    'l': rect.left,
    't': rect.top,
    'r': rect.right,
    'b': rect.bottom,
    'text': text,
    'bg': backgroundColor,
    'fg': textColor,
  };

  factory TranslatedRegion.fromJson(Map<String, dynamic> json) {
    return TranslatedRegion(
      rect: IntRect(json['l'], json['t'], json['r'], json['b']),
      text: json['text'],
      backgroundColor: json['bg'],
      textColor: json['fg'],
    );
  }
}

class PipelineCanceled implements Exception {
  const PipelineCanceled();
}

/// How the original lettering is removed before the translation is drawn.
///
/// The mode is part of the rendered-image cache key (a one-char token), so
/// switching it re-renders from the already-stored text result without
/// re-running OCR or the LLM, and switching back serves the earlier render.
enum InpaintMode {
  /// Legacy: cover each region with an opaque rounded patch in the sampled
  /// background colour. Fast and universal, but a big bubble becomes a big
  /// solid block and a textured/translucent bubble gets a pasted-on look.
  patch('p'),

  /// Pure-Dart erase: estimate the text strokes inside each region and fill
  /// only those pixels from the surrounding non-text pixels, keeping the
  /// bubble shape, screentone and gradients. A backing plate is added only
  /// where the placed translation would be hard to read. Default.
  smart('s'),

  /// AI erase: an ONNX inpainting model reconstructs the region. Best on busy
  /// backgrounds; needs a model download and more compute. Falls back to
  /// [smart] when the model is not installed.
  ai('a');

  const InpaintMode(this.token);

  /// One-character tag appended to the rendered-image cache key.
  final String token;

  static InpaintMode fromSettings(Object? value) {
    return switch (value) {
      'patch' => InpaintMode.patch,
      'ai' => InpaintMode.ai,
      _ => InpaintMode.smart,
    };
  }
}

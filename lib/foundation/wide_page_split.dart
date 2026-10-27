import 'dart:ui' show Size;

/// How the vertical continuous reader cuts a landscape page (usually a
/// two-page spread) into two halves stacked top to bottom, so each half is
/// laid out at the full column width instead of the whole spread shrinking
/// to it. Stored as the `splitWidePages` reader setting.
enum WidePageSplit {
  off,

  /// Right half on top: the order of right-to-left comics.
  rightFirst,

  /// Left half on top.
  leftFirst;

  static WidePageSplit fromSetting(Object? value) => switch (value) {
    'rightFirst' => rightFirst,
    'leftFirst' => leftFirst,
    _ => off,
  };

  /// Whether a page of [imageSize] is cut. Only landscape pages are; a square
  /// or portrait page is a single page however it was scanned.
  bool appliesTo(Size imageSize) =>
      this != off && imageSize.width > imageSize.height;

  /// The aspect ratio the page takes in the column: two halves stacked.
  Size layoutSize(Size imageSize) => appliesTo(imageSize)
      ? Size(imageSize.width / 2, imageSize.height * 2)
      : imageSize;
}

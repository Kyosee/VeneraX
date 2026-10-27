/// How a chapter's images are grouped into screens when the gallery reader
/// shows several per screen. Image indices are 0-based, screens 1-based.
///
/// Images go [imagesPerScreen] to a screen in order, except that a landscape
/// image (usually a spread) never shares one: it gets a screen to itself and
/// grouping starts over after it. [singleFirst] keeps the first image alone,
/// like a cover.
class GalleryLayout {
  GalleryLayout({
    required this.imageCount,
    required this.imagesPerScreen,
    this.singleFirst = false,
    Set<int> wide = const {},
    Set<int> breaks = const {},
  }) : _starts = _group(imageCount, imagesPerScreen, singleFirst, wide, breaks);

  final int imageCount;

  final int imagesPerScreen;

  final bool singleFirst;

  /// First image of each screen.
  final List<int> _starts;

  /// A screen also starts at each image in [breaks].
  static List<int> _group(
    int count,
    int perScreen,
    bool singleFirst,
    Set<int> wide,
    Set<int> breaks,
  ) {
    final starts = <int>[];
    var filled = 0;
    for (var i = 0; i < count; i++) {
      if (i == 0 ||
          filled >= perScreen ||
          wide.contains(i) ||
          wide.contains(i - 1) ||
          breaks.contains(i) ||
          (singleFirst && i == 1)) {
        starts.add(i);
        filled = 0;
      }
      filled++;
    }
    return starts;
  }

  int get screenCount => _starts.length;

  /// The [start, end) images on [screen]; empty past either end.
  (int, int) imagesOf(int screen) {
    if (screen < 1) return (0, 0);
    if (screen > _starts.length) return (imageCount, imageCount);
    final end = screen < _starts.length ? _starts[screen] : imageCount;
    return (_starts[screen - 1], end);
  }

  /// The screen showing image [index].
  int screenOf(int index) {
    var low = 0;
    var high = _starts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_starts[mid] <= index) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }

  /// The grouping with the landscape images in [wide], keeping [screen]
  /// where it is: it starts at the same image and holds the same ones, unless
  /// one of them is landscape and has to stand alone. Screens around it
  /// regroup. Used when landscape images turn up while reading, so that what
  /// is on screen does not change under the reader.
  GalleryLayout regroupedAround(int screen, Set<int> wide) {
    final inRange = screen >= 1 && screen <= screenCount;
    final (start, end) = imagesOf(screen);
    return GalleryLayout(
      imageCount: imageCount,
      imagesPerScreen: imagesPerScreen,
      singleFirst: singleFirst,
      wide: wide,
      breaks: inRange ? {start, end} : const {},
    );
  }

  bool sameScreensAs(GalleryLayout other) {
    if (imageCount != other.imageCount ||
        _starts.length != other._starts.length) {
      return false;
    }
    for (var i = 0; i < _starts.length; i++) {
      if (_starts[i] != other._starts[i]) return false;
    }
    return true;
  }
}

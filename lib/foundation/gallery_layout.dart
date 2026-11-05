/// How a chapter's images are grouped into screens when the gallery reader
/// shows several per screen. Image indices are 0-based, screens 1-based.
///
/// Images go [imagesPerScreen] to a screen in order, except that a landscape
/// image (usually a spread) never shares one: it gets a screen to itself and
/// grouping starts over after it. [singleFirst] keeps the first image alone,
/// like a cover. With [splitWide] and one image per screen, a landscape image
/// is cut in two and each half gets a screen.
class GalleryLayout {
  GalleryLayout({
    required int imageCount,
    required int imagesPerScreen,
    bool singleFirst = false,
    bool splitWide = false,
    Set<int> wide = const {},
    Set<int> breaks = const {},
  }) : this._(
         imageCount,
         imagesPerScreen,
         singleFirst,
         splitWide && imagesPerScreen == 1,
         wide,
         breaks,
       );

  GalleryLayout._(
    this.imageCount,
    this.imagesPerScreen,
    this.singleFirst,
    this.splitWide,
    Set<int> wide,
    Set<int> breaks,
  ) : _starts = _group(
        imageCount,
        imagesPerScreen,
        singleFirst,
        splitWide,
        wide,
        breaks,
      );

  final int imageCount;

  final int imagesPerScreen;

  final bool singleFirst;

  /// Whether landscape images are cut in two. Only ever true with one image
  /// per screen: a landscape image already has a screen to itself otherwise.
  final bool splitWide;

  /// First image of each screen. A cut image starts two screens in a row.
  final List<int> _starts;

  /// A screen also starts at each image in [breaks].
  static List<int> _group(
    int count,
    int perScreen,
    bool singleFirst,
    bool splitWide,
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
      if (splitWide && wide.contains(i)) starts.add(i);
      filled++;
    }
    return starts;
  }

  int get screenCount => _starts.length;

  /// The [start, end) images on [screen]; empty past either end. Both
  /// screens of a cut image hold that one image.
  (int, int) imagesOf(int screen) {
    if (screen < 1) return (0, 0);
    if (screen > _starts.length) return (imageCount, imageCount);
    final start = _starts[screen - 1];
    if (halfOf(screen) != null) return (start, start + 1);
    final end = screen < _starts.length ? _starts[screen] : imageCount;
    return (start, end);
  }

  /// Which half of a cut image [screen] shows; null when it is not cut.
  GalleryHalf? halfOf(int screen) {
    if (screen < 1 || screen > _starts.length) return null;
    final start = _starts[screen - 1];
    if (screen < _starts.length && _starts[screen] == start) {
      return GalleryHalf.first;
    }
    if (screen > 1 && _starts[screen - 2] == start) return GalleryHalf.second;
    return null;
  }

  /// The screen showing image [index]; for a cut image, the screen with
  /// [half] of it.
  int screenOf(int index, [GalleryHalf half = GalleryHalf.first]) {
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
    // The search ends on the later of a cut image's two screens.
    if (half == GalleryHalf.first &&
        low > 0 &&
        _starts[low - 1] == _starts[low]) {
      low--;
    }
    return low + 1;
  }

  /// The screen here showing what [screen] of [other] shows: the same first
  /// image, and the same half when the image is cut in both. An image cut
  /// here only opens on its later half when the reader got to it [backward],
  /// so that turning back does not skip a half.
  int screenMatching(
    GalleryLayout other,
    int screen, {
    bool backward = false,
  }) => screenOf(
    other.imagesOf(screen).$1,
    other.halfOf(screen) ?? (backward ? GalleryHalf.second : GalleryHalf.first),
  );

  /// The grouping with the landscape images in [wide], keeping [screen]
  /// where it is: it starts at the same image and holds the same ones, unless
  /// one of them is landscape and has to stand alone or be cut. Screens
  /// around it regroup. Used when landscape images turn up while reading, so
  /// that what is on screen does not change under the reader.
  GalleryLayout regroupedAround(int screen, Set<int> wide) {
    final inRange = screen >= 1 && screen <= screenCount;
    final (start, end) = imagesOf(screen);
    return GalleryLayout(
      imageCount: imageCount,
      imagesPerScreen: imagesPerScreen,
      singleFirst: singleFirst,
      splitWide: splitWide,
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

/// The two screens of a landscape image cut in two, in reading order.
enum GalleryHalf { first, second }

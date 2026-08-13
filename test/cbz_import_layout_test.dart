import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/cbz.dart';

// Issue #198: a cbz produced elsewhere imported as "0 comics" ("No images found
// in the archive"). The import only looked at root-level files and matched
// extensions case-sensitively, so upper-case extensions and chapter
// subdirectories both read as "no pages". These cover the pure decisions;
// the copy path needs real files and is verified on device.

void main() {
  group('isImageName', () {
    test('accepts upper-case and mixed-case extensions', () {
      expect(CBZ.isImageName('001.JPG'), isTrue);
      expect(CBZ.isImageName('001.JpEg'), isTrue);
      expect(CBZ.isImageName('001.PNG'), isTrue);
      expect(CBZ.isImageName('001.WebP'), isTrue);
    });

    test('accepts bmp and avif', () {
      expect(CBZ.isImageName('a.bmp'), isTrue);
      expect(CBZ.isImageName('a.avif'), isTrue);
    });

    test('rejects non-images and extension-less names', () {
      expect(CBZ.isImageName('metadata.json'), isFalse);
      expect(CBZ.isImageName('ComicInfo.xml'), isFalse);
      expect(CBZ.isImageName('thumbs.db'), isFalse);
      expect(CBZ.isImageName('README'), isFalse);
    });
  });

  group('naturalCompare', () {
    test('orders unpadded numbers by value', () {
      var names = ['10.jpg', '2.jpg', '1.jpg', '21.jpg']..sort(
        CBZ.naturalCompare,
      );
      expect(names, ['1.jpg', '2.jpg', '10.jpg', '21.jpg']);
    });

    test('orders names with numeric suffixes', () {
      var names = ['page10.png', 'page9.png', 'page1.png']..sort(
        CBZ.naturalCompare,
      );
      expect(names, ['page1.png', 'page9.png', 'page10.png']);
    });

    test('ignores case for the text runs', () {
      expect(CBZ.naturalCompare('IMG2.jpg', 'img10.jpg'), lessThan(0));
    });
  });

  group('rangesFit', () {
    ComicChapter c(String t, int s, int e) =>
        ComicChapter(title: t, start: s, end: e);

    test('accepts ranges covering the page list', () {
      expect(CBZ.rangesFit([c('a', 1, 3), c('b', 4, 6)], 6), isTrue);
    });

    test('rejects a range past the last page', () {
      // Slicing by this metadata would throw instead of importing.
      expect(CBZ.rangesFit([c('a', 1, 3), c('b', 4, 9)], 6), isFalse);
    });

    test('rejects zero/negative start and inverted range', () {
      expect(CBZ.rangesFit([c('a', 0, 3)], 6), isFalse);
      expect(CBZ.rangesFit([c('a', 4, 2)], 6), isFalse);
    });
  });
}

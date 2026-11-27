import 'dart:async';

import 'package:flutter/painting.dart' show ImageChunkEvent;
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_cover_store.dart';
import 'package:venera/foundation/image_provider/local_comic_image.dart';
import 'package:venera/network/images.dart';
import 'package:venera/network/webdav_library.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/local_comic_scanner.dart';

import 'fixtures/avif_page.dart';

void main() {
  test('AVIF downloads are accepted and keep their original file type', () {
    final bytes = avifPageBytes();
    expect(isValidDownloadedImage(bytes), isTrue);
    expect(detectFileType(bytes).ext, '.avif');
    expect(detectFileType(bytes).mime, 'image/avif');
  });

  test('recognizes an AVIF compatible brand inside the file-type box', () {
    List<int> fileTypeBox(String brand, List<String> compatibleBrands) => [
      ...List.filled(3, 0),
      16 + 4 * compatibleBrands.length,
      ...'ftyp'.codeUnits,
      ...brand.codeUnits,
      ...List.filled(4, 0),
      for (final item in compatibleBrands) ...item.codeUnits,
    ];

    final compatible = fileTypeBox('mif1', ['mif1', 'miaf', 'avif']);
    expect(detectFileType(compatible).ext, '.avif');
    expect(detectFileType(fileTypeBox('avis', ['msf1'])).ext, '.avif');
    final extended = [
      ...[0, 0, 0, 1],
      ...'ftyp'.codeUnits,
      ...List.filled(7, 0),
      compatible.length + 8,
      ...compatible.skip(8),
    ];
    expect(detectFileType(extended).ext, '.avif');
    expect(detectFileType(compatible.sublist(0, 25)).ext, isNot('.avif'));
    final other = fileTypeBox('isom', ['mif1']);
    expect(detectFileType([...other, ...'avif'.codeUnits]).ext, isNot('.avif'));
    other.setRange(12, 16, 'avif'.codeUnits);
    expect(detectFileType(other).ext, isNot('.avif'));
  });

  test(
    'reads an AVIF-only local folder and accepts its cover and page names',
    () async {
      final root = await Directory.systemTemp.createTemp('venera_avif_input_');
      addTearDown(() => root.delete(recursive: true));
      final image = avifPageBytes();
      final page = File(FilePath.join(root.path, '001.AVIF'));
      await page.writeAsBytes(image);
      final comic = await scanLocalComicDirectory(root, rejectExisting: false);
      expect(comic?.cover, '001.AVIF');
      final provider = LocalComicImageProvider(comic!);
      final events = StreamController<ImageChunkEvent>.broadcast();
      addTearDown(events.close);
      expect(await provider.load(events, () {}), image);
      final chapter = await Directory(
        FilePath.join(root.path, 'chapter'),
      ).create();
      await page.rename(FilePath.join(chapter.path, '001.Avif'));
      expect(await provider.load(events, () {}), image);
      final rescanned = await scanLocalComicDirectory(root, previous: comic);
      expect(rescanned?.cover, FilePath.join('chapter', '001.Avif'));

      expect(CBZ.isImageName('001.AVIF'), isTrue);
      expect(WebdavLibrary.isImage('001.AVIF'), isTrue);
      expect(ComicCoverStore.imageExtensions, contains('avif'));
      expect(ComicCoverStore.nameOf('collection://cover.AVIF'), 'cover.AVIF');
      expect(ComicCoverStore.nameOf('collection://../cover.AVIF'), isNull);
    },
  );
}

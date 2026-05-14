import 'package:zip_flutter/zip_flutter.dart';

Future<void> compressFolderAsync(String src, String dst) {
  return ZipFile.compressFolderAsync(src, dst);
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:venera/foundation/feature_flags.dart';
import 'package:zip_flutter/zip_flutter.dart';

Future<void> compressFolderAsync(String src, String dst) {
  return ZipFile.compressFolderAsync(src, dst);
}

/// Extracts the zip at [src] into [dest], entry by entry.
///
/// Deliberately avoids `ZipFile.openAndExtract`: that helper registers its
/// argument pointer with a GC finalizer AND frees it manually, so whenever a
/// GC runs in the calling isolate the finalizer frees the pointer a second
/// time and libmalloc aborts the whole process ("pointer being freed was not
/// allocated"). The per-entry API used here has no such double-free pairing.
///
/// Entries whose normalized path would land outside [dest] (zip-slip) abort
/// the extraction.
void extractZip(String src, String dest) {
  // Kill switch. Extraction is a native call, and a defect on that side is
  // beyond any Dart patch: the double-free this function was written to avoid
  // aborted in libmalloc, taking the process down from whichever unrelated code
  // happened to touch the corrupted heap next. Refusing here degrades import,
  // archive download and WebDAV image bundles to a visible failure, which beats
  // a crash whose stack points at something innocent.
  if (!featureEnabled(KillIds.archiveExtract)) {
    throw StateError(
      'Archive extraction is unavailable: '
      '${featureDisabledReason(KillIds.archiveExtract) ?? "disabled remotely"}',
    );
  }
  final zip = ZipFile.openRead(src);
  try {
    final root = p.normalize(Directory(dest).absolute.path);
    final total = zip.entriesCount;
    for (var i = 0; i < total; i++) {
      final entry = zip.getEntryByIndex(i);
      if (entry.name.isEmpty) continue;
      final target = p.normalize(p.join(root, entry.name));
      if (!p.isWithin(root, target)) {
        throw Exception('Invalid archive: entry escapes target directory');
      }
      if (entry.isDir) {
        Directory(target).createSync(recursive: true);
      } else {
        entry.writeToFile(target);
      }
    }
  } finally {
    zip.close();
  }
}

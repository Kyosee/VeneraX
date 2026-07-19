// One-off generator: builds multi-resolution .ico files from the launcher-icon
// PNG presets so the Windows runtime can swap the live window/taskbar/tray icon
// (issue #134). Run from the repo root: `dart run tool/gen_launcher_icos.dart`.
//
// The .exe's embedded icon is fixed at build time and stays app_icon.ico; these
// generated .ico files only feed WM_SETICON / the tray at runtime.
//
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:image/image.dart';

void main() {
  // preset PNG -> output .ico. `default` already ships as assets/app_icon.ico,
  // so it is intentionally absent here.
  const jobs = {
    'assets/venera_original.png': 'assets/venera_original.ico',
    'assets/user_logo.png': 'assets/user_logo.ico',
    'assets/new_logo2.png': 'assets/new_logo2.ico',
    'assets/new_logo3.png': 'assets/new_logo3.ico',
  };

  // Sizes Windows picks between for title bar (16), taskbar button (32) and
  // higher-DPI / Alt-Tab surfaces.
  const sizes = [16, 32, 48, 64, 128, 256];

  jobs.forEach((src, dst) {
    final decoded = decodePng(File(src).readAsBytesSync());
    if (decoded == null) {
      stderr.writeln('skip $src: not a PNG');
      return;
    }
    // encodeIco emits every frame of the image as a directory entry, so pack
    // all sizes into one Image.
    final image = copyResize(decoded,
        width: sizes.first,
        height: sizes.first,
        interpolation: Interpolation.average);
    for (final s in sizes.skip(1)) {
      image.addFrame(copyResize(decoded,
          width: s, height: s, interpolation: Interpolation.average));
    }
    File(dst).writeAsBytesSync(encodeIco(image));
    stdout.writeln('wrote $dst (${sizes.length} sizes)');
  });
}

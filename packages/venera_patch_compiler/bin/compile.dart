// Compiles patch sources to a VIR payload.
//
//   dart run venera_patch_compiler:compile \
//     --surface build/patch/surface.json \
//     --out build/patch/bundle.vpatch \
//     lib/my_fix.dart
//
// This program never ships in the app. It reads the surface manifest emitted by
// `tool/patch_tool.dart surface` for the build being targeted, so every call a
// patch makes is checked against what that binary can actually reach. A patch
// naming an unbound member fails here, with a file and line, instead of on a
// user's device.

import 'dart:convert';
import 'dart:io';

import 'package:venera_patch_compiler/venera_patch_compiler.dart';

Future<void> main(List<String> args) async {
  final flags = <String, String>{};
  final sources = <String>[];
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a.startsWith('--')) {
      final name = a.substring(2);
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        flags[name] = args[++i];
      } else {
        flags[name] = 'true';
      }
    } else {
      sources.add(a);
    }
  }

  final surfacePath = flags['surface'];
  if (surfacePath == null || sources.isEmpty) {
    stderr.writeln('''
usage: compile --surface <surface.json> [--out <bundle.vpatch>] <source.dart>...

  --surface   Surface manifest for the target build, from
              `dart tool/patch_tool.dart surface`. Required: without it there is
              nothing to check calls against, and an unbound call would only
              surface on a device.
  --out       Where to write the payload. Defaults to stdout, so the output can
              be piped or inspected before it is signed.
''');
    exit(64);
  }

  final surfaceFile = File(surfacePath);
  if (!surfaceFile.existsSync()) {
    stderr.writeln('error: surface manifest not found: $surfacePath');
    exit(1);
  }

  try {
    final surface = SurfaceManifest.parse(surfaceFile.readAsStringSync());
    final payload = await PatchCompiler(surface).compileFiles(sources);
    final json = const JsonEncoder.withIndent('  ').convert(payload);

    final out = flags['out'];
    if (out == null) {
      stdout.writeln(json);
    } else {
      File(out).parent.createSync(recursive: true);
      File(out).writeAsStringSync(json);
      final overrides = (payload['overrides'] as Map?) ?? const {};
      final functions = (payload['functions'] as List?) ?? const [];
      stdout.writeln('payload -> $out');
      stdout.writeln('  targets app         ${surface.appVersion}');
      stdout.writeln('  functions           ${functions.length}');
      stdout.writeln('  overrides           ${overrides.length} '
          '(seam ids ${overrides.keys.join(", ")})');
      stdout.writeln('  bytes               ${json.length}');
    }
  } on PatchCompileError catch (e) {
    // The message is the product here: it names the file, the line, and what to
    // do instead. A patch author hits these far more often than a runtime fault.
    stderr.writeln('compile failed:\n${e.message}');
    exit(1);
  } on SurfaceError catch (e) {
    stderr.writeln('surface error:\n${e.message}');
    exit(1);
  }
}

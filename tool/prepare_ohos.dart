import 'dart:convert';
import 'dart:io';

// Adapt only build-local copies of the locked dependencies. Never edit Pub's
// shared cache: other platforms and concurrent checkouts use the same files.
void main() {
  final root = File.fromUri(Platform.script).parent.parent;
  final configFile = File('${root.path}/.dart_tool/package_config.json');
  final config = jsonDecode(configFile.readAsStringSync()) as Map;
  final generated = Directory('${root.path}/.dart_tool/ohos')
    ..createSync(recursive: true);
  final nativeRoots = <String, String>{};
  final patches = <String, (String, String, String)>{
    'flutter_qjs': (
      'lib/src/ffi.dart',
      'if (Platform.isAndroid) {',
      "if (Platform.isAndroid || Platform.operatingSystem == 'ohos') {",
    ),
    for (final entry in {
      'flutter_7zip': 'lib/flutter_7zip.dart',
      'lodepng_flutter': 'lib/lodepng_flutter.dart',
      'zip_flutter': 'lib/src/zip_dart_base.dart',
    }.entries)
      entry.key: (
        entry.value,
        'if (Platform.isAndroid || Platform.isLinux) {',
        "if (Platform.isAndroid || Platform.isLinux || Platform.operatingSystem == 'ohos') {",
      ),
  };
  for (final package in config['packages'] as List) {
    final name = package['name'] as String;
    final source = Directory.fromUri(
      configFile.uri.resolve(package['rootUri'] as String),
    ).absolute.uri;
    if (source.toString().startsWith(generated.absolute.uri.toString())) {
      throw StateError(
        'Run flutter pub get --enforce-lockfile before preparing OHOS again.',
      );
    }
    // Config root URIs must remain absolute when used by native build tools.
    package['rootUri'] = source.toString();
    if (patches.containsKey(name) || name == 'rhttp') {
      nativeRoots[name] = Directory.fromUri(source).path.replaceAll('\\', '/');
    }
    final patch = patches[name];
    if (patch == null) continue;
    final destination = Directory('${generated.path}/packages/$name');
    for (final file in Directory.fromUri(
      source.resolve('lib/'),
    ).listSync(recursive: true, followLinks: false).whereType<File>()) {
      final relative = file.uri.path.substring(source.path.length);
      final output = File('${destination.path}/$relative');
      output.parent.createSync(recursive: true);
      file.copySync(output.path);
    }
    for (final name in ['pubspec.yaml', 'LICENSE']) {
      final file = File.fromUri(source.resolve(name));
      if (file.existsSync()) file.copySync('${destination.path}/$name');
    }
    final file = File('${destination.path}/${patch.$1}');
    final contents = file.readAsStringSync();
    if (patch.$2.allMatches(contents).length != 1) {
      throw StateError('Cannot apply the OHOS loader patch to $name.');
    }
    file.writeAsStringSync(contents.replaceFirst(patch.$2, patch.$3));
    package['rootUri'] = destination.absolute.uri.toString();
  }
  if (nativeRoots.length != patches.length + 1) {
    throw StateError('Resolve the locked dependencies before preparing OHOS.');
  }
  File('${generated.path}/native_deps.cmake').writeAsStringSync(
    nativeRoots.entries
        .map((e) => 'set(${e.key.toUpperCase()}_SOURCE [==[${e.value}]==])')
        .join('\n'),
  );
  configFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(config),
  );
  stdout.writeln('Prepared OHOS loaders and native sources from pubspec.lock.');
}

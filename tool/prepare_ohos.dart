import 'dart:convert';
import 'dart:io';

import 'package:yaml/yaml.dart';

import 'prepare_ohos_icons.dart';

const _webviewCommit = '389cf40dbb647f1df7272de5ea6b3401efe27a75';

String _git(Directory directory, List<String> arguments) {
  final result = Process.runSync('git', ['-C', directory.path, ...arguments]);
  if (result.exitCode != 0) {
    throw StateError('Git ${arguments.first} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

void _copyLibrary(Uri source, Directory destination) {
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
}

void _prepareWebview(
  Directory root,
  Directory generated,
  Map config,
  String? sourcePath,
) {
  const name = 'flutter_inappwebview_ohos';
  final upstream = Directory(
    sourcePath ?? '${generated.path}/sources/inappwebview',
  );
  if (!upstream.existsSync()) {
    if (sourcePath != null) throw StateError('WebView source does not exist.');
    upstream.createSync(recursive: true);
    _git(upstream, ['init']);
  }
  final head = Process.runSync('git', [
    '-C',
    upstream.path,
    'rev-parse',
    'HEAD',
  ]);
  if (head.exitCode != 0 && sourcePath == null) {
    _git(upstream, [
      'fetch',
      '--depth',
      '1',
      'https://gitcode.com/CPF-Flutter/flutter_inappwebview.git',
      _webviewCommit,
    ]);
    _git(upstream, ['checkout', '--detach', _webviewCommit]);
  }
  if (_git(upstream, ['rev-parse', 'HEAD']).trim() != _webviewCommit) {
    throw StateError('WebView requires official commit $_webviewCommit.');
  }
  _git(upstream, ['diff', '--quiet', 'HEAD', '--', name, 'LICENSE']);
  final destination = Directory('${generated.path}/packages/$name');
  // Remove stale generated source so a previous patch cannot survive preparation.
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  for (final path in _git(upstream, [
    'ls-files',
    '-z',
    '--',
    name,
  ]).split('\x00')) {
    if (path.isEmpty) continue;
    final relative = path.substring(name.length + 1);
    if (!(relative.startsWith('lib/') ||
        relative.startsWith('ohos/') ||
        relative == 'pubspec.yaml')) {
      continue;
    }
    final output = File('${destination.path}/$relative');
    output.parent.createSync(recursive: true);
    File('${upstream.path}/$path').copySync(output.path);
  }
  File('${upstream.path}/LICENSE').copySync('${destination.path}/LICENSE');
  for (final patch in [
    'inappwebview.patch',
    'inappwebview_security.patch',
    'inappwebview_security_test.patch',
  ]) {
    _git(root, [
      'apply',
      '--whitespace=error',
      '--directory=.dart_tool/ohos/packages/$name',
      '${root.path}/tool/ohos/$patch',
    ]);
  }
  // JSON is valid YAML and avoids altering either shared Pub cache or lockfile.
  final manifest = File('${destination.path}/pubspec.yaml');
  final pubspec =
      jsonDecode(jsonEncode(loadYaml(manifest.readAsStringSync()))) as Map;
  pubspec['dependencies']['flutter_inappwebview_platform_interface'] =
      '1.4.0-beta.3';
  pubspec['flutter']['plugin']['implements'] = 'flutter_inappwebview';
  manifest.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(pubspec),
  );
  (config['packages'] as List).add({
    'name': name,
    'rootUri': destination.absolute.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.4',
  });

  final appPackage =
      (config['packages'] as List).singleWhere(
            (package) => package['name'] == 'flutter_inappwebview',
          )
          as Map;
  final wrapper = Directory('${generated.path}/packages/flutter_inappwebview');
  _copyLibrary(Uri.parse(appPackage['rootUri'] as String), wrapper);
  final wrapperManifest = File('${wrapper.path}/pubspec.yaml');
  final wrapperSpec =
      jsonDecode(jsonEncode(loadYaml(wrapperManifest.readAsStringSync())))
          as Map;
  wrapperSpec['dependencies'][name] = '1.1.3';
  wrapperSpec['flutter']['plugin']['platforms']['ohos'] = {
    'default_package': name,
  };
  wrapperManifest.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(wrapperSpec),
  );
  appPackage['rootUri'] = wrapper.absolute.uri.toString();

  // Flutter 3.44 discovers plugins via package_graph, not package_config alone.
  final graphFile = File('${root.path}/.dart_tool/package_graph.json');
  final graph = jsonDecode(graphFile.readAsStringSync()) as Map;
  final packages = graph['packages'] as List;
  final wrapperGraph =
      packages.singleWhere(
            (package) => package['name'] == 'flutter_inappwebview',
          )
          as Map;
  (wrapperGraph['dependencies'] as List).add(name);
  packages.add({
    'name': name,
    'version': '1.1.3',
    'dependencies': ['flutter', 'flutter_inappwebview_platform_interface'],
    'devDependencies': <String>[],
  });
  graphFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(graph),
  );
}

// Adapt only build-local copies of the locked dependencies. Never edit Pub's
// shared cache: other platforms and concurrent checkouts use the same files.
void main(List<String> args) {
  if (args.length > 1) {
    throw ArgumentError('Expected an optional WebView source directory.');
  }
  final root = File.fromUri(Platform.script).parent.parent;
  prepareOhosIcons(root);
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
    _copyLibrary(source, destination);
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
  _prepareWebview(root, generated, config, args.firstOrNull);
  File(
    '${root.path}/tool/ohos/refresh_plugins.dart.template',
  ).copySync('${generated.path}/refresh_plugins.dart');
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

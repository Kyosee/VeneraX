import 'dart:io';

import 'windows_updater_ui.dart';

/// Renders the production window with sample data; never installs an update.
Future<void> main(List<String> args) async {
  String? option(String name) {
    final index = args.indexOf(name);
    return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
  }

  final output = option('--output');
  final errors = <String>[];
  final window = WindowsUpdaterWindow(
    restart: true,
    iconPath: File('assets/new_logo.png').absolute.path,
    themeColors: option('--theme-colors'),
    onError: (error) {
      errors.add(error);
      stderr.writeln(error);
    },
  );
  try {
    await window.show(locale: option('--locale'));
    window.update(
      UpdateStage.installing,
      completed: 157,
      total: 240,
      unit: 'files',
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (output != null) {
      await Directory(output).create(recursive: true);
      await window.capture('$output/installing.png');
      window.update(
        UpdateStage.downloading,
        completed: 50751078,
        total: 83886080,
        unit: 'bytes',
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await window.capture('$output/downloading.png');
      window.update(UpdateStage.extracting);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await window.capture('$output/extracting.png');
      window.update(UpdateStage.complete);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await window.capture('$output/complete.png');
    } else {
      await Future<void>.delayed(const Duration(seconds: 10));
    }
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
  } finally {
    await window.close();
  }
}

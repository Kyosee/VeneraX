import 'dart:convert';
import 'dart:io';

import 'package:flex_seed_scheme/flex_seed_scheme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/windows_updater_strings.dart';
import '../tool/windows_updater_ui.dart';

void main() {
  test('all updater languages cover stages and use VeneraX branding', () {
    expect(
      windowsUpdaterStrings.keys,
      unorderedEquals(['en', 'zh-Hans', 'zh-Hant']),
    );
    for (final strings in windowsUpdaterStrings.values) {
      expect(strings.keys, unorderedEquals(windowsUpdaterStrings['en']!.keys));
      for (final stage in UpdateStage.values) {
        expect(strings[stage.name], isNotEmpty);
      }
      for (final key in [
        'windowTitle',
        'title',
        'waiting',
        'restarting',
        'restartHint',
      ]) {
        expect(strings[key], contains('VeneraX'));
      }
      expect(
        strings.values.any((text) => RegExp(r'Venera(?!X)').hasMatch(text)),
        isFalse,
      );
    }
  });

  test(
    'theme input accepts colors and rejects malformed or executable values',
    () {
      expect(decodeUpdaterColors(null), isEmpty);
      expect(decodeUpdaterColors('broken input'), isEmpty);
      expect(decodeUpdaterColors(base64Url.encode(utf8.encode('[]'))), isEmpty);
      final input = base64Url.encode(
        utf8.encode(
          jsonEncode({
            'primary': '#FF123456',
            'surface': '#ffabcdef',
            'error': r'$(Write-Output injected)',
            'onSurface': 42,
            'unexpected': '#FFFFFFFF',
          }),
        ),
      );
      expect(decodeUpdaterColors(input), {
        'primary': '#FF123456',
        'surface': '#ffabcdef',
      });
    },
  );

  test(
    'native window follows locale, app colors and real progress without blocking',
    () async {
      final output = Directory('build/windows-updater-preview');
      await output.create(recursive: true);
      for (final (locale, language, seed, brightness) in [
        ('zh-CN', 'zh-Hans', Colors.blue, Brightness.light),
        ('zh-HK', 'zh-Hant', Colors.green, Brightness.dark),
        ('en-US', 'en', Colors.purple, Brightness.light),
        ('fr-FR', 'en', Colors.orange, Brightness.dark),
      ]) {
        final colors = SeedColorScheme.fromSeeds(
          primaryKey: seed,
          brightness: brightness,
          tones: FlexTones.vividBackground(brightness),
        );
        final palette =
            {
              'primary': colors.primary,
              'onPrimary': colors.onPrimary,
              'primaryContainer': colors.primaryContainer,
              'onPrimaryContainer': colors.onPrimaryContainer,
              'surface': colors.surface,
              'surfaceContainerLow': colors.surfaceContainerLow,
              'onSurface': colors.onSurface,
              'onSurfaceVariant': colors.onSurfaceVariant,
              'outlineVariant': colors.outlineVariant,
              'error': colors.error,
            }.map(
              (key, color) => MapEntry(
                key,
                '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
              ),
            );
        final errors = <String>[];
        final window = WindowsUpdaterWindow(
          restart: true,
          iconPath: File('assets/new_logo.png').absolute.path,
          themeColors: base64Url.encode(utf8.encode(jsonEncode(palette))),
          onError: errors.add,
        );
        Future<Map<String, dynamic>> snapshot(String name) async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          return window.capture('${output.path}/$locale-$name.png');
        }

        try {
          await window.show(locale: locale);
          window.update(
            UpdateStage.installing,
            completed: 157,
            total: 240,
            unit: 'files',
          );
          var state = await snapshot('installing');
          expect(state['title'], windowsUpdaterStrings[language]!['title']);
          expect(
            state['windowTitle'],
            windowsUpdaterStrings[language]!['windowTitle'],
          );
          expect(state['percent'], '65%');
          expect(state['detail'], contains('157 / 240'));
          expect(state['primary'], palette['primary']);
          expect(state['surface'], palette['surface']);
          expect(state['indeterminate'], isFalse);
          expect(state['closeEnabled'], isFalse);

          window.update(
            UpdateStage.downloading,
            completed: 41943040,
            total: -1,
            unit: 'bytes',
          );
          state = await snapshot('unknown-length');
          expect(state['percent'], '—');
          expect(state['indeterminate'], isTrue);
          expect(state['detail'], contains('40'));

          window.update(UpdateStage.extracting);
          state = await snapshot('extracting');
          expect(
            state['status'],
            windowsUpdaterStrings[language]!['extracting'],
          );
          expect(state['indeterminate'], isTrue);

          window.update(UpdateStage.complete);
          state = await snapshot('complete');
          expect(state['percent'], '100%');
          expect(state['closeEnabled'], isTrue);
          window.update(UpdateStage.failed);
          state = await snapshot('failed');
          expect(state['title'], windowsUpdaterStrings[language]!['failed']);
          expect(state['closeEnabled'], isTrue);
          expect(state['primary'], palette['error']);
          expect(errors, isEmpty);
        } finally {
          await window.close();
        }
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'local and downloaded packages install safely in a temporary app',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        "venerax updater's test ",
      );
      final payload = Directory('${fixture.path}/payload/data');
      await payload.create(recursive: true);
      await File('${payload.parent.path}/venera.exe').writeAsString('new app');
      await File('${payload.path}/asset.txt').writeAsString('new nested asset');
      final zip = File('${fixture.path}/update.zip');
      String quote(String value) => "'${value.replaceAll("'", "''")}'";
      HttpServer? server;
      try {
        final compressed = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          'Compress-Archive -LiteralPath ${quote(payload.parent.path)} -DestinationPath ${quote(zip.path)}',
        ]);
        expect(compressed.exitCode, 0, reason: '${compressed.stderr}');
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final package = await zip.readAsBytes();
        server.listen((request) async {
          // Leave the length unknown to exercise streamed downloads.
          request.response.add(package);
          await request.response.close();
        });
        for (final local in [true, false]) {
          final app = Directory(
            '${fixture.path}/${local ? 'local' : 'downloaded'}',
          );
          await app.create();
          await File('${app.path}/venera.exe').writeAsString('old app');
          await File('${app.path}/obsolete.txt').writeAsString('old asset');
          await File(
            '${app.path}/unins000.dat',
          ).writeAsString('keep uninstaller');
          final result = await Process.run('dart', [
            'tool/windows_updater.dart',
            '--app-dir',
            '${app.path}${local ? '' : Platform.pathSeparator}',
            if (local) ...[
              '--package-file',
              zip.path,
            ] else ...[
              '--package-url',
              'http://127.0.0.1:${server.port}/update.zip',
            ],
            '--from-temp',
          ], runInShell: true).timeout(const Duration(seconds: 40));
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(
            await File('${app.path}/venera.exe').readAsString(),
            'new app',
          );
          expect(
            await File('${app.path}/data/asset.txt').readAsString(),
            'new nested asset',
          );
          expect(
            await File('${app.path}/unins000.dat').readAsString(),
            'keep uninstaller',
          );
          expect(File('${app.path}/obsolete.txt').existsSync(), isFalse);
          expect(
            '${result.stdout}${result.stderr}',
            isNot(contains('Cannot show progress window')),
          );
        }
      } finally {
        await server?.close(force: true);
        await fixture.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

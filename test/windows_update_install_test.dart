import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../tool/windows_update_install.dart';

void main() {
  late Directory root, installed, payload;
  setUp(() {
    root = Directory.systemTemp.createTempSync('venera-transaction-');
    installed = Directory('${root.path}/app')..createSync();
    payload = Directory('${root.path}/payload')..createSync();
    File('${installed.path}/venera.exe').writeAsStringSync('old executable');
    File('${installed.path}/obsolete.dll').writeAsStringSync('old library');
    File('${installed.path}/unins000.dat').writeAsStringSync('uninstaller');
    File('${payload.path}/venera.exe').writeAsStringSync('new executable');
    Directory('${payload.path}/data').createSync();
    File('${payload.path}/data/app.so').writeAsStringSync('new code');
  });
  tearDown(() => root.deleteSync(recursive: true));
  void expectOld() {
    expect(
      File('${installed.path}/venera.exe').readAsStringSync(),
      'old executable',
    );
    expect(
      File('${installed.path}/obsolete.dll').readAsStringSync(),
      'old library',
    );
    expect(
      File('${installed.path}/unins000.dat').readAsStringSync(),
      'uninstaller',
    );
  }

  test(
    'switches the complete directory and preserves the uninstaller',
    () async {
      await replaceWindowsInstallation(installed: installed, payload: payload);
      expect(
        File('${installed.path}/venera.exe').readAsStringSync(),
        'new executable',
      );
      expect(
        File('${installed.path}/data/app.so').readAsStringSync(),
        'new code',
      );
      expect(File('${installed.path}/obsolete.dll').existsSync(), isFalse);
      expect(
        File('${installed.path}/unins000.dat').readAsStringSync(),
        'uninstaller',
      );
      expect(root.listSync().length, 2);
    },
  );
  test('activation failure restores the original directory', () async {
    await expectLater(
      replaceWindowsInstallation(
        installed: installed,
        payload: payload,
        beforeActivate: () =>
            throw const FileSystemException('Injected activation failure'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expectOld();
    expect(root.listSync().length, 2);
  });
  test('failure preparing the replacement leaves original untouched', () async {
    await expectLater(
      replaceWindowsInstallation(
        installed: installed,
        payload: Directory('${root.path}/missing'),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expectOld();
    expect(root.listSync().length, 2);
  });
  test('failed restore retains the only original copy for recovery', () async {
    final logs = <String>[];
    await expectLater(
      replaceWindowsInstallation(
        installed: installed,
        payload: payload,
        beforeActivate: () {
          installed.createSync();
          File('${installed.path}/obstruction').writeAsStringSync('occupied');
          throw const FileSystemException('Injected activation failure');
        },
        log: logs.add,
      ),
      throwsA(isA<FileSystemException>()),
    );
    final retained = root.listSync().whereType<Directory>().singleWhere(
      (entry) => entry.path.contains('.venera-update-'),
    );
    expect(
      File('${retained.path}/previous/venera.exe').readAsStringSync(),
      'old executable',
    );
    expect(
      File('${retained.path}/previous/obsolete.dll').readAsStringSync(),
      'old library',
    );
    expect(logs.single, contains('original app retained'));
  });
  test(
    'briefly held files are waited out instead of failing the update',
    () async {
      // Scanners hold files for moments; any open handle blocks a folder move.
      final handle = File('${installed.path}/obsolete.dll').openSync();
      final release = Timer(
        const Duration(milliseconds: 600),
        handle.closeSync,
      );
      try {
        await replaceWindowsInstallation(
          installed: installed,
          payload: payload,
        );
      } finally {
        release.cancel();
        try {
          handle.closeSync();
        } on FileSystemException {
          // Already released by the timer.
        }
      }
      expect(
        File('${installed.path}/venera.exe').readAsStringSync(),
        'new executable',
      );
      expect(File('${installed.path}/obsolete.dll').existsSync(), isFalse);
      expect(root.listSync().length, 2);
    },
    skip: !Platform.isWindows,
  );
  test(
    'locked original file never causes a partially removed app',
    () async {
      final lock = File('${installed.path}/obsolete.dll');
      final path = lock.path.replaceAll("'", "''");
      // A hidden PowerShell ignores redirected stdin, so release via a file.
      final release = File('${root.path}/release-lock');
      final releasePath = release.path.replaceAll("'", "''");
      final process = await Process.start('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        "\$f = [IO.File]::Open('$path', 'Open', 'Read', 'None'); [Console]::WriteLine('ready'); while (-not (Test-Path -LiteralPath '$releasePath')) { Start-Sleep -Milliseconds 50 }; \$f.Dispose()",
      ]);
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .firstWhere((line) => line == 'ready')
            .timeout(const Duration(seconds: 15));
        await expectLater(
          replaceWindowsInstallation(installed: installed, payload: payload),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        release.writeAsStringSync('');
        await process.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            process.kill();
            return -1;
          },
        );
        expect(await errors, isEmpty);
      }
      expectOld();
    },
    skip: !Platform.isWindows,
  );
}

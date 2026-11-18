import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:venera/foundation/update_delta.dart';
import 'package:venera/foundation/update_manifest.dart';

void main() {
  late Directory root, source, work;
  late File patch;
  String hash(List<int> bytes) => sha256.convert(bytes).toString();
  final app = utf8.encode('new executable');
  final aot = utf8.encode('retained AOT');
  final fixtures =
      jsonDecode(
            File('test/fixtures/update_delta/bsdiff4.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final fixture =
      (fixtures['cases'] as List<dynamic>).firstWhere(
            (item) => item['name'] == 'move_repeat',
          )
          as Map<String, dynamic>;
  final oldFixture = base64Decode(fixture['old'] as String);
  final newFixture = base64Decode(fixture['new'] as String);
  final patchFixture = base64Decode(fixture['patch'] as String);
  setUp(() {
    root = Directory.systemTemp.createTempSync('update-delta-test-');
    source = Directory('${root.path}/app')..createSync();
    Directory('${source.path}/data').createSync();
    File('${source.path}/data/app.so').writeAsBytesSync(aot);
    File('${source.path}/removed.dll').writeAsStringSync('old');
    work = Directory('${root.path}/work')..createSync();
    patch = File('${work.path}/update.patch');
  });
  tearDown(() => root.deleteSync(recursive: true));
  Map<String, Object?> file(String path, String mode, List<int> bytes) => {
    'path': path,
    'mode': mode,
    'size': bytes.length,
    'sha256': hash(bytes),
    if (mode == 'copy') 'oldSha256': hash(bytes),
    if (mode == 'full') 'payload': 'payload/0',
  };
  UpdateDelta make({
    List<Map<String, Object?>>? files,
    Map<String, List<int>>? extras,
    String? patchHash,
    String from = '1.0.0',
    String to = '1.0.1',
    List<int>? payloadBytes,
    int metadataPadding = 0,
    void Function(Uint8List)? editZip,
  }) {
    final metadata = utf8.encode(
      jsonEncode({
        'schema': 1,
        'fromVersion': from,
        'toVersion': to,
        if (metadataPadding > 0) 'padding': 'X' * metadataPadding,
        'files':
            files ??
            [file('venera.exe', 'full', app), file('data/app.so', 'copy', aot)],
      }),
    );
    final payload = payloadBytes ?? app;
    final archive = Archive()
      ..addFile(ArchiveFile('delta.json', metadata.length, metadata))
      ..addFile(ArchiveFile('payload/0', payload.length, payload));
    for (final entry in (extras ?? <String, List<int>>{}).entries) {
      archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
    }
    final zip = Uint8List.fromList(ZipEncoder().encode(archive));
    editZip?.call(zip);
    patch.writeAsBytesSync(zip);
    return UpdateDelta(
      platform: 'windows',
      architecture: 'x64',
      fromVersion: '1.0.0',
      toVersion: '1.0.1',
      fullAsset: 'VeneraX-1.0.1-windows.zip',
      patchAsset: 'update.patch',
      patchSize: patch.lengthSync(),
      patchSha256: patchHash ?? hash(patch.readAsBytesSync()),
      fullSha256: '0' * 64,
    );
  }

  Future<File> prepare(UpdateDelta delta, [CancelToken? token]) =>
      prepareDeltaUpdate(
        delta: delta,
        sourcePath: source.path,
        patch: patch,
        workDirectory: work,
        fullSize: 1000,
        cancelToken: token ?? CancelToken(),
      );

  Map<String, List<int>> installedFiles() => {
    for (final entry in source.listSync(recursive: true).whereType<File>())
      p.relative(entry.path, from: source.path): entry.readAsBytesSync(),
  };

  UpdateDelta androidDelta({
    List<int>? bytes,
    String? oldDigest,
    String? newDigest,
  }) {
    patch.writeAsBytesSync(bytes ?? patchFixture);
    return UpdateDelta(
      platform: 'android',
      architecture: 'arm64-v8a',
      fromVersion: '1.0.0',
      toVersion: '1.0.1',
      fullAsset: 'VeneraX-1.0.1-arm64-v8a.apk',
      patchAsset: 'update.patch',
      patchSize: patch.lengthSync(),
      patchSha256: hash(patch.readAsBytesSync()),
      oldSha256: oldDigest ?? hash(oldFixture),
      fullSha256: newDigest ?? hash(newFixture),
    );
  }

  Future<File> prepareAndroid(
    UpdateDelta delta,
    File installed, {
    int? size,
    CancelToken? token,
  }) => prepareDeltaUpdate(
    delta: delta,
    sourcePath: installed.path,
    patch: patch,
    workDirectory: work,
    fullSize: size ?? newFixture.length,
    cancelToken: token ?? CancelToken(),
  );

  test(
    'Windows reconstructs a complete new package and preserves installed files',
    () async {
      final output = await prepare(make());
      final archive = ZipDecoder().decodeBytes(output.readAsBytesSync());
      expect(archive.files.map((f) => f.name).toSet(), {
        'venera.exe',
        'data/app.so',
      });
      expect(archive.findFile('venera.exe')!.content, app);
      expect(archive.findFile('data/app.so')!.content, aot);
      expect(File('${source.path}/removed.dll').readAsStringSync(), 'old');
      expect(File('${source.path}/data/app.so').readAsBytesSync(), aot);
      expect(Directory('${work.path}/payload').existsSync(), isFalse);
    },
  );
  test('wrong patch digest is rejected before reading archive', () async {
    await expectLater(
      prepare(make(patchHash: '0' * 64)),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'Android reconstructs an independently generated BSDIFF40 fixture',
    () async {
      final installed = File('${source.path}/base.apk')
        ..writeAsBytesSync(oldFixture);
      final before = installedFiles();
      final output = await prepareAndroid(androidDelta(), installed);
      expect(output.readAsBytesSync(), newFixture);
      expect(installedFiles(), before);
      expect(patch.readAsBytesSync(), patchFixture);
      expect(work.listSync().whereType<Directory>(), isEmpty);
    },
  );

  for (final failedDigest in ['old', 'final']) {
    test(
      'Android rejects wrong $failedDigest digest without changing installed files',
      () async {
        final installed = File('${source.path}/base.apk')
          ..writeAsBytesSync(oldFixture);
        final before = installedFiles();
        final delta = androidDelta(
          oldDigest: failedDigest == 'old' ? '0' * 64 : null,
          newDigest: failedDigest == 'final' ? '0' * 64 : null,
        );
        await expectLater(
          prepareAndroid(delta, installed),
          throwsA(isA<FormatException>()),
        );
        expect(installedFiles(), before);
        expect(patch.readAsBytesSync(), patchFixture);
        expect(work.listSync().whereType<Directory>(), isEmpty);
        if (failedDigest == 'old') {
          expect(File('${work.path}/${delta.fullAsset}').existsSync(), isFalse);
        }
      },
    );
  }

  test(
    'Android cancellation after output creation never reports success',
    () async {
      final large =
          jsonDecode(
                File(
                  'test/fixtures/update_delta/large-output.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final installed = File('${source.path}/base.apk')..writeAsBytesSync([]);
      final before = installedFiles();
      final delta = androidDelta(
        bytes: base64Decode(large['patch'] as String),
        oldDigest: hash([]),
        newDigest: large['sha256'] as String,
      );
      final token = CancelToken();
      final created = Completer<void>();
      final watcher = work.watch(events: FileSystemEvent.create).listen((
        event,
      ) {
        if (p.basename(event.path) == delta.fullAsset) {
          token.cancel('cancel after reconstruction started');
          if (!created.isCompleted) created.complete();
        }
      });
      try {
        await expectLater(
          prepareAndroid(
            delta,
            installed,
            size: large['size'] as int,
            token: token,
          ),
          throwsA(anyOf(isA<DioException>(), isA<FileSystemException>())),
        );
        expect(created.isCompleted, isTrue);
        expect(token.isCancelled, isTrue);
        expect(installedFiles(), before);
        expect(work.listSync().whereType<Directory>(), isEmpty);
        expect(File('${work.path}/cancel').existsSync(), isFalse);
      } finally {
        await watcher.cancel();
      }
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Windows applies real BSDIFF40 to an executable while copying AOT',
    () async {
      File('${source.path}/venera.exe').writeAsBytesSync(oldFixture);
      final before = installedFiles();
      final entry = file('venera.exe', 'bsdiff', newFixture)
        ..['oldSha256'] = hash(oldFixture)
        ..['payload'] = 'payload/0';
      final output = await prepare(
        make(
          files: [entry, file('data/app.so', 'copy', aot)],
          payloadBytes: patchFixture,
        ),
      );
      final archive = ZipDecoder().decodeBytes(output.readAsBytesSync());
      expect(archive.findFile('venera.exe')!.content, newFixture);
      expect(archive.findFile('data/app.so')!.content, aot);
      expect(installedFiles(), before);
      expect(File('${work.path}/block').existsSync(), isFalse);
      expect(Directory('${work.path}/payload').existsSync(), isFalse);
    },
  );

  test(
    'Windows rejects the wrong BSDIFF40 output digest without modifying the app',
    () async {
      File('${source.path}/venera.exe').writeAsBytesSync(oldFixture);
      final before = installedFiles();
      final entry = file('venera.exe', 'bsdiff', newFixture)
        ..['oldSha256'] = hash(oldFixture)
        ..['sha256'] = '0' * 64
        ..['payload'] = 'payload/0';
      await expectLater(
        prepare(
          make(
            files: [entry, file('data/app.so', 'copy', aot)],
            payloadBytes: patchFixture,
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(installedFiles(), before);
      expect(File('${work.path}/block').existsSync(), isFalse);
      expect(Directory('${work.path}/payload').existsSync(), isFalse);
    },
  );

  test(
    'Windows rejects duplicate ZIP entry names before extracting payloads',
    () async {
      final before = installedFiles();
      final delta = make(
        extras: {
          'payload/1': [1],
        },
        editZip: (bytes) =>
            _editZipEntry(bytes, 'payload/1', (view, central, local) {
              final name = ascii.encode('payload/0');
              bytes.setRange(central + 46, central + 46 + name.length, name);
              bytes.setRange(local + 30, local + 30 + name.length, name);
            }),
      );
      await expectLater(prepare(delta), throwsA(isA<FormatException>()));
      expect(installedFiles(), before);
      expect(File('${work.path}/delta.json').existsSync(), isFalse);
      expect(Directory('${work.path}/payload').existsSync(), isFalse);
    },
  );

  test(
    'Windows rejects ZIP symbolic links before reading their contents',
    () async {
      final before = installedFiles();
      final delta = make(
        editZip: (bytes) {
          _editZipEntry(bytes, 'delta.json', (view, central, local) {
            view.setUint16(central + 4, (3 << 8) | 20, Endian.little);
            view.setUint32(central + 38, 0xa1ff << 16, Endian.little);
          });
        },
      );
      await expectLater(prepare(delta), throwsA(isA<FormatException>()));
      expect(installedFiles(), before);
      expect(File('${work.path}/delta.json').existsSync(), isFalse);
      expect(Directory('${work.path}/payload').existsSync(), isFalse);
    },
  );

  for (final name in ['delta.json', 'payload/0']) {
    test(
      'Windows bounds real decompression when $name claims a smaller size',
      () async {
        final before = installedFiles();
        final largePayload = List<int>.filled(4096, 88);
        final delta = make(
          metadataPadding: 4096,
          payloadBytes: largePayload,
          files: [
            file('venera.exe', 'full', largePayload),
            file('data/app.so', 'copy', aot),
          ],
          editZip: (bytes) =>
              _editZipEntry(bytes, name, (view, central, local) {
                view.setUint32(central + 24, 1, Endian.little);
                view.setUint32(local + 22, 1, Endian.little);
              }),
        );
        await expectLater(prepare(delta), throwsA(isA<FormatException>()));
        expect(installedFiles(), before);
        expect(Directory('${work.path}/payload').existsSync(), isFalse);
        final bounded = File(
          '${work.path}/${name == 'delta.json' ? 'delta.json' : 'block'}',
        );
        if (bounded.existsSync()) {
          expect(bounded.lengthSync(), lessThanOrEqualTo(1));
        }
      },
    );
  }
  test('modified installed file is rejected and never overwritten', () async {
    final delta = make();
    File('${source.path}/data/app.so').writeAsStringSync('modified');
    await expectLater(prepare(delta), throwsA(isA<FormatException>()));
    expect(File('${source.path}/data/app.so').readAsStringSync(), 'modified');
  });
  test(
    'disk write failure leaves installed files intact and permits retry',
    () async {
      final delta = make();
      final before = installedFiles();
      final obstacle = File('${work.path}/payload')
        ..writeAsStringSync('occupied');
      await expectLater(prepare(delta), throwsA(isA<FileSystemException>()));
      expect(installedFiles(), before);
      expect(File('${work.path}/${delta.fullAsset}').existsSync(), isFalse);
      obstacle.deleteSync();
      expect(await prepare(delta), isA<File>());
      expect(installedFiles(), before);
    },
  );
  test('missing installed file is rejected', () async {
    final delta = make();
    File('${source.path}/data/app.so').deleteSync();
    await expectLater(prepare(delta), throwsA(isA<FileSystemException>()));
  });
  test('different release metadata is rejected', () async {
    await expectLater(
      prepare(make(from: '0.9.0')),
      throwsA(isA<FormatException>()),
    );
  });
  test('cancellation probes are throttled yet still observed', () async {
    var probes = 0;
    var cancelled = false;
    final check = throttledCancellation(() {
      probes++;
      return cancelled;
    }, interval: const Duration(milliseconds: 50));
    // One stat per control tuple took 45 s on Windows for 240k tuples.
    for (var i = 0; i < 200000; i++) {
      check();
    }
    expect(probes, inInclusiveRange(1, 10));
    cancelled = true;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(check, throwsA(isA<FileSystemException>()));
    expect(
      throttledCancellation(() => true),
      throwsA(isA<FileSystemException>()),
      reason: 'the first call probes immediately',
    );
  });
  test('pre-cancelled update performs no reconstruction', () async {
    final delta = make();
    await expectLater(
      prepare(delta, CancelToken()..cancel()),
      throwsA(isA<DioException>()),
    );
    expect(File('${work.path}/${delta.fullAsset}').existsSync(), isFalse);
  });
  for (final path in [
    '../escape',
    '/absolute',
    'C:/escape',
    'data\\app.so',
    'data/../app.so',
    'data/app.so.',
    'CON.txt',
    'data/app.so:stream',
  ]) {
    test('rejects unsafe target $path', () async {
      await expectLater(
        prepare(make(files: [file(path, 'full', app)])),
        throwsA(isA<FormatException>()),
      );
    });
  }
  test('rejects case insensitive duplicate targets', () async {
    await expectLater(
      prepare(
        make(
          files: [
            file('venera.exe', 'full', app),
            file('VENERA.EXE', 'copy', aot),
          ],
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });
  test('rejects uninstaller and unexpected payloads', () async {
    await expectLater(
      prepare(make(files: [file('unins000.exe', 'full', app)])),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      prepare(
        make(
          extras: {
            'extra': [1],
          },
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });
  test('rejects a full payload whose declared contents differ', () async {
    final entry = file('venera.exe', 'full', app)..['sha256'] = '0' * 64;
    await expectLater(
      prepare(make(files: [entry])),
      throwsA(isA<FormatException>()),
    );
  });
  test('rejects output size exceeding the supported limit', () async {
    final entry = file('venera.exe', 'full', app)
      ..['size'] = 1024 * 1024 * 1024;
    await expectLater(
      prepare(make(files: [entry])),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'manifest requires exact target, channel, hashes and safe filenames',
    () {
      final entry = {
        'format': 'bsdiff40-v1',
        'platform': 'android',
        'architecture': 'arm64-v8a',
        'fromVersion': '1.0.0',
        'toVersion': '1.0.1',
        'fullAsset': 'VeneraX-1.0.1-arm64-v8a.apk',
        'patchAsset': 'update.patch',
        'patchSize': 100,
        'patchSha256': '1' * 64,
        'oldSha256': '2' * 64,
        'fullSha256': '3' * 64,
      };
      Object manifest(Map<String, Object> value) => {
        'schema': 1,
        'version': '1.0.1',
        'deltas': [value],
      };
      expect(UpdateDelta.parse(manifest(entry), '1.0.1'), hasLength(1));
      expect(UpdateDelta.parse(manifest(entry), '1.0.2'), isEmpty);
      for (final change in <String, Object>{
        'fromVersion': '1.0.0-beta.1',
        'oldSha256': '',
        'patchSize': -1,
        'patchAsset': '../update.patch',
        'format': 'unknown',
        'platform': 'ohos',
      }.entries) {
        expect(
          UpdateDelta.parse(
            manifest({...entry, change.key: change.value}),
            '1.0.1',
          ),
          isEmpty,
        );
      }
      for (final platform in ['android', 'windows']) {
        final platformEntry = <String, Object>{
          ...entry,
          'platform': platform,
          'architecture': platform == 'android' ? 'arm64-v8a' : 'x64',
          'fullAsset': platform == 'android'
              ? 'VeneraX-1.0.1-arm64-v8a.apk'
              : 'VeneraX-1.0.1-windows.zip',
        };
        expect(
          UpdateDelta.parse(manifest(platformEntry), '1.0.1'),
          hasLength(1),
        );
        for (final invalidDigest in <Object>[
          42,
          <String>[],
          <String, Object>{},
        ]) {
          late List<UpdateDelta> parsed;
          expect(
            () => parsed = UpdateDelta.parse(
              manifest({...platformEntry, 'oldSha256': invalidDigest}),
              '1.0.1',
            ),
            returnsNormally,
          );
          expect(parsed, isEmpty);
        }
      }
    },
  );

  test('Android asset selection follows the device ABI preference order', () {
    const names = [
      'VeneraX-1.0.1.apk',
      'VeneraX-1.0.1-armeabi-v7a.apk',
      'VeneraX-1.0.1-x86_64.apk',
      'VeneraX-1.0.1-arm64-v8a.apk',
    ];
    expect(
      selectAndroidUpdateAssetName(names, ['arm64-v8a', 'armeabi-v7a']),
      'VeneraX-1.0.1-arm64-v8a.apk',
    );
    expect(
      selectAndroidUpdateAssetName(names, ['armeabi-v7a', 'arm64-v8a']),
      'VeneraX-1.0.1-armeabi-v7a.apk',
    );
    expect(
      selectAndroidUpdateAssetName(names, ['riscv64', 'x86_64']),
      'VeneraX-1.0.1-x86_64.apk',
    );
  });

  test(
    'delta selection binds version, architecture, asset digest and savings',
    () {
      final delta = androidDelta();
      bool matches({
        String version = '1.0.0',
        String platform = 'android',
        String arch = 'arm64-v8a',
        String? name,
        String? digest,
        int? size,
      }) => delta.matchesTarget(
        installedVersion: version,
        targetPlatform: platform,
        targetArchitecture: arch,
        fullAssetName: name ?? delta.fullAsset,
        fullSize: size ?? delta.patchSize * 10,
        fullDigest: digest ?? 'sha256:${delta.fullSha256}',
      );
      expect(matches(), isTrue);
      expect(matches(version: '0.9.0'), isFalse);
      expect(matches(version: '1.0.0-beta.1'), isFalse);
      expect(matches(platform: 'windows'), isFalse);
      expect(matches(arch: 'x86_64'), isFalse);
      expect(matches(arch: 'universal'), isFalse);
      expect(matches(name: 'VeneraX-1.0.1.apk'), isFalse);
      expect(matches(digest: 'sha256:${'0' * 64}'), isFalse);
      expect(matches(digest: ''), isFalse);
      expect(matches(size: delta.patchSize), isFalse);
      expect(matches(size: 0), isFalse);
    },
  );

  test(
    'Android asset selection falls back to a compatible universal package',
    () {
      const names = [
        'VeneraX-1.0.1.apk',
        'VeneraX-1.0.1-arm64-v8a.apk',
        'VeneraX-1.0.1-universal.apk',
      ];
      expect(
        selectAndroidUpdateAssetName(names, ['x86_64']),
        'VeneraX-1.0.1-universal.apk',
      );
      expect(
        selectAndroidUpdateAssetName(names.take(2).toList(), ['x86_64']),
        'VeneraX-1.0.1.apk',
      );
      expect(
        selectAndroidUpdateAssetName(names.take(2).toList(), []),
        'VeneraX-1.0.1.apk',
      );
    },
  );

  test('Android asset selection returns null when no release APK matches', () {
    expect(
      selectAndroidUpdateAssetName(['VeneraX-1.0.1-arm64-v8a.apk'], ['x86_64']),
      isNull,
    );
    expect(
      selectAndroidUpdateAssetName(
        ['update-manifest.json', 'update.patch', 'VeneraX-1.0.1-windows.zip'],
        ['arm64-v8a'],
      ),
      isNull,
    );
    expect(selectAndroidUpdateAssetName([], []), isNull);
  });

  test('Android asset selection excludes debug packages at every priority', () {
    expect(
      selectAndroidUpdateAssetName(
        [
          'VeneraX-1.0.1-DEBUG-arm64-v8a.apk',
          'VeneraX-1.0.1-debug-universal.apk',
          'VeneraX-1.0.1.apk',
        ],
        ['arm64-v8a'],
      ),
      'VeneraX-1.0.1.apk',
    );
    expect(
      selectAndroidUpdateAssetName(
        ['VeneraX-1.0.1-debug-arm64-v8a.apk', 'VeneraX-1.0.1-debug.apk'],
        ['arm64-v8a'],
      ),
      isNull,
    );
  });
}

/// Mutates fixed ZIP header fields without using the decoder under test.
void _editZipEntry(
  Uint8List bytes,
  String name,
  void Function(ByteData view, int central, int local) change,
) {
  final view = ByteData.sublistView(bytes);
  final end = bytes.length - 22;
  expect(view.getUint32(end, Endian.little), 0x06054b50);
  var central = view.getUint32(end + 16, Endian.little);
  final count = view.getUint16(end + 10, Endian.little);
  for (var i = 0; i < count; i++) {
    expect(view.getUint32(central, Endian.little), 0x02014b50);
    final nameLength = view.getUint16(central + 28, Endian.little);
    final extraLength = view.getUint16(central + 30, Endian.little);
    final commentLength = view.getUint16(central + 32, Endian.little);
    final entryName = utf8.decode(
      bytes.sublist(central + 46, central + 46 + nameLength),
    );
    if (entryName == name) {
      final local = view.getUint32(central + 42, Endian.little);
      expect(view.getUint32(local, Endian.little), 0x04034b50);
      change(view, central, local);
      return;
    }
    central += 46 + nameLength + extraLength + commentLength;
  }
  fail('Missing ZIP fixture entry $name');
}

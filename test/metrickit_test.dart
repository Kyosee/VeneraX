import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/diagnostics.dart';
import 'package:venera/foundation/metrickit.dart';

/// On iOS and macOS the system's own crash and hang reports reach the app
/// through MetricKit on a later launch, as JSON the host keeps on disk. The
/// report needs what the system says about each one and the stack of the
/// thread it blames, as text, and each delivery has to land on the right run.
void main() {
  Map<String, Object?> frame(
    String binary,
    int offset, {
    List<Map<String, Object?>>? sub,
    String? uuid,
  }) => {
    'binaryUUID': uuid ?? '$binary-UUID'.toUpperCase(),
    'offsetIntoBinaryTextSegment': offset,
    'sampleCount': 1,
    'binaryName': binary,
    'address': 4300000000 + offset,
    if (sub != null) 'subFrames': sub,
  };

  // A crash stack comes as a chain: each frame's caller is its sub-frame.
  final crashed = frame(
    'libsqlite3.dylib',
    1234,
    sub: [
      frame('App', 56789, sub: [frame('Flutter', 4242)]),
    ],
  );

  final crash = {
    'version': '1.0.0',
    'callStackTree': {
      'callStackPerThread': true,
      'callStacks': [
        {
          'threadAttributed': false,
          'callStackRootFrames': [frame('libsystem_idle.dylib', 1)],
        },
        {
          'threadAttributed': true,
          'callStackRootFrames': [crashed],
        },
      ],
    },
    'diagnosticMetaData': {
      'appBuildVersion': '310',
      'appVersion': '3.1.0',
      'regionFormat': 'US',
      'exceptionType': 1,
      'osVersion': 'iPhone OS 18.1 (22B83)',
      'deviceType': 'iPhone15,2',
      'exceptionCode': 1,
      'signal': 11,
      'virtualMemoryRegionInfo': '0x10 is not in any region /private/regions',
      'terminationReason': 'Namespace SIGNAL, Code 11 Segmentation fault: 11',
      'platformArchitecture': 'arm64e',
    },
  };

  // A hang stack is sampled: a frame can lead to several callees.
  final hang = {
    'version': '1.0.0',
    'callStackTree': {
      'callStackPerThread': true,
      'callStacks': [
        {
          'threadAttributed': true,
          'callStackRootFrames': [
            frame(
              'Runner',
              10,
              sub: [
                frame('Flutter', 20, sub: [frame('App', 30)]),
                frame('UIKitCore', 40),
              ],
            ),
          ],
        },
      ],
    },
    'diagnosticMetaData': {
      'appVersion': '3.1.0',
      'hangDuration': '8 sec',
      'osVersion': 'iPhone OS 18.1 (22B83)',
      'deviceType': 'iPhone15,2',
    },
  };

  String payload({
    List<Object?>? crashes,
    List<Object?>? hangs,
    Map<String, Object?> extra = const {},
  }) => jsonEncode({
    'timeStampBegin': '2026-11-20 10:00:00',
    'timeStampEnd': '2026-11-20 10:00:00',
    if (crashes != null) 'crashDiagnostics': crashes,
    if (hangs != null) 'hangDiagnostics': hangs,
    ...extra,
  });

  test('a crash comes out as what the system says, then the blamed stack', () {
    final text = describeSystemDiagnostics(payload(crashes: [crash]))!;
    expect(
      text,
      'Reported for: 2026-11-20 10:00:00\n'
      'Crash:\n'
      'Exception type: 1 (EXC_BAD_ACCESS)\n'
      'Exception code: 1\n'
      'Signal: 11 (SIGSEGV)\n'
      'Termination reason: Namespace SIGNAL, Code 11 Segmentation fault: 11\n'
      'App version: 3.1.0 (310)\n'
      'OS version: iPhone OS 18.1 (22B83)\n'
      'Device: iPhone15,2\n'
      'Architecture: arm64e\n'
      'Attributed thread:\n'
      '  #00 libsqlite3.dylib +1234 (LIBSQLITE3.DYLIB-UUID)\n'
      '  #01 App +56789 (APP-UUID)\n'
      '  #02 Flutter +4242 (FLUTTER-UUID)',
    );
  });

  test('threads the system does not blame and memory regions are left out', () {
    final text = describeSystemDiagnostics(payload(crashes: [crash]))!;
    expect(text, isNot(contains('libsystem_idle')));
    expect(text, isNot(contains('regions')));
  });

  test('a sampled hang stack is walked depth first', () {
    final text = describeSystemDiagnostics(payload(hangs: [hang]))!;
    expect(text, contains('Hang:\nHang duration: 8 sec\nApp version: 3.1.0\n'));
    expect(
      text,
      endsWith(
        'Attributed thread:\n'
        '  #00 Runner +10 (RUNNER-UUID)\n'
        '  #01 Flutter +20 (FLUTTER-UUID)\n'
        '  #02 App +30 (APP-UUID)\n'
        '  #03 UIKitCore +40 (UIKITCORE-UUID)',
      ),
    );
  });

  test('crashes and hangs in one delivery each get their own section', () {
    final text = describeSystemDiagnostics(
      payload(crashes: [crash], hangs: [hang]),
    )!;
    expect(text.indexOf('Crash:'), lessThan(text.indexOf('\n\nHang:')));
  });

  test('a deep stack stops at 64 frames and says so', () {
    // As deep as a stack overflow leaves it.
    var deepest = frame('lib999', 999);
    for (var i = 998; i >= 0; i--) {
      deepest = frame('lib$i', i, sub: [deepest]);
    }
    final text = describeSystemDiagnostics(
      payload(
        crashes: [
          {
            'callStackTree': {
              'callStacks': [
                {
                  'threadAttributed': true,
                  'callStackRootFrames': [deepest],
                },
              ],
            },
          },
        ],
      ),
    )!;
    expect(text, contains('  #63 lib63 +63'));
    expect(text, isNot(contains('#64')));
    expect(text, endsWith('  (more frames not shown)'));

    final exact = describeSystemDiagnostics(
      payload(
        crashes: [
          {
            'callStackTree': {
              'callStacks': [
                {
                  'threadAttributed': true,
                  'callStackRootFrames': [
                    for (var i = 0; i < 64; i++) frame('lib$i', i),
                  ],
                },
              ],
            },
          },
        ],
      ),
    )!;
    expect(exact, contains('#63 lib63'));
    expect(exact, isNot(contains('more frames')));
  });

  test('missing names and odd values do not stop the rest', () {
    final text = describeSystemDiagnostics(
      payload(
        crashes: [
          'not a diagnostic',
          {
            'diagnosticMetaData': {'signal': 99, 'exceptionType': 'weird'},
            'callStackTree': {
              'callStacks': [
                {
                  'threadAttributed': true,
                  'callStackRootFrames': [
                    {'offsetIntoBinaryTextSegment': 8},
                    7,
                    {'binaryName': 'App'},
                  ],
                },
              ],
            },
          },
        ],
      ),
    )!;
    expect(text, contains('Signal: 99\n'));
    expect(text, contains('Exception type: weird\n'));
    expect(text, contains('  #00 <unknown> +8\n'));
    expect(text, contains('  #01 App +?'));
  });

  test('a delivery without a crash or hang gives nothing', () {
    expect(
      describeSystemDiagnostics(
        payload(
          extra: {
            'cpuExceptionDiagnostics': [
              {'diagnosticMetaData': {}},
            ],
          },
        ),
      ),
      isNull,
    );
    expect(describeSystemDiagnostics(payload(crashes: [], hangs: [])), isNull);
  });

  test('text that is no delivery gives nothing', () {
    expect(describeSystemDiagnostics(''), isNull);
    expect(describeSystemDiagnostics('plain text'), isNull);
    expect(describeSystemDiagnostics('{"crashDiagnostics": '), isNull);
    expect(describeSystemDiagnostics('[1, 2]'), isNull);
    expect(describeSystemDiagnostics('{"crashDiagnostics": "x"}'), isNull);
  });

  test('deliveries are picked by when they arrived, oldest first', () {
    final names = [
      'system-1000-0.json',
      'system-2500-1.json',
      'system-2500-0.json',
      'system-1999-0.json',
      'system-2000-0.json',
      'system-3000-0.json',
      // The archived runs and anything else in the folder.
      '1500.json',
      '1500.trace.txt',
      'system-2100-0.json.tmp',
      'system-x-0.json',
    ];
    // The start counts, the end belongs to the next run.
    expect(pickSystemDiagnostics(names, from: 2000, to: 3000), [
      'system-2000-0.json',
      'system-2500-0.json',
      'system-2500-1.json',
    ]);
    expect(pickSystemDiagnostics(names, from: 2600), ['system-3000-0.json']);
    expect(pickSystemDiagnostics(names, from: 4000), isEmpty);
  });

  group('kept files', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('metrickit_test'));

    tearDown(() => dir.deleteSync(recursive: true));

    test('those in range are read, broken ones skipped', () {
      File(
        '${dir.path}/system-1000-0.json',
      ).writeAsStringSync(payload(hangs: [hang]));
      File(
        '${dir.path}/system-2000-0.json',
      ).writeAsStringSync(payload(crashes: [crash]));
      File('${dir.path}/system-2000-1.json').writeAsStringSync('{broken');
      File('${dir.path}/system-2001-0.json').writeAsBytesSync([0xff, 0xfe]);
      final text = readSystemDiagnostics(dir, from: 1500)!;
      expect(text, contains('Crash:'));
      expect(text, isNot(contains('Hang:')));
      expect(readSystemDiagnostics(dir, from: 5000), isNull);
    });

    test('a missing folder gives nothing', () {
      expect(
        readSystemDiagnostics(Directory('${dir.path}/missing'), from: 0),
        isNull,
      );
    });
  });

  test('the stack survives redaction in the report', () {
    const uuid = '70B89F27-1634-3580-A695-57CDB41D7743';
    final report = DiagnosticsReport.build(
      appVersion: '3.1.0',
      platform: 'ios',
      systemReport: describeSystemDiagnostics(
        payload(
          crashes: [
            {
              'diagnosticMetaData': crash['diagnosticMetaData'],
              'callStackTree': {
                'callStacks': [
                  {
                    'threadAttributed': true,
                    'callStackRootFrames': [
                      frame('libsystem_kernel.dylib', 37568, uuid: uuid),
                    ],
                  },
                ],
              },
            },
          ],
        ),
      ),
    );
    expect(report, contains('  #00 libsystem_kernel.dylib +37568 ($uuid)'));
    expect(report, contains('OS version: iPhone OS 18.1 (22B83)'));
    expect(report, contains('Device: iPhone15,2'));
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/session_guard.dart';
import 'package:venera/pages/diagnostics_page.dart';
import 'package:venera/utils/translations.dart';

/// The page is where the user checks, before anything leaves the device, what
/// a report contains: the run that ended abnormally comes up first, already
/// redacted, and the current run is one tap away.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  String? clipboard;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() async {
    appdata.settings['language'] = 'en-US';
    Log.clear();
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        });

    dir = Directory.systemTemp.createTempSync('diagnostics-page-');
    App.dataPath = dir.path;
    final reports = Directory('${dir.path}/diagnostics')..createSync();
    final crashed = SessionRecord(
      id: DateTime(2026, 11, 20, 9).millisecondsSinceEpoch,
      version: '1.2.3',
      presence: SessionRecord.front,
      active: ['reader'],
    );
    File('${reports.path}/${crashed.id}.json').writeAsStringSync(
      jsonEncode({
        ...crashed.toJson(),
        'archivedAt': DateTime(2026, 11, 20, 10).millisecondsSinceEpoch,
      }),
    );
    File('${reports.path}/${crashed.id}.log').writeAsStringSync(
      LogItem(
        LogLevel.error,
        'Reader',
        'decode failed for https://example.com/a/1.webp',
        DateTime(2026, 11, 20, 9, 30),
      ).toString(),
    );
    await SessionGuard.start(
      directory: dir,
      version: '1.2.4',
      bootTime: () => 1000,
      observeLifecycle: false,
    );
  });

  tearDown(() {
    SessionGuard.reset();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, {String? reportId}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => OverlayWidget(child!),
        home: DiagnosticsPage(reportId: reportId),
      ),
    );
    await tester.pump();
  }

  testWidgets('opens on the abnormal exit, already redacted', (tester) async {
    await open(tester);

    expect(find.textContaining('== Run that ended abnormally =='), findsOne);
    expect(find.textContaining('App version: 1.2.3'), findsOne);
    expect(find.textContaining('In progress: reader'), findsOne);
    expect(find.textContaining('https://site-1/….webp'), findsOne);
    expect(find.textContaining('example.com'), findsNothing);
    expect(find.text('11-20 09:00'), findsOne);
    expect(find.text('This run'), findsOne);
  });

  testWidgets('the current run is one tap away and copies as shown', (
    tester,
  ) async {
    Log.error('Sync', 'upload failed for someone@example.com');
    await open(tester);

    await tester.tap(find.text('This run'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('== Current run =='), findsOne);
    expect(find.textContaining('App version: 1.2.4'), findsOne);
    expect(find.textContaining('upload failed for <email>'), findsOne);

    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(clipboard, contains('== Current run =='));
    expect(clipboard, isNot(contains('someone@example.com')));
    expect(find.text('Copied'), findsOne);
    // Let the toast expire.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('with nothing on record it shows the current run', (
    tester,
  ) async {
    Directory('${dir.path}/diagnostics').deleteSync(recursive: true);
    await open(tester);

    expect(find.textContaining('== Current run =='), findsOne);
    expect(find.text('This run'), findsNothing);
  });

  testWidgets('on Apple systems a run shows the system reports that arrived '
      'before the next failure', (tester) async {
    final reports = '${dir.path}/diagnostics';
    final later = SessionRecord(
      id: DateTime(2026, 11, 20, 11).millisecondsSinceEpoch,
      version: '1.2.3',
      presence: SessionRecord.front,
      lastAt: DateTime(2026, 11, 20, 11, 5).millisecondsSinceEpoch,
    );
    File('$reports/${later.id}.json').writeAsStringSync(
      jsonEncode({
        ...later.toJson(),
        'archivedAt': DateTime(2026, 11, 20, 12).millisecondsSinceEpoch,
      }),
    );
    void delivery(DateTime arrived, String binary) {
      File(
        '$reports/system-${arrived.millisecondsSinceEpoch}-0.json',
      ).writeAsStringSync(
        jsonEncode({
          'crashDiagnostics': [
            {
              'callStackTree': {
                'callStacks': [
                  {
                    'threadAttributed': true,
                    'callStackRootFrames': [
                      {'binaryName': binary, 'offsetIntoBinaryTextSegment': 1},
                    ],
                  },
                ],
              },
            },
          ],
        }),
      );
    }

    // Each arrives on the launch after its crash.
    delivery(DateTime(2026, 11, 20, 10), 'FirstCrash');
    delivery(DateTime(2026, 11, 20, 12), 'SecondCrash');

    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await open(tester);
      expect(find.textContaining('#00 SecondCrash +1'), findsOne);
      expect(find.textContaining('FirstCrash'), findsNothing);

      await tester.tap(find.text('11-20 09:00'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('#00 FirstCrash +1'), findsOne);
      expect(find.textContaining('SecondCrash'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

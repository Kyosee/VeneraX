import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/session_guard.dart';
import 'package:venera/pages/diagnostics_page.dart';
import 'package:venera/pages/recovery_page.dart';
import 'package:venera/utils/translations.dart';

/// When the app keeps dying right after launch the user never reaches the
/// logs page. This page comes up before anything that could be the cause, and
/// offers a way in that skips it and a way to get the report out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUpAll(() async {
    await AppTranslation.init();
  });

  setUp(() {
    appdata.settings['language'] = 'en-US';
    Log.clear();
    dir = Directory.systemTemp.createTempSync('recovery-page-');
    App.dataPath = dir.path;
  });

  tearDown(() {
    SessionGuard.reset();
    dir.deleteSync(recursive: true);
  });

  Future<List<bool>> open(
    WidgetTester tester, {
    Future<void> Function()? prepareReport,
  }) async {
    final choices = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => OverlayWidget(child!),
        home: RecoveryPage(
          onChoice: choices.add,
          prepareReport: prepareReport ?? () async {},
        ),
      ),
    );
    return choices;
  }

  testWidgets('safe mode is chosen with one tap and the page stops offering', (
    tester,
  ) async {
    final choices = await open(tester);
    expect(
      find.text('The app closed right after starting, more than once'),
      findsOne,
    );

    await tester.tap(find.text('Start in safe mode'));
    await tester.pump();
    expect(choices, [true]);
    expect(find.text('Start in safe mode'), findsNothing);
    expect(find.text('Start normally'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOne);
  });

  testWidgets('an ordinary start is one tap too', (tester) async {
    final choices = await open(tester);
    await tester.tap(find.text('Start normally'));
    await tester.pump();
    expect(choices, [false]);
  });

  testWidgets('the report opens once the failed run has been set aside', (
    tester,
  ) async {
    final prepared = Completer<void>();
    var started = 0;
    final choices = await open(
      tester,
      prepareReport: () {
        started++;
        return prepared.future;
      },
    );
    // Started with the page, not with the tap: closing the page must not
    // lose the record.
    expect(started, 1);

    await tester.tap(find.text('Export diagnostic report'));
    await tester.pump();
    expect(find.byType(DiagnosticsPage), findsNothing);

    prepared.complete();
    await tester.pumpAndSettle();
    expect(find.byType(DiagnosticsPage), findsOne);
    expect(find.textContaining('VeneraX diagnostics'), findsOne);
    expect(choices, isEmpty);
  });
}

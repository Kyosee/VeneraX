import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/reading_statistics_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();

    tempDir = Directory.systemTemp.createTempSync(
      'venera-home-reading-statistics-',
    );
    App.dataPath = tempDir.path;
    await HistoryManager().init();

    appdata.settings['homeSections'] = [
      for (final section in kHomeSections)
        {'id': section.id, 'visible': section.id == 'history'},
    ];
  });

  tearDownAll(() {
    HistoryManager().close();
    tempDir.deleteSync(recursive: true);
  });

  testWidgets('home exposes a labeled reading statistics entry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: HomePage())),
    );
    await tester.pump();

    final entry = find.byKey(const Key('home-reading-statistics-entry'));
    expect(entry, findsOneWidget);
    expect(find.text('Reading Statistics'), findsOneWidget);

    final chevrons = find.byIcon(Icons.chevron_right_rounded);
    expect(chevrons, findsNWidgets(2));
    expect(
      tester.getCenter(chevrons.at(0)).dx,
      tester.getCenter(chevrons.at(1)).dx,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(ReadingStatisticsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

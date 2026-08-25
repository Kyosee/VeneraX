import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/home_layout.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();

    tempDir = Directory.systemTemp.createTempSync('venera-home-edit-back-');
    App.dataPath = tempDir.path;
  });

  setUp(() {
    appdata.settings['homeSections'] = [
      for (final section in kHomeSections) {'id': section.id, 'visible': false},
    ];
  });

  tearDownAll(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        tempDir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    tempDir.deleteSync(recursive: true);
  });

  testWidgets('system back exits home edit mode without leaving home (#221)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final mainNavigatorKey = GlobalKey<NavigatorState>();
    App.mainNavigatorKey = mainNavigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: NaviPane(
          paneItems: [
            PaneItemEntry(
              label: 'Home',
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
            ),
          ],
          paneActions: [],
          pageBuilder: (_) => const HomePage(),
          observer: NaviObserver(),
          navigatorKey: mainNavigatorKey,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Edit Home'));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);

    final handled = await tester.runAsync(() async {
      final result = await tester.binding.handlePopRoute();
      await appdata.saveData(false);
      return result;
    });
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byTooltip('Edit Home'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
  });
}

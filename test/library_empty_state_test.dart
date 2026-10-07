import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/home_page.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    temp = Directory.systemTemp.createTempSync('library-empty-state-');
    App.dataPath = temp.path;
    await appdata.init();
    await AppTranslation.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalManager().init();
    debugDefaultTargetPlatformOverride = null;
  });
  tearDownAll(() async {
    await appdata.saveData(false);
    LocalManager().close();
    JsEngine().dispose();
    debugDefaultTargetPlatformOverride = null;
    temp.deleteSync(recursive: true);
  });
  setUp(() => appdata.settings['language'] = 'en-US');

  testWidgets(
    'empty library offers import and opens the existing import flow',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LocalComicsPage()));
      await tester.pumpAndSettle();
      expect(find.text('Your library is empty'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await tester.pumpAndSettle();
      expect(find.byType(ImportComicsWidget), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('empty category and query can return to the full library', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LocalComicsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Downloaded'));
    await tester.pumpAndSettle();
    expect(find.text('No comics in this category'), findsOneWidget);
    await tester.tap(find.text('Show all comics'));
    await tester.pumpAndSettle();
    expect(find.text('Your library is empty'), findsOneWidget);
    await tester.tap(find.byTooltip('Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No matching comics'), findsOneWidget);
    await tester.tap(find.text('Show all comics'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Your library is empty'), findsOneWidget);
  });

  for (final language in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets(
      'network concurrency explanations fit narrow large text in $language',
      (tester) async {
        appdata.settings['language'] = language;
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: const Scaffold(body: NetworkSettings()),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Images downloaded at once within each comic. Reduce this if the source limits requests.'
                .tl,
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Comics downloaded at the same time. Combined with Download Threads, this controls the total number of image requests.'
                .tl,
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

ComicSource _source(int i) => ComicSource(
  'Source $i',
  'filter_test_$i',
  null,
  null,
  null,
  null,
  const [],
  const SearchPageData(null, null, null),
  null,
  null,
  null,
  null,
  null,
  null,
  '',
  '',
  '1.0.0',
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  null,
  false,
  false,
  null,
  null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final registered = <String>[];

  setUpAll(() async {
    await AppTranslation.init();
    temp = Directory.systemTemp.createTempSync('multi-pages-filter-');
    App.dataPath = temp.path;
  });

  tearDownAll(() {
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() => appdata.settings['languageFilterSources'] = []);

  tearDown(() {
    for (final key in registered) {
      ComicSourceManager().remove(key);
    }
    registered.clear();
  });

  // Closing the page saves settings with real file IO.
  Future<void> settleWrites(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(body: setLanguageFilterSourcesWidget()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty list without sources shows no add button', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('No items'.tl), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Add'.tl), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await settleWrites(tester);
  });

  testWidgets('long add dialog keeps its buttons on screen', (tester) async {
    for (var i = 0; i < 40; i++) {
      final source = _source(i);
      expect(ComicSourceManager().add(source), isTrue);
      registered.add(source.key);
    }
    await open(tester);
    expect(find.text('No items'.tl), findsOneWidget);

    // The button in the middle of the empty page.
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(CheckboxListTile).first);
    await tester.pump();
    final confirm = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(FilledButton),
    );
    expect(tester.getRect(confirm).bottom, lessThanOrEqualTo(700));

    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('No items'.tl), findsNothing);
    expect(find.text('Source 0'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await settleWrites(tester);
    expect(appdata.settings['languageFilterSources'], ['filter_test_0']);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  testWidgets('restores an index safely before the first tab layout', (
    tester,
  ) async {
    final bucket = PageStorageBucket();
    const tabBarKey = PageStorageKey<String>('restored-tab-bar');

    Widget buildApp({required bool showTabBar}) {
      return MaterialApp(
        home: PageStorage(
          bucket: bucket,
          child: showTabBar
              ? DefaultTabController(
                  length: 2,
                  child: const Scaffold(
                    body: AppTabBar(
                      key: tabBarKey,
                      tabs: [
                        Tab(text: 'First'),
                        Tab(text: 'Second'),
                      ],
                    ),
                  ),
                )
              : const SizedBox(),
        ),
      );
    }

    await tester.pumpWidget(buildApp(showTabBar: true));
    bucket.writeState(tester.element(find.byKey(tabBarKey)), 1);
    await tester.pumpWidget(buildApp(showTabBar: false));

    await tester.pumpWidget(buildApp(showTabBar: true));
    await tester.pump();

    expect(tester.takeException(), isNull);
    final context = tester.element(find.byKey(tabBarKey));
    expect(DefaultTabController.of(context).index, 1);
  });

  testWidgets('keeps trailing selector fixed while tabs scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final items = List.generate(
      20,
      (index) =>
          TabPageSelectorItem(label: 'Page $index', subtitle: 'Source $index'),
    );
    const selectorKey = Key('fixed-selector');

    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: items.length,
          child: Builder(
            builder: (context) {
              final controller = DefaultTabController.of(context);
              return Scaffold(
                body: AppTabBar(
                  controller: controller,
                  tabs: items.map((item) => Tab(text: item.label)).toList(),
                  trailing: TabPageSelectorButton(
                    key: selectorKey,
                    controller: controller,
                    items: items,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    final before = tester.getTopLeft(find.byKey(selectorKey));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-900, 0),
    );
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.byKey(selectorKey)), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('searches selector by source and switches existing controller', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final items = List.generate(
      15,
      (index) => TabPageSelectorItem(
        label: 'Page $index',
        subtitle: 'Source $index',
        searchTerms: 'source-key-$index',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: items.length,
          child: Builder(
            builder: (context) {
              final controller = DefaultTabController.of(context);
              return Scaffold(
                body: AppTabBar(
                  controller: controller,
                  tabs: items.map((item) => Tab(text: item.label)).toList(),
                  trailing: TabPageSelectorButton(
                    controller: controller,
                    items: items,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.format_list_bulleted_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Select Source'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Source 12');
    await tester.pump();
    final matchedSource = find.descendant(
      of: find.byType(ListTile),
      matching: find.text('Source 12'),
    );
    expect(matchedSource, findsOneWidget);
    expect(find.text('Source 11'), findsNothing);

    await tester.tap(matchedSource);
    await tester.pumpAndSettle();

    final tabBarContext = tester.element(find.byType(AppTabBar));
    expect(DefaultTabController.of(tabBarContext).index, 12);
    expect(find.text('Select Source'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an empty state when selector search has no matches', (
    tester,
  ) async {
    final items = [
      const TabPageSelectorItem(label: 'Popular', subtitle: 'Alpha Source'),
      const TabPageSelectorItem(label: 'Latest', subtitle: 'Beta Source'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: DefaultTabController(
          length: items.length,
          child: Builder(
            builder: (context) {
              final controller = DefaultTabController.of(context);
              return Scaffold(
                body: AppTabBar(
                  controller: controller,
                  tabs: items.map((item) => Tab(text: item.label)).toList(),
                  trailing: TabPageSelectorButton(
                    controller: controller,
                    items: items,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.format_list_bulleted_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();

    expect(find.text('No matching items'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

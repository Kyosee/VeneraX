import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/task_list.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);
  setUp(() => appdata.settings['language'] = 'en-US');

  Widget app(List<TaskListEntry> entries) => MaterialApp(
    home: Scaffold(
      body: TaskListView(
        key: const PageStorageKey('test-tasks'),
        entries: entries,
        emptyText: 'No task history',
        emptyIcon: Icons.history,
      ),
    ),
  );

  List<TaskListEntry> entries({int count = 1000, ValueChanged<int>? onBuild}) =>
      List.generate(
        count,
        (i) => TaskListEntry(
          id: '$i',
          title: 'Book $i',
          category: i.isEven ? 'Import Data' : 'Export Comics',
          status: i % 3 == 0 ? 'failed' : 'completed',
          time: DateTime(2026, 1, 1),
          builder: (_) {
            onBuild?.call(i);
            return SizedBox(height: 96, child: Text('Book $i'));
          },
        ),
      );

  testWidgets(
    'large task lists build only visible cards and search resets scroll',
    (tester) async {
      final built = <int>{};
      await tester.pumpWidget(app(entries(onBuild: built.add)));
      await tester.pump();
      expect(built.length, lessThan(20));
      expect(find.text('1000 of 1000 tasks'), findsOneWidget);
      await tester.drag(find.byType(ListView), const Offset(0, -700));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'book 999');
      await tester.pumpAndSettle();
      expect(find.text('Book 999'), findsOneWidget);
      expect(find.text('1 of 1000 tasks'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Book 0'), findsOneWidget);
    },
  );

  testWidgets(
    'type and status filters intersect and empty results can be cleared',
    (tester) async {
      await tester.pumpWidget(app(entries(count: 6)));
      await tester.pumpAndSettle();
      final dropdowns = find.byType(DropdownButton<String>);
      await tester.tap(dropdowns.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import Data').last);
      await tester.pumpAndSettle();
      await tester.tap(dropdowns.last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Failed').last);
      await tester.pumpAndSettle();
      expect(find.text('1 of 6 tasks'), findsOneWidget);
      expect(find.text('Book 0'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'missing');
      await tester.pumpAndSettle();
      expect(find.text('No matching tasks'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('6 of 6 tasks'), findsOneWidget);
    },
  );

  testWidgets('expanded card state follows identity when task order changes', (
    tester,
  ) async {
    TaskListEntry entry(String id) => TaskListEntry(
      id: id,
      title: id,
      category: 'Import Data',
      status: 'completed',
      time: DateTime(2026),
      builder: (_) =>
          ExpansionTile(title: Text(id), children: [Text('details $id')]),
    );
    await tester.pumpWidget(app([entry('A'), entry('B')]));
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text('details A'), findsOneWidget);
    await tester.pumpWidget(app([entry('B'), entry('A')]));
    await tester.pumpAndSettle();
    expect(find.text('details A'), findsOneWidget);
    expect(find.text('details B'), findsNothing);

    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No matching tasks'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.widgetWithText(TextButton, 'Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('details A'), findsOneWidget);
    expect(find.text('details B'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['en-US', 'zh-CN', 'zh-TW']) {
    testWidgets('narrow task controls fit large text in $locale', (
      tester,
    ) async {
      appdata.settings['language'] = locale;
      tester.view.physicalSize = const Size(320, 640);
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
          home: Scaffold(
            body: TaskListView(
              entries: entries(count: 3),
              emptyText: 'No task history'.tl,
              emptyIcon: Icons.history,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Task type'.tl), findsOneWidget);
    });
  }
}

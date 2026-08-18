import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  testWidgets('compact navigation shows labels and still changes pages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final observer = NaviObserver();
    final navigatorKey = GlobalKey<NavigatorState>();
    final items = [
      PaneItemEntry(
        label: 'Home',
        icon: Icons.home_outlined,
        activeIcon: Icons.home,
      ),
      PaneItemEntry(
        label: 'Explore',
        icon: Icons.explore_outlined,
        activeIcon: Icons.explore,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          paneItems: items,
          paneActions: const [],
          pageBuilder: (index) => Center(child: Text('Page $index')),
          observer: observer,
          navigatorKey: navigatorKey,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsWidgets);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('Page 0'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Explore'));
    await tester.pumpAndSettle();

    expect(find.text('Page 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact navigation hides labels when four items are cramped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final observer = NaviObserver();
    final navigatorKey = GlobalKey<NavigatorState>();
    final items = [
      PaneItemEntry(
        label: 'Home',
        icon: Icons.home_outlined,
        activeIcon: Icons.home,
      ),
      PaneItemEntry(
        label: 'Explore',
        icon: Icons.explore_outlined,
        activeIcon: Icons.explore,
      ),
      PaneItemEntry(
        label: 'Library',
        icon: Icons.library_books_outlined,
        activeIcon: Icons.library_books,
      ),
      PaneItemEntry(
        label: 'Settings',
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: NaviPane(
          paneItems: items,
          paneActions: const [],
          pageBuilder: (index) => Center(child: Text('Page $index')),
          observer: observer,
          navigatorKey: navigatorKey,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The current page title remains in the top bar, but bottom labels are
    // omitted so all four destinations retain a comfortable icon target.
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Explore'), findsNothing);
    expect(find.text('Library'), findsNothing);
    expect(find.text('Settings'), findsNothing);
    expect(find.byIcon(Icons.explore_outlined), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

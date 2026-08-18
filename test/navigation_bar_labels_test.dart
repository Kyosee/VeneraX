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
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

void main() {
  for (final size in [
    const Size(390, 844),
    const Size(626, 900),
    const Size(844, 390),
  ]) {
    testWidgets(
      'mobile content keeps the expected safe bounds at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const contentKey = ValueKey('safe-content');
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(left: 20, right: 10),
                viewPadding: const EdgeInsets.only(left: 20, right: 10),
                systemGestureInsets: const EdgeInsets.only(left: 16, right: 28),
              ),
              child: child!,
            ),
            home: NaviPane(
              paneItems: [
                PaneItemEntry(
                  label: 'Home',
                  icon: Icons.home_outlined,
                  activeIcon: Icons.home,
                ),
              ],
              paneActions: const [],
              pageBuilder: (_) =>
                  const SafeArea(child: SizedBox.expand(key: contentKey)),
              observer: NaviObserver(),
              navigatorKey: GlobalKey<NavigatorState>(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final content = tester.getRect(find.byKey(contentKey));
        if (defaultTargetPlatform == TargetPlatform.android &&
            size.height > size.width) {
          expect(content.right, closeTo(size.width - 10, 0.5));
        } else {
          expect(content.left, greaterThanOrEqualTo(20));
          expect(content.right, closeTo(size.width - 28, 0.5));
        }
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.iOS,
        TargetPlatform.android,
      }),
    );
  }

  testWidgets(
    'keyboard insets reach content without recreating navigation controllers',
    (tester) async {
      tester.view.physicalSize = const Size(626, 900);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(left: 20, right: 10);
      tester.view.viewPadding = const FakeViewPadding(left: 20, right: 10);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: NaviPane(
            paneItems: [
              PaneItemEntry(
                label: 'Home',
                icon: Icons.home_outlined,
                activeIcon: Icons.home,
              ),
            ],
            paneActions: const [],
            pageBuilder: (_) => Builder(
              builder: (context) =>
                  Text('keyboard: ${MediaQuery.viewInsetsOf(context).bottom}'),
            ),
            observer: NaviObserver(),
            navigatorKey: GlobalKey<NavigatorState>(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scope = find
          .descendant(
            of: find.byType(NaviPane),
            matching: find.byType(HeroControllerScope),
          )
          .first;
      final controller = tester.widget<HeroControllerScope>(scope).controller;
      expect(find.text('keyboard: 0.0'), findsOneWidget);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(find.text('keyboard: 300.0'), findsOneWidget);
      expect(
        tester.widget<HeroControllerScope>(scope).controller,
        same(controller),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('compact navigation is icon-only and still changes pages', (
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

    // The top bar keeps the current page title; destinations in the bottom
    // bar are represented by icons only, matching the desktop navigation.
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Explore'), findsNothing);
    expect(find.byIcon(Icons.explore_outlined), findsAtLeastNWidgets(1));
    expect(find.text('Page 0'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.explore_outlined).last);
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

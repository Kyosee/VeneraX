import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(AppTranslation.init);

  Future<void> openMenu(
    WidgetTester tester,
    List<MenuEntry> entries, {
    Size size = const Size(900, 700),
    Offset location = const Offset(160, 140),
    double textScale = 1,
    bool header = false,
    String? title,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMenuX(
                context,
                location,
                entries,
                title: title ?? (header ? 'A comic' : null),
                subtitle: header ? 'Page 8' : null,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  List<MenuEntry> groupedEntries(VoidCallback onMove) => [
    MenuEntry(
      text: 'Read now',
      icon: Icons.menu_book_outlined,
      role: MenuEntryRole.primary,
      onClick: () {},
    ),
    MenuEntry(
      text: 'Favorite',
      icon: Icons.favorite_border,
      group: MenuGroup.organize,
      role: MenuEntryRole.quick,
      onClick: () {},
    ),
    MenuEntry(
      text: 'Move to folder',
      icon: Icons.drive_file_move_outline,
      group: MenuGroup.organize,
      onClick: onMove,
    ),
    MenuEntry(text: 'Linked entries', group: MenuGroup.source, onClick: () {}),
    MenuEntry(text: 'Copy title', group: MenuGroup.more, onClick: () {}),
    MenuEntry(text: 'Remove item', destructive: true, onClick: () {}),
  ];

  testWidgets(
    'desktop opens groups on hover and invokes a leaf once',
    (tester) async {
      var moved = 0;
      await openMenu(tester, groupedEntries(() => moved++));
      expect(find.text('Move to folder'), findsNothing);
      expect(find.text('Read now'), findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Organize')));
      await tester.pumpAndSettle();
      expect(find.text('Move to folder'), findsOneWidget);
      await tester.tap(find.text('Move to folder'));
      await tester.pumpAndSettle();
      expect(moved, 1);
      expect(find.text('Read now'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'mobile shows grouped actions without entering submenus',
    (tester) async {
      var moved = 0;
      await openMenu(
        tester,
        groupedEntries(() => moved++),
        size: const Size(390, 844),
        header: true,
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(SubmenuButton), findsNothing);
      expect(find.text('A comic'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Read now'), findsOneWidget);
      expect(find.text('Favorite'), findsOneWidget);
      expect(find.text('Move to folder'), findsOneWidget);
      expect(find.text('Linked entries'), findsOneWidget);
      await tester.ensureVisible(find.text('Move to folder'));
      await tester.tap(find.text('Move to folder'));
      await tester.pumpAndSettle();
      expect(moved, 1);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'mobile keeps long labels and the last action reachable',
    (tester) async {
      var removed = false;
      await openMenu(
        tester,
        [
          ...List.generate(
            12,
            (index) => MenuEntry(
              text: 'A long action label that must wrap $index',
              icon: Icons.folder_outlined,
              group: MenuGroup.organize,
              onClick: () {},
            ),
          ),
          MenuEntry(
            text: 'Remove item',
            destructive: true,
            onClick: () => removed = true,
          ),
        ],
        size: const Size(320, 568),
        textScale: 2,
        header: true,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Remove item'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove item'));
      await tester.pumpAndSettle();
      expect(removed, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'desktop fits the screen edge and closes with Escape',
    (tester) async {
      const size = Size(560, 360);
      await openMenu(
        tester,
        groupedEntries(() {}),
        size: size,
        location: const Offset(558, 358),
      );
      await tester.tap(find.text('Organize'));
      await tester.pumpAndSettle();
      final bounds = tester.getRect(find.text('Move to folder'));
      expect(bounds.left, greaterThanOrEqualTo(0));
      expect(bounds.right, lessThanOrEqualTo(size.width));
      expect(bounds.bottom, lessThanOrEqualTo(size.height));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Read now'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'a page override replaces a common action without text matching',
    (tester) async {
      var common = 0;
      var page = 0;
      await openMenu(tester, [
        MenuEntry(
          action: MenuAction.readLater,
          text: 'Common action',
          onClick: () => common++,
        ),
        MenuEntry(
          action: MenuAction.readLater,
          text: 'Page action',
          onClick: () => page++,
        ),
      ]);
      expect(find.text('Common action'), findsNothing);
      await tester.tap(find.text('Page action'));
      await tester.pumpAndSettle();
      expect(common, 0);
      expect(page, 1);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'desktop supports keyboard navigation immediately after opening',
    (tester) async {
      var selected = 0;
      await openMenu(tester, [
        MenuEntry(text: 'First action', onClick: () => selected++),
        MenuEntry(text: 'Second action', onClick: () => selected += 10),
      ]);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 1);
      expect(find.text('First action'), findsNothing);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 11);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'outside click dismisses desktop submenus without reopening the menu',
    (tester) async {
      var invoked = 0;
      await openMenu(tester, groupedEntries(() => invoked++));
      await tester.tap(find.text('Organize'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Read now'), findsNothing);
      expect(find.text('Move to folder'), findsNothing);
      expect(invoked, 0);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Read now'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'three mobile quick actions remain usable with large text',
    (tester) async {
      var selected = -1;
      await openMenu(
        tester,
        [
          for (var index = 0; index < 3; index++)
            MenuEntry(
              text: 'Long quick action label $index',
              icon: Icons.bookmark_outline,
              role: MenuEntryRole.quick,
              onClick: () => selected = index,
            ),
        ],
        size: const Size(320, 568),
        textScale: 2,
        header: true,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Long quick action label 2'));
      await tester.tap(find.text('Long quick action label 2'));
      await tester.pumpAndSettle();
      expect(selected, 2);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'long comic titles leave room for the reading actions and header details',
    (tester) async {
      var openedDetails = false;
      const title =
          'The Heroines of a Gal Game Who Avoided the End of Death '
          'Read My Diary And Found Out My Secret';
      await openMenu(
        tester,
        [
          MenuEntry(
            text: 'Continue reading',
            subtitle: 'Chapter 1 · Page 3',
            role: MenuEntryRole.primary,
            onClick: () {},
          ),
          for (final label in ['Favorited', 'In read later', 'Download'])
            MenuEntry(
              text: label,
              icon: Icons.bookmark_outline,
              role: MenuEntryRole.quick,
              onClick: () {},
            ),
          MenuEntry(
            action: MenuAction.details,
            text: 'Details',
            onClick: () => openedDetails = true,
          ),
          ...groupedEntries(() {}).skip(2),
        ],
        size: const Size(360, 640),
        header: true,
        title: title,
      );
      final titleBounds = tester.getRect(find.text(title));
      expect(titleBounds.height, lessThan(60));
      expect(
        tester.getRect(find.text('Details')).bottom,
        lessThan(tester.getRect(find.text('Continue reading')).top),
      );
      final heights = [
        for (final label in ['Favorited', 'In read later', 'Download'])
          tester.getSize(find.widgetWithText(TextButton, label)).height,
      ];
      expect(heights.toSet(), hasLength(1));
      await tester.tap(find.text('Details'));
      await tester.pumpAndSettle();
      expect(openedDetails, isTrue);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'empty menus leave the current route usable',
    (tester) async {
      await openMenu(tester, []);
      expect(tester.takeException(), isNull);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(MenuItemButton), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

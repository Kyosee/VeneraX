import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory directory;
  late String originalDataPath;
  final manager = LocalFavoritesManager();
  const layoutKeys = [
    'favoriteFolder',
    'favoriteExpandedFolders',
    'favoriteSidebarHidden',
  ];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    directory = Directory.systemTemp.createTempSync('venera-favorites-page-');
    originalDataPath = App.dataPath;
    App.dataPath = directory.path;
    await appdata.init();
    await HistoryManager().init();
    await manager.init();
  });

  tearDownAll(() async {
    manager.close();
    HistoryManager().close();
    App.dataPath = originalDataPath;
    App.mainNavigatorKey = null;
    directory.deleteSync(recursive: true);
  });

  setUp(() {
    appdata.settings['language'] = 'en-US';
    for (final key in layoutKeys) {
      appdata.implicitData.remove(key);
    }
    for (final folder in manager.folderNames) {
      if (manager.existsFolder(folder)) manager.deleteFolder(folder);
    }
  });

  Future<void> openPage(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    App.mainNavigatorKey = App.rootNavigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: const Scaffold(body: FavoritesPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Lets the implicit-data writes the page started finish: their file IO is
  /// real, so fake time alone never completes them and their retry timers
  /// would outlive the test.
  Future<void> settleWrites(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 25));
    }
  }

  /// [finder] inside the folder list that is on screen.
  Finder inFolderList(Finder finder) => find
      .descendant(
        of: find.byKey(const ValueKey('favorite_folder_list')),
        matching: finder,
      )
      .hitTestable();

  void nest() {
    manager.createFolder('Parent');
    manager.createFolder('Child');
    manager.moveFolder('Child', 'Parent');
  }

  Map<String, Object> selected(String name) => {
    'name': name,
    'isNetwork': false,
  };

  test('folder names clash regardless of letter case', () {
    manager.createFolder('abc');
    expect(validateFolderName('ABC'), isNotNull);
    expect(validateFolderName('ABC', renaming: 'abc'), isNull);
    expect(validateFolderName('folder_tree'), isNotNull);
  });

  testWidgets('a folder removed by a sync falls back to the overview', (
    tester,
  ) async {
    manager.createFolder('Gone');
    manager.createFolder('Kept');
    appdata.implicitData['favoriteFolder'] = selected('Gone');
    await openPage(tester, 1200);

    manager.deleteFolder('Gone');
    await tester.pumpAndSettle();
    expect(appdata.implicitData['favoriteFolder'], {
      'name': null,
      'isNetwork': false,
    });
    expect(find.text('Favorites'), findsOneWidget);
    await settleWrites(tester);
  });

  testWidgets('a wide window hides and shows the folder list in place', (
    tester,
  ) async {
    manager.createFolder('Parent');
    await openPage(tester, 1200);
    expect(find.byTooltip('Hide folder list').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Show folder list'), findsNothing);

    await tester.tap(find.byTooltip('Hide folder list').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Hide folder list').hitTestable(), findsNothing);
    expect(appdata.implicitData['favoriteSidebarHidden'], isTrue);

    await tester.tap(find.byTooltip('Show folder list'));
    await tester.pumpAndSettle();
    // Back beside the content, not opened as a drawer over it.
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    expect(find.byType(CloseButton), findsNothing);
    expect(find.byTooltip('Hide folder list').hitTestable(), findsOneWidget);
    expect(appdata.implicitData['favoriteSidebarHidden'], isFalse);
    await settleWrites(tester);
  });

  testWidgets('a narrow window opens the folder list as a drawer', (
    tester,
  ) async {
    nest();
    await openPage(tester, 700);
    expect(find.byTooltip('Hide folder list').hitTestable(), findsNothing);

    await tester.tap(find.byTooltip('Folders'));
    await tester.pumpAndSettle();
    expect(find.byType(CloseButton), findsOneWidget);

    await tester.tap(inFolderList(find.byTooltip('Expand')));
    await tester.pumpAndSettle();
    await tester.tap(inFolderList(find.text('Child')));
    await tester.pumpAndSettle();
    expect(find.byType(CloseButton), findsNothing);
    expect(appdata.implicitData['favoriteFolder'], selected('Child'));
    await settleWrites(tester);
  });

  testWidgets('back from a subfolder goes up to its parent', (tester) async {
    nest();
    await openPage(tester, 1200);
    expect(inFolderList(find.text('Child')), findsNothing);

    await tester.tap(inFolderList(find.byTooltip('Expand')));
    await tester.pumpAndSettle();
    await tester.tap(inFolderList(find.text('Child')));
    await tester.pumpAndSettle();
    // The path above the comics leads back to the parent.
    expect(find.widgetWithText(TextButton, 'Parent'), findsOneWidget);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(handled, isTrue);
    expect(appdata.implicitData['favoriteFolder'], selected('Parent'));
    await settleWrites(tester);
  });

  testWidgets('moving a folder closes the dialog and its barrier', (
    tester,
  ) async {
    nest();
    await openPage(tester, 1200);
    await tester.tap(inFolderList(find.byTooltip('Expand')));
    await tester.pumpAndSettle();

    await tester.longPress(inFolderList(find.text('Child')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move Folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Top level'));
    await tester.pumpAndSettle();

    expect(manager.folderTree.parentOf('Child'), isNull);
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    expect(
      find.byWidgetPredicate(
        (w) => w is ModalBarrier && w.color == Colors.black54,
      ),
      findsNothing,
    );
    await settleWrites(tester);
  });

  testWidgets('deleting the open folder shows its parent', (tester) async {
    nest();
    appdata.implicitData['favoriteFolder'] = selected('Child');
    await openPage(tester, 1200);

    await tester.longPress(inFolderList(find.text('Child')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete Folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();

    expect(manager.existsFolder('Child'), isFalse);
    expect(appdata.implicitData['favoriteFolder'], selected('Parent'));
    expect(App.rootNavigatorKey.currentState!.canPop(), isFalse);
    await settleWrites(tester);
  });
}

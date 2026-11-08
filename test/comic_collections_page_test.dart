import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/read_later.dart';
import 'package:venera/pages/comic_collections_page.dart';
import 'package:venera/pages/comic_collection_edit_page.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/read_later_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory directory;
  late String originalDataPath;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    directory = Directory.systemTemp.createTempSync(
      'venera-collection-selection-',
    );
    originalDataPath = App.dataPath;
    App.dataPath = directory.path;
    await appdata.init();
    await HistoryManager().init();
    await LocalFavoritesManager().init();
    await ReadLaterManager().init();
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    ReadLaterManager().close();
    LocalFavoritesManager().close();
    HistoryManager().close();
    App.dataPath = originalDataPath;
    App.mainNavigatorKey = null;
    directory.deleteSync(recursive: true);
  });

  setUp(() async {
    appdata.settings['language'] = 'en-US';
    appdata.settings['comicDisplayMode'] = 'detailed';
    appdata.settings['blockedWords'] = <String>[];
    appdata.settings[ComicCollectionStore.settingsKey] = [
      {'id': 'alpha', 'name': 'Volume Alpha', 'members': []},
      {'id': 'beta', 'name': 'Volume Beta', 'members': []},
      {'id': 'gamma', 'name': 'Other Story', 'members': []},
    ];
    for (final folder in LocalFavoritesManager().folderNames) {
      LocalFavoritesManager().deleteFolder(folder);
    }
    LocalFavoritesManager().createFolder('Saved');
    await ReadLaterManager().clearAll();
    for (final history in HistoryManager().getAll()) {
      HistoryManager().remove(history.id, history.type);
    }
  });

  Future<void> openPage(WidgetTester tester, {double width = 320}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    App.mainNavigatorKey = App.rootNavigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) => const ComicCollectionsPage(),
                ),
              ),
              child: const Text('Open collections'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open collections'));
    await tester.pumpAndSettle();
  }

  Finder tile(String id) => find.byWidgetPredicate(
    (widget) => widget is ComicTile && widget.comic.id == id,
  );

  Set<String> selectedIds(WidgetTester tester) => tester
      .widget<SliverGridComics>(find.byType(SliverGridComics))
      .selections!
      .keys
      .map((comic) => comic.id)
      .toSet();

  Future<void> batchAction(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('Batch manage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> expectBatchDeleteDisabled(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Batch manage'));
    await tester.pumpAndSettle();
    final item = tester.widget<PopupMenuItem<String>>(
      find.byWidgetPredicate(
        (widget) => widget is PopupMenuItem<String> && widget.value == 'delete',
      ),
    );
    expect(item.enabled, isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  Comic asComic(ComicCollection collection) => Comic(
    collection.displayName,
    '',
    collection.id,
    null,
    null,
    '',
    collection.sourceKey,
    null,
    null,
  );

  for (final mode in ['detailed', 'brief']) {
    testWidgets(
      '$mode selection follows visible results and survives refresh',
      (tester) async {
        appdata.settings['comicDisplayMode'] = mode;
        appdata.settings['blockedWords'] = ['Other Story'];
        await openPage(tester);
        expect(tile('gamma'), findsNothing);
        await tester.tap(find.byTooltip('Multi-Select'));
        await tester.pumpAndSettle();
        await tester.tap(tile('alpha'));
        await tester.pumpAndSettle();
        expect(selectedIds(tester), {'alpha'});
        expect(find.byType(ComicPage), findsNothing);

        await tester.tap(
          tile('alpha'),
          buttons: kSecondaryMouseButton,
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(find.text('Edit'), findsNothing);
        expect(find.text('Details'), findsNothing);
        expect(selectedIds(tester), {'alpha'});

        await batchAction(tester, 'Invert Selection');
        expect(selectedIds(tester), {'beta'});
        await batchAction(tester, 'Deselect');
        expect(selectedIds(tester), isEmpty);
        await expectBatchDeleteDisabled(tester);
        ComicCollectionStore.notifyChanged();
        await tester.pumpAndSettle();
        expect(find.byTooltip('Batch manage'), findsOneWidget);

        await batchAction(tester, 'Select All');
        expect(selectedIds(tester), {'alpha', 'beta'});
        await tester.enterText(find.byType(TextField), 'Alpha');
        await tester.pumpAndSettle();
        expect(selectedIds(tester), {'alpha'});

        final collections = ComicCollectionStore.all();
        collections.first.name = 'Volume Alpha refreshed';
        appdata.settings[ComicCollectionStore.settingsKey] = [
          for (final collection in collections) collection.toJson(),
        ];
        ComicCollectionStore.notifyChanged();
        await tester.pumpAndSettle();
        expect(selectedIds(tester), {'alpha'});

        appdata.settings[ComicCollectionStore.settingsKey] = [
          for (final collection in collections.skip(1)) collection.toJson(),
        ];
        ComicCollectionStore.notifyChanged();
        await tester.pumpAndSettle();
        await expectBatchDeleteDisabled(tester);
        expect(find.text('No matching collections'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('context menu preserves editing and back exits selection first', (
    tester,
  ) async {
    await openPage(tester);
    await tester.longPress(tile('alpha'));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    await tester.tap(find.text('Multi-Select'));
    await tester.pumpAndSettle();
    expect(selectedIds(tester), {'alpha'});

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ComicCollectionsPage), findsOneWidget);
    expect(find.byTooltip('Multi-Select'), findsOneWidget);
    expect(selectedIds(tester), isEmpty);
    await tester.tap(
      tile('alpha'),
      buttons: kSecondaryMouseButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ComicCollectionsPage), findsNothing);
    expect(find.text('Open collections'), findsOneWidget);
  });

  for (final mode in ['detailed', 'brief']) {
    testWidgets(
      'mobile $mode card opens reading actions without selecting the card',
      (tester) async {
        appdata.settings['comicDisplayMode'] = mode;
        final originalScale = appdata.settings['comicTileScale'];
        addTearDown(() => appdata.settings['comicTileScale'] = originalScale);
        appdata.settings['comicTileScale'] = mode == 'brief'
            ? 0.75
            : originalScale;
        await openPage(tester, width: mode == 'brief' ? 390 : 320);
        if (mode == 'brief') {
          final coverSize = tester.getSize(
            find.descendant(of: tile('alpha'), matching: find.byType(Hero)),
          );
          final titleSize = tester.getSize(find.text('Volume Alpha'));
          expect(titleSize.width, greaterThan(coverSize.width * 0.85));
          expect(coverSize.height, greaterThan(coverSize.width * 1.3));
          expect(
            tester.getTopLeft(tile('gamma')).dy,
            tester.getTopLeft(tile('alpha')).dy,
          );
          await tester.longPress(tile('alpha'));
        } else {
          await tester.tap(
            find.descendant(
              of: tile('alpha'),
              matching: find.byTooltip('Actions'),
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(selectedIds(tester), isEmpty);
        expect(find.byType(BottomSheet), findsOneWidget);
        expect(find.widgetWithText(FilledButton, 'Read'), findsOneWidget);
        expect(find.byType(SubmenuButton), findsNothing);
        expect(find.text('Add to favorites'), findsOneWidget);
        expect(find.text('Migrate Source'), findsNothing);
        expect(find.text('Linked entries'), findsNothing);
        await tester.ensureVisible(find.text('Edit'));
        await tester.tap(find.text('Edit'));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(ComicCollectionEditPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }

  testWidgets('batch favorites and read later apply to selected collections', (
    tester,
  ) async {
    await openPage(tester);
    await tester.enterText(find.byType(TextField), 'Volume');
    await tester.tap(find.byTooltip('Multi-Select'));
    await tester.pumpAndSettle();
    await batchAction(tester, 'Select All');
    await batchAction(tester, 'Add to favorites');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(
      LocalFavoritesManager().getFolderComics('Saved').map((comic) => comic.id),
      unorderedEquals(['alpha', 'beta']),
    );

    await ReadLaterManager().add(asComic(ComicCollectionStore.find('alpha')!));
    await batchAction(tester, 'Read later');
    expect(
      ReadLaterManager().getAll().map((comic) => comic.id),
      unorderedEquals(['alpha', 'beta']),
    );
    expect(find.byTooltip('Multi-Select'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
    'read later menu removes once even when its item changes',
    (tester) async {
      final comic = asComic(ComicCollectionStore.find('alpha')!);
      final type = ComicType.fromKey(comic.sourceKey);
      await ReadLaterManager().addComics([comic]);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          home: const ReadLaterPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Actions'));
      await tester.pumpAndSettle();
      expect(find.text('Add to favorites'), findsOneWidget);
      expect(find.text('In read later'), findsOneWidget);
      ReadLaterManager().remove(comic.id, type);
      await tester.pumpAndSettle();
      await tester.tap(find.text('In read later'));
      await tester.pumpAndSettle();
      expect(ReadLaterManager().isExist(comic.id, type), isFalse);
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets('wide toolbar selects, inverts and cancels without navigation', (
    tester,
  ) async {
    await openPage(tester, width: 900);
    await tester.tap(find.byTooltip('Multi-Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Select All'));
    await tester.pumpAndSettle();
    expect(selectedIds(tester), {'alpha', 'beta', 'gamma'});
    await tester.tap(find.byTooltip('Invert Selection'));
    await tester.pumpAndSettle();
    expect(selectedIds(tester), isEmpty);
    await tester.tap(tile('beta'));
    await tester.pumpAndSettle();
    expect(selectedIds(tester), {'beta'});
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pumpAndSettle();
    expect(selectedIds(tester), isEmpty);
    expect(find.byType(ComicCollectionsPage), findsOneWidget);
    expect(find.byType(ComicPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed batch deletion keeps members and cleans collection records',
    (tester) async {
      const member = Comic(
        'Member',
        '',
        'member',
        null,
        null,
        '',
        'test',
        null,
        null,
      );
      final collections = ComicCollectionStore.all();
      collections.first.members.add(
        CollectionMember(sourceKey: member.sourceKey, comicId: member.id),
      );
      appdata.settings[ComicCollectionStore.settingsKey] = [
        for (final collection in collections) collection.toJson(),
      ];
      final entries = [...collections.map(asComic), member];
      for (final comic in entries) {
        final type = ComicType.fromKey(comic.sourceKey);
        LocalFavoritesManager().addComic(
          'Saved',
          FavoriteItem(
            id: comic.id,
            name: comic.title,
            coverPath: '',
            author: '',
            type: type,
            tags: [],
          ),
        );
        HistoryManager().addHistory(
          History.fromMap({
            'id': comic.id,
            'type': type.value,
            'title': comic.title,
            'ep': 1,
            'page': 1,
          }),
        );
      }
      await ReadLaterManager().addComics(entries);
      await openPage(tester);
      await tester.enterText(find.byType(TextField), 'Volume');
      await tester.tap(find.byTooltip('Multi-Select'));
      await tester.pumpAndSettle();
      await batchAction(tester, 'Select All');
      await batchAction(tester, 'Delete');
      expect(
        find.text('Delete 2 collections? The comics in them are kept.'),
        findsOneWidget,
      );
      expect(ComicCollectionStore.all(), hasLength(3));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(ComicCollectionStore.all(), hasLength(3));
      expect(selectedIds(tester), {'alpha', 'beta'});

      await batchAction(tester, 'Delete');
      await tester.runAsync(() async {
        await tester.tap(find.text('Confirm'));
        await appdata.saveData(false);
      });
      await tester.pumpAndSettle();
      expect(ComicCollectionStore.all().map((collection) => collection.id), [
        'gamma',
      ]);
      expect(
        LocalFavoritesManager()
            .getFolderComics('Saved')
            .map((comic) => comic.id),
        unorderedEquals(['gamma', 'member']),
      );
      expect(
        HistoryManager().getAll().map((comic) => comic.id),
        unorderedEquals(['gamma', 'member']),
      );
      expect(
        ReadLaterManager().getAll().map((comic) => comic.id),
        unorderedEquals(['gamma', 'member']),
      );
      expect(find.byTooltip('Multi-Select'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
    },
  );
}

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_collection_store.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/utils/translations.dart';

const firstComic = Comic(
  'First volume',
  '',
  'one',
  null,
  null,
  '',
  'test',
  null,
  null,
);
const secondComic = Comic(
  'Second volume',
  '',
  'two',
  null,
  null,
  '',
  'test',
  null,
  null,
);

void main() {
  late Directory directory;
  late String originalDataPath;
  late String originalCachePath;
  late String coverPath;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    directory = Directory.systemTemp.createTempSync(
      'venera-collection-picker-',
    );
    originalDataPath = App.dataPath;
    originalCachePath = App.cachePath;
    App.dataPath = directory.path;
    App.cachePath = directory.path;
    await appdata.init();
    await LocalFavoritesManager().init();
    final cover = File('${directory.path}/cover.png');
    final recorder = ui.PictureRecorder();
    Canvas(
      recorder,
    ).drawRect(const Rect.fromLTWH(0, 0, 44, 60), Paint()..color = Colors.blue);
    final picture = recorder.endRecording();
    final image = await picture.toImage(44, 60);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    cover.writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    coverPath = 'file://${cover.path}';
  });

  tearDownAll(() async {
    await appdata.saveData(false);
    LocalFavoritesManager().close();
    App.dataPath = originalDataPath;
    App.cachePath = originalCachePath;
    App.mainNavigatorKey = null;
    directory.deleteSync(recursive: true);
  });

  Map<String, Object> collection(
    String id,
    String name, {
    String displayMode = 'flat',
    String cover = '',
    List<Map<String, String>> members = const [],
  }) => {
    'id': id,
    'name': name,
    'customCover': cover,
    'displayMode': displayMode,
    'members': members,
  };

  setUp(() {
    appdata.settings['language'] = 'en-US';
    appdata.settings[ComicCollectionStore.settingsKey] = [
      collection('alpha', 'Volume Alpha'),
      collection('beta', 'Volume Beta', displayMode: 'tabs'),
    ];
    for (final folder in LocalFavoritesManager().folderNames) {
      LocalFavoritesManager().deleteFolder(folder);
    }
  });

  Future<void> openDialog(
    WidgetTester tester, {
    List<Comic> comics = const [firstComic],
    double width = 320,
    double height = 800,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    App.mainNavigatorKey = App.rootNavigatorKey;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: App.rootNavigatorKey,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddToCollectionDialog(context, comics),
              child: const Text('Open dialog'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();
  }

  final target = find.byKey(const ValueKey('collection-target'));
  final list = find.byKey(const ValueKey('collection-picker-list'));
  Finder option(String id) => find.byKey(ValueKey(id));
  Finder field(String label) => find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );
  Finder getSearch() => find.descendant(
    of: find.byType(AppSearchField),
    matching: find.byType(TextField),
  );

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(target);
    await tester.pumpAndSettle();
    expect(find.text('Select collection'), findsOneWidget);
  }

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(getSearch(), text);
    await tester.pumpAndSettle();
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Confirm'));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'searches a thousand collections lazily and resets scroll on clear',
    (tester) async {
      appdata.settings[ComicCollectionStore.settingsKey] = [
        for (var i = 0; i < 1000; i++)
          collection('item-$i', 'Volume ${i.toString().padLeft(4, '0')}'),
      ];
      await openDialog(tester);
      await openPicker(tester);
      expect(find.text('Collections: 1000'), findsOneWidget);
      expect(option('item-999'), findsNothing);
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .where((text) => text.data?.startsWith('Volume ') ?? false)
            .length,
        lessThan(20),
      );
      final searchTop = tester.getTopLeft(getSearch());
      await tester.drag(list, const Offset(0, -1400));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(getSearch()), searchTop);
      await search(tester, '  vOLumE 0999  ');
      expect(find.text('Collections: 1'), findsOneWidget);
      expect(option('item-999').hitTestable(), findsOneWidget);
      expect(option('item-0'), findsNothing);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(option('item-0').hitTestable(), findsOneWidget);
      expect(find.text('Collections: 1000'), findsOneWidget);
      expect(ComicCollectionStore.all(), hasLength(1000));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'finds member aliases and original titles and keeps creation available',
    (tester) async {
      appdata.settings[ComicCollectionStore.settingsKey] = [
        collection(
          'member-match',
          'Series',
          members: [
            {
              'sourceKey': 'test',
              'comicId': 'member',
              'displayName': 'Season One',
              'cachedTitle': 'Original title',
            },
          ],
        ),
        collection('unrelated', 'Unrelated'),
      ];
      await openDialog(tester);
      await openPicker(tester);
      for (final query in [' season ONE ', 'original TITLE']) {
        await search(tester, query);
        expect(option('member-match'), findsOneWidget);
        expect(option('unrelated'), findsNothing);
      }
      await search(tester, 'no such story');
      expect(find.text('No matching collections'), findsOneWidget);
      expect(option('').hitTestable(), findsOneWidget);
      appdata.settings[ComicCollectionStore.settingsKey] = [];
      ComicCollectionStore.notifyChanged();
      await tester.pumpAndSettle();
      expect(find.text('No collections yet'), findsOneWidget);
      await tester.tap(option(''));
      await tester.pumpAndSettle();
      expect(field('Collection name'), findsOneWidget);
      expect(ComicCollectionStore.all(), isEmpty);
    },
  );

  testWidgets(
    'selects same-name collections by id and cancel preserves the target',
    (tester) async {
      appdata.settings[ComicCollectionStore.settingsKey] = [
        collection('alpha', 'Same title'),
        collection('beta', 'Same title', displayMode: 'tabs'),
      ];
      await openDialog(tester);
      await openPicker(tester);
      await tester.tap(option('beta'));
      await tester.pumpAndSettle();
      expect(field('Collection name'), findsNothing);
      expect(
        tester
            .widget<RadioGroup<CollectionDisplayMode>>(
              find.byType(RadioGroup<CollectionDisplayMode>),
            )
            .groupValue,
        CollectionDisplayMode.tabs,
      );
      await openPicker(tester);
      expect(
        tester
            .widget<Semantics>(
              find
                  .descendant(
                    of: option('beta'),
                    matching: find.byType(Semantics),
                  )
                  .first,
            )
            .properties
            .selected,
        isTrue,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(ComicCollectionStore.find('alpha')!.members, isEmpty);
      expect(
        ComicCollectionStore.find('beta')!.members.single.comicId,
        firstComic.id,
      );
      expect(
        ComicCollectionStore.find('beta')!.displayMode,
        CollectionDisplayMode.tabs,
      );
    },
  );

  testWidgets(
    'reports partial and complete membership and adds only missing comics',
    (tester) async {
      appdata.settings[ComicCollectionStore.settingsKey] = [
        collection(
          'alpha',
          'Volume Alpha',
          members: [
            {
              'sourceKey': 'test',
              'comicId': 'one',
              'cachedTitle': firstComic.title,
            },
          ],
        ),
      ];
      const nested = Comic(
        'Nested',
        '',
        'nested',
        null,
        null,
        '',
        'comic_collection_nested',
        null,
        null,
      );
      await openDialog(
        tester,
        comics: [firstComic, secondComic, firstComic, nested],
      );
      await openPicker(tester);
      expect(find.text('Already included: 1 / 2'), findsOneWidget);
      await tester.tap(option('alpha'));
      await tester.pumpAndSettle();
      await confirm(tester);
      final saved = ComicCollectionStore.find('alpha')!;
      expect(saved.members.map((member) => member.refKey), [
        'test/one',
        'test/two',
      ]);
      expect(saved.displayMode, CollectionDisplayMode.flat);

      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();
      await openPicker(tester);
      expect(find.text('Already in this collection'), findsOneWidget);
      await tester.tap(option('alpha'));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(ComicCollectionStore.find('alpha')!.members, hasLength(2));
    },
  );

  testWidgets(
    'switching between existing and new collections preserves the draft',
    (tester) async {
      await openDialog(tester, comics: [firstComic, secondComic]);
      await tester.enterText(field('Collection name'), 'My new series');
      await openPicker(tester);
      await tester.tap(option('beta'));
      await tester.pumpAndSettle();
      await openPicker(tester);
      await tester.tap(option(''));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('Collection name')).controller!.text,
        'My new series',
      );
      await confirm(tester);
      final saved = ComicCollectionStore.all().last;
      expect(saved.name, 'My new series');
      expect(saved.members.map((member) => member.refKey), [
        'test/one',
        'test/two',
      ]);
      expect(saved.displayMode, CollectionDisplayMode.tabs);
      expect(ComicCollectionStore.find('beta')!.members, isEmpty);
    },
  );

  for (final width in [320.0, 900.0]) {
    testWidgets(
      'long titles and keyboard fit at width $width with larger text',
      (tester) async {
        final longName = List.filled(
          12,
          'Long collection title 合集名称',
        ).join(' ');
        appdata.settings[ComicCollectionStore.settingsKey] = [
          collection('long', longName),
          collection('next', 'Next collection'),
        ];
        await openDialog(tester, width: width, height: 568, textScale: 1.4);
        await openPicker(tester);
        expect(
          tester.getTopLeft(option('next')).dy -
              tester.getBottomLeft(option('long')).dy,
          greaterThanOrEqualTo(8),
        );
        expect(find.byTooltip(longName), findsOneWidget);
        expect(tester.takeException(), isNull);
        await search(tester, 'long');
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        expect(tester.getBottomLeft(list).dy, lessThanOrEqualTo(328));
        expect(tester.getSize(list).height, greaterThan(40));
        expect(getSearch().hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(option('long'));
        await tester.pumpAndSettle();
        expect(option('long').hitTestable(), findsOneWidget);
        await tester.tap(option('long'));
        await tester.pumpAndSettle();
        expect(list, findsNothing);
        expect(field('Collection name'), findsNothing);
        expect(find.text('Confirm').hitTestable(), findsOneWidget);
        expect(
          tester.getBottomLeft(find.text('Confirm')).dy,
          lessThanOrEqualTo(328),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'custom and borrowed covers retain collection identity and broken covers fall back',
    (tester) async {
      // Keep file IO and codec futures in the real async zone.
      await tester.runAsync(() async {
        appdata.settings[ComicCollectionStore.settingsKey] = [
          collection('custom', 'Custom cover', cover: coverPath),
          collection(
            'borrowed',
            'Borrowed cover',
            members: [
              {
                'sourceKey': 'member-source',
                'comicId': 'member',
                'cachedCover': coverPath,
              },
            ],
          ),
          collection(
            'broken',
            'Broken cover',
            cover: 'file://${directory.path}/missing.png',
          ),
        ];
        await openDialog(tester, width: 600, height: 1000);
        await openPicker(tester);
        for (final id in ['custom', 'borrowed', 'broken']) {
          final image = tester.widget<Image>(
            find.descendant(of: option(id), matching: find.byType(Image)),
          );
          final provider =
              (image.image as ResizeImage).imageProvider as CachedImageProvider;
          expect(provider.sourceKey, 'comic_collection_$id');
          expect(provider.cid, id);
          if (id != 'broken') expect(provider.url, coverPath);
          final done = Completer<void>();
          final stream = image.image.resolve(ImageConfiguration.empty);
          final listener = ImageStreamListener(
            (_, _) => done.complete(),
            onError: (_, _) => done.complete(),
          );
          stream.addListener(listener);
          await done.future.timeout(const Duration(seconds: 20));
          stream.removeListener(listener);
          await tester.pumpAndSettle();
          if (id == 'broken') {
            expect(
              find.descendant(
                of: option(id),
                matching: find.byIcon(Icons.collections_bookmark_outlined),
              ),
              findsOneWidget,
            );
          } else {
            expect(
              tester
                  .widget<RawImage>(
                    find.descendant(
                      of: option(id),
                      matching: find.byType(RawImage),
                    ),
                  )
                  .image,
              isNotNull,
            );
          }
        }
        expect(tester.takeException(), isNull);
      });
    },
  );
}

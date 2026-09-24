import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/chapter_duplicates.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_details_page/chapter_order_editor.dart';
import 'package:venera/utils/translations.dart';

void main() {
  const chapters = ComicChapters({'a': 'One', 'c': 'Three', 'b': 'Two'});
  const setting = ChapterOrderPrefs.settingKey;
  late Directory directory;
  late String originalPath;
  late Map<String, dynamic> originalSettings;
  bool? result;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  setUp(() {
    directory = Directory.systemTemp.createTempSync('venera-chapter-editor-');
    originalPath = App.dataPath;
    originalSettings = {
      for (final key in [setting, 'webdav', 'language'])
        key: appdata.settings[key],
    };
    App.dataPath = directory.path;
    appdata.settings[setting] = <String, dynamic>{};
    appdata.settings['webdav'] = <String>[];
    appdata.settings['language'] = 'en-US';
    result = null;
  });

  tearDown(() {
    for (final entry in originalSettings.entries) {
      appdata.settings[entry.key] = entry.value;
    }
    App.dataPath = originalPath;
    directory.deleteSync(recursive: true);
  });

  Future<void> open(
    WidgetTester tester, {
    ComicChapters data = chapters,
    int group = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showChapterOrderEditor(
                  context: context,
                  chapters: data,
                  comicId: 'comic',
                  sourceKey: 'webdav_library_test',
                  initialGroupIndex: group,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  List<String> titles(WidgetTester tester) => tester
      .widgetList<ListTile>(find.byType(ListTile))
      .map((tile) => (tile.title! as Text).data!)
      .toList();

  Future<void> save(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.text('Save'));
      // Wait for the editor's real disk write before pumping route animations.
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
  }

  testWidgets('arrow changes are staged and cancelling preserves saved order', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byTooltip('Move up').at(2));
    await tester.pumpAndSettle();
    expect(titles(tester), ['One', 'Two', 'Three']);
    expect(appdata.settings[setting], isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(appdata.settings[setting], isEmpty);
  });

  testWidgets('dragging and saving persist order, reset also requires save', (
    tester,
  ) async {
    await open(tester);
    final handle = find.byType(ReorderableDragStartListener).at(1);
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    // Move in steps: the list recomputes its insert slot per drag update.
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(titles(tester), ['One', 'Two', 'Three']);
    await save(tester);
    expect(result, isTrue);
    expect(
      ChapterOrderPrefs.orderedIndices(
        chapters,
        'comic',
        'webdav_library_test',
      ),
      [0, 2, 1],
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(titles(tester), ['One', 'Two', 'Three']);
    await tester.tap(find.text('Restore source order'));
    await tester.pumpAndSettle();
    expect(titles(tester), ['One', 'Three', 'Two']);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      ChapterOrderPrefs.orderedIndices(
        chapters,
        'comic',
        'webdav_library_test',
      ),
      [0, 2, 1],
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore source order'));
    await save(tester);
    expect(appdata.settings[setting], isEmpty);
  });

  testWidgets(
    'editing starts in the selected group and preserves other groups',
    (tester) async {
      const grouped = ComicChapters.grouped({
        'English': {'a': 'One', 'b': 'Two'},
        'Chinese': {'a': '一', 'b': '二'},
      });
      await open(tester, data: grouped, group: 1);
      expect(titles(tester), ['一', '二']);
      await tester.tap(find.byTooltip('Move up').at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(titles(tester), ['One', 'Two']);
      await tester.tap(find.byTooltip('Move down').first);
      await tester.pumpAndSettle();
      await save(tester);
      expect(
        ChapterOrderPrefs.orderedIndices(
          grouped,
          'comic',
          'webdav_library_test',
        ),
        [1, 0, 3, 2],
      );

      await open(tester, data: grouped);
      await tester.tap(find.text('Restore source order'));
      await tester.pumpAndSettle();
      expect(titles(tester), ['One', 'Two']);
      await save(tester);
      expect(
        ChapterOrderPrefs.orderedIndices(
          grouped,
          'comic',
          'webdav_library_test',
        ),
        [0, 1, 3, 2],
      );
    },
  );

  testWidgets('narrow screens and long titles keep all controls usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    appdata.settings['language'] = 'zh-CN';
    const longTitle = '第一话：一个很长很长的漫画章节标题，包含特别篇和附录';
    await open(tester, data: const ComicChapters({'a': longTitle, 'b': '第二话'}));
    expect(find.text('自定义章节顺序'), findsOneWidget);
    expect(find.byTooltip('上移'), findsNWidgets(2));
    expect(find.byTooltip('下移'), findsNWidgets(2));
    expect(find.text('保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

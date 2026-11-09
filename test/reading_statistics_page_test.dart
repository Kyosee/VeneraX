import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/pages/reading_statistics_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  late Directory settingsDirectory;
  late String previousDataPath;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
    previousDataPath = App.dataPath;
    settingsDirectory = Directory.systemTemp.createTempSync(
      'venera-statistics-page-',
    );
    App.dataPath = settingsDirectory.path;
  });

  tearDownAll(() {
    App.dataPath = previousDataPath;
    settingsDirectory.deleteSync(recursive: true);
  });

  ReadingStatisticsSummary summary({
    bool withData = true,
    List<ComicReadingStatistics>? comics,
  }) {
    final today = DateTime(2026, 8, 17);
    return ReadingStatisticsSummary(
      today: withData ? const Duration(minutes: 5) : Duration.zero,
      lastSevenDays: withData
          ? const Duration(hours: 1, minutes: 5)
          : Duration.zero,
      total: withData ? const Duration(hours: 2, minutes: 3) : Duration.zero,
      daily: List.generate(
        7,
        (index) => DailyReadingDuration(
          day: DateTime(2026, 8, 11 + index),
          duration: withData && index == 6
              ? const Duration(minutes: 5)
              : Duration.zero,
        ),
      ),
      recentComics: withData
          ? comics ??
                [
                  ComicReadingStatistics(
                    id: 'comic-1',
                    // A non-local type avoids requiring LocalManager just to
                    // render the list tile in this isolated widget test.
                    type: ComicType(1),
                    title:
                        'A long comic title that must fit on a narrow screen',
                    subtitle: 'Subtitle',
                    cover: '',
                    duration: const Duration(hours: 1, minutes: 2),
                    lastReadAt: today,
                  ),
                ]
          : const [],
    );
  }

  ComicReadingStatistics comic(
    String id, {
    required String title,
    String subtitle = '',
    required Duration duration,
    required DateTime lastReadAt,
  }) => ComicReadingStatistics(
    id: id,
    type: ComicType(1),
    title: title,
    subtitle: subtitle,
    cover: '',
    duration: duration,
    lastReadAt: lastReadAt,
  );

  Widget wrap(
    Widget child, {
    Brightness brightness = Brightness.light,
    double textScale = 1,
  }) => MaterialApp(
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.blue,
        brightness: brightness,
      ),
    ),
    builder: (context, content) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: content!,
    ),
    home: child,
  );

  String metric(WidgetTester tester, String key) {
    final text = tester.widget<Text>(find.byKey(Key(key)));
    return text.semanticsLabel ?? text.data ?? text.textSpan!.toPlainText();
  }

  String visibleMetric(WidgetTester tester, String key) {
    final text = tester.widget<Text>(find.byKey(Key(key)));
    return text.data ?? text.textSpan!.toPlainText();
  }

  void expectBottomSheet(WidgetTester tester) {
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.getTopLeft(find.byType(BottomSheet)).dy, greaterThan(0));
  }

  ReadingStatisticsStore createStore() {
    final db = sqlite3.openInMemory();
    addTearDown(db.dispose);
    return ReadingStatisticsStore(db)..ensureSchema();
  }

  void record(
    ReadingStatisticsStore store,
    String id,
    DateTime day,
    int minutes,
  ) => store.recordDuration(
    id: id,
    type: ComicType(1),
    title: id,
    subtitle: '',
    cover: '',
    startedAt: day,
    duration: Duration(minutes: minutes),
  );

  ReadingStatisticsPage storePage(ReadingStatisticsStore store, DateTime now) =>
      ReadingStatisticsPage(
        now: now,
        loadSummary: (start, end) => store.readSummary(
          now: now,
          start: start,
          end: end,
          allTime: start == null,
        ),
      );

  Future<void> tapVisible(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> selectRangeDay(WidgetTester tester, DateTime date) async {
    final dayButtons = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('range-day-');
    });
    final firstKey = tester.widget(dayButtons.first).key! as ValueKey<String>;
    final firstDay = int.parse(firstKey.value.substring('range-day-'.length));
    final current = readingDateFromDayKey(firstDay);
    final delta = (date.year - current.year) * 12 + date.month - current.month;
    for (var count = 0; count < delta.abs(); count++) {
      await tapVisible(
        tester,
        find.byKey(
          Key(
            delta < 0
                ? 'reading-range-previous-month'
                : 'reading-range-next-month',
          ),
        ),
      );
    }
    await tapVisible(
      tester,
      find.byKey(Key('range-day-${readingDayKey(date)}')),
    );
  }

  Future<void> enterRange(
    WidgetTester tester,
    DateTime start,
    DateTime end,
  ) async {
    await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(DateRangePickerDialog), findsNothing);
    await tapVisible(tester, find.byKey(const Key('reading-range-start')));
    await selectRangeDay(tester, start);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('reading-range-apply')))
          .onPressed,
      isNull,
    );
    await selectRangeDay(tester, end);
    await tapVisible(tester, find.byKey(const Key('reading-range-apply')));
    expect(find.byKey(const Key('reading-range-dialog')), findsNothing);
  }

  Future<void> preset(WidgetTester tester, String key) async {
    await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
    await tapVisible(tester, find.byKey(Key(key)));
    await tapVisible(tester, find.byKey(const Key('reading-range-apply')));
  }

  void useNarrowViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('empty statistics keeps range controls and disables clear', (
    tester,
  ) async {
    useNarrowViewport(tester);
    await tester.pumpWidget(
      wrap(ReadingStatisticsPage(summary: summary(withData: false))),
    );
    await tester.pump();

    expect(find.byKey(const Key('reading-statistics-trend')), findsOneWidget);
    expect(find.byKey(const Key('reading-pick-range')), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '0 min');
    await tester.tap(find.byKey(const Key('reading-statistics-more')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    final clear = tester.widget<TextButton>(
      find.byKey(const Key('clear-reading-statistics')),
    );
    expect(clear.onPressed, isNull);
    expect(find.byKey(const Key('reading-statistics-empty')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders summary trend and comics without narrow-screen errors', (
    tester,
  ) async {
    useNarrowViewport(tester);
    await tester.pumpWidget(wrap(ReadingStatisticsPage(summary: summary())));
    await tester.pump();

    expect(find.byKey(const Key('reading-statistics-summary')), findsOneWidget);
    expect(find.byKey(const Key('reading-statistics-trend')), findsOneWidget);
    expect(find.byKey(const Key('reading-comic-1-comic-1')), findsOneWidget);
    expect(find.byKey(const Key('reading-bar-20260817')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear requires confirmation before invoking callback', (
    tester,
  ) async {
    var cleared = false;
    await tester.pumpWidget(
      wrap(
        ReadingStatisticsPage(
          summary: summary(),
          onClear: () => cleared = true,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('reading-statistics-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear-reading-statistics')));
    await tester.pumpAndSettle();
    expectBottomSheet(tester);
    expect(
      find.text(
        'This permanently deletes reading time for every date. Comics, favorites and reading progress are kept.',
      ),
      findsOneWidget,
    );
    expect(cleared, isFalse);
    expect(find.byType(FilledButton), findsOneWidget);

    await tester.tap(find.text('Keep Records'));
    await tester.pumpAndSettle();
    expect(cleared, isFalse);
    await tester.tap(find.byKey(const Key('reading-statistics-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('clear-reading-statistics')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(cleared, isTrue);
  });

  test('formats minute and hour boundaries', () {
    expect(formatReadingDuration(Duration.zero), '0 min');
    expect(
      formatReadingDuration(const Duration(seconds: 59)),
      'Less than a minute',
    );
    expect(formatReadingDuration(const Duration(minutes: 1)), '1 min');
    expect(formatReadingDuration(const Duration(hours: 1)), '1 h');
    expect(
      formatReadingDuration(const Duration(hours: 1, minutes: 1)),
      '1 h 1 min',
    );
  });

  testWidgets('more opens statistics guidance in a bottom sheet', (
    tester,
  ) async {
    useNarrowViewport(tester);
    await tester.pumpWidget(wrap(ReadingStatisticsPage(summary: summary())));
    await tester.tap(find.byKey(const Key('reading-statistics-more')));
    await tester.pumpAndSettle();
    expectBottomSheet(tester);
    expect(find.text('Manage Statistics'), findsOneWidget);
    await tester.tap(find.text('How Statistics Work'));
    await tester.pumpAndSettle();
    expectBottomSheet(tester);
    expect(
      find.text(
        'Daily average includes days without reading. Reading time comes from recorded reading sessions.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('content fills a wide window instead of a fixed body width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(ReadingStatisticsPage(summary: summary())));
    await tester.pump();

    // The approved layout uses 16px page gutters and 18px card padding.
    expect(
      tester.getSize(find.byKey(const Key('reading-statistics-summary'))).width,
      1568,
    );
    expect(
      tester.getSize(find.byKey(const Key('reading-statistics-trend'))).width,
      1532,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('duration stays on one line and is not clipped', (tester) async {
    useNarrowViewport(tester);
    await tester.pumpWidget(wrap(ReadingStatisticsPage(summary: summary())));
    await tester.pump();

    final label = formatReadingDuration(const Duration(hours: 1, minutes: 2));
    final duration = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          (widget.semanticsLabel == label || widget.data == label),
    );
    expect(duration, findsOneWidget);
    expect(tester.widget<Text>(duration).maxLines, 1);

    // The tile used to pin the duration to a fixed 84px, which wrapped values
    // like "2 h 6 min" even with room to spare.
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: duration, matching: find.byType(RichText)),
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sort entry is offered only when statistics exist', (
    tester,
  ) async {
    useNarrowViewport(tester);
    await tester.pumpWidget(
      wrap(ReadingStatisticsPage(summary: summary(withData: false))),
    );
    await tester.pump();
    expect(find.byKey(const Key('sort-reading-statistics')), findsNothing);

    await tester.pumpWidget(wrap(ReadingStatisticsPage(summary: summary())));
    await tester.pump();
    expect(find.byKey(const Key('sort-reading-statistics')), findsOneWidget);

    await tester.longPress(find.byKey(const Key('sort-reading-statistics')));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Reading Time Desc'), findsOneWidget);
    expect(find.text('Name Asc'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('list is rendered in sorted order, not source order', (
    tester,
  ) async {
    final previous = appdata.settings['reading_statistics_sort'];
    appdata.settings['reading_statistics_sort'] = 'last_read';
    addTearDown(() => appdata.settings['reading_statistics_sort'] = previous);
    final comics = [
      comic(
        'a',
        title: 'Bravo',
        duration: const Duration(hours: 3),
        lastReadAt: DateTime(2026, 8, 10),
      ),
      comic(
        'b',
        title: 'Alpha',
        duration: const Duration(minutes: 30),
        lastReadAt: DateTime(2026, 8, 17),
      ),
    ];
    await tester.pumpWidget(
      wrap(ReadingStatisticsPage(summary: summary(comics: comics))),
    );
    await tester.pump();

    // A saved last-read preference takes precedence over the new default.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final recent = tester
        .getTopLeft(find.byKey(const ValueKey('reading-comic-1-b')))
        .dy;
    final older = tester
        .getTopLeft(find.byKey(const ValueKey('reading-comic-1-a')))
        .dy;
    expect(recent, lessThan(older));
  });

  testWidgets('quick sort starts with time first and persists each selection', (
    tester,
  ) async {
    useNarrowViewport(tester);
    final saved = appdata.settings['reading_statistics_sort'];
    final legacy = appdata.implicitData['reading_statistics_sort'];
    appdata.settings['reading_statistics_sort'] = null;
    appdata.implicitData['reading_statistics_sort'] = null;
    addTearDown(() {
      appdata.settings['reading_statistics_sort'] = saved;
      appdata.implicitData['reading_statistics_sort'] = legacy;
    });
    final comics = [
      comic(
        'a',
        title: 'Bravo',
        duration: const Duration(hours: 3),
        lastReadAt: DateTime(2026, 8, 10),
      ),
      comic(
        'b',
        title: 'Alpha',
        duration: const Duration(minutes: 30),
        lastReadAt: DateTime(2026, 8, 17),
      ),
    ];
    await tester.pumpWidget(
      wrap(ReadingStatisticsPage(summary: summary(comics: comics))),
    );
    await tester.pumpAndSettle();
    expect(find.text('Time First'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final a = find.byKey(const Key('reading-comic-1-a'));
    final b = find.byKey(const Key('reading-comic-1-b'));
    expect(tester.getTopLeft(a).dy, lessThan(tester.getTopLeft(b).dy));
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('sort-reading-statistics')));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(find.text('Name Order'), findsOneWidget);
    expect(appdata.settings['reading_statistics_sort'], 'name_asc');
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.getTopLeft(b).dy, lessThan(tester.getTopLeft(a).dy));
    await tester.longPress(find.byKey(const Key('sort-reading-statistics')));
    await tester.pumpAndSettle();
    expectBottomSheet(tester);
    await tester.runAsync(() async {
      await tester.tap(find.text('Last Read'));
      await appdata.saveData(false);
    });
    await tester.pumpAndSettle();
    expect(appdata.settings['reading_statistics_sort'], 'last_read');
    expect(find.text('Last Read'), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comic actions open before navigation and confirm deletion', (
    tester,
  ) async {
    useNarrowViewport(tester);
    var deleted = false;
    await tester.pumpWidget(
      wrap(
        ReadingStatisticsPage(
          summary: summary(),
          onDelete: (_) => deleted = true,
        ),
      ),
    );
    final tile = find.byKey(const Key('reading-comic-1-comic-1'));
    await tapVisible(tester, tile);
    expectBottomSheet(tester);
    expect(find.byKey(const Key('reading-open-comic')), findsOneWidget);
    expect(find.text('Reading in selected period: 1 hr 2 min'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reading-delete-comic')));
    await tester.pumpAndSettle();
    expectBottomSheet(tester);
    expect(deleted, isFalse);
    expect(
      find.text(
        'Delete all reading statistics for this comic, including other dates?',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(deleted, isFalse);
    expect(tile, findsOneWidget);
    await tapVisible(tester, tile);
    await tester.tap(find.byKey(const Key('reading-delete-comic')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(deleted, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('comic actions remain usable after the list item is removed', (
    tester,
  ) async {
    useNarrowViewport(tester);
    final data = ValueNotifier(summary());
    addTearDown(data.dispose);
    ComicReadingStatistics? deleted;
    await tester.pumpWidget(
      wrap(
        ValueListenableBuilder<ReadingStatisticsSummary>(
          valueListenable: data,
          builder: (context, value, child) => ReadingStatisticsPage(
            summary: value,
            onDelete: (comic) => deleted = comic,
          ),
        ),
      ),
    );
    final tile = find.byKey(const Key('reading-comic-1-comic-1'));
    await tapVisible(tester, tile);
    data.value = summary(withData: false);
    await tester.pumpAndSettle();
    expect(tile, findsNothing);
    await tester.tap(find.byKey(const Key('reading-delete-comic')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectBottomSheet(tester);
    expect(find.text('Delete Reading Statistics'), findsOneWidget);
    expect(deleted, isNull);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(deleted?.id, 'comic-1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('hides comics whose author matches a blocked word', (
    tester,
  ) async {
    final previous = appdata.settings['blockedWords'];
    appdata.settings['blockedWords'] = ['Blocked Author'];
    addTearDown(() {
      appdata.settings['blockedWords'] = previous;
    });
    final comics = [
      comic(
        'blocked',
        title: 'Blocked Comic',
        subtitle: 'Blocked Author',
        duration: const Duration(minutes: 30),
        lastReadAt: DateTime(2026, 8, 17),
      ),
      comic(
        'visible',
        title: 'Visible Comic',
        subtitle: 'Visible Author',
        duration: const Duration(minutes: 20),
        lastReadAt: DateTime(2026, 8, 16),
      ),
    ];

    await tester.pumpWidget(
      wrap(ReadingStatisticsPage(summary: summary(comics: comics))),
    );
    await tester.pump();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('reading-comic-1-blocked')), findsNothing);
    expect(
      find.byKey(const ValueKey('reading-comic-1-visible')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('reading-statistics-summary')), findsOneWidget);
    expect(find.byKey(const Key('reading-statistics-trend')), findsOneWidget);
  });

  testWidgets('left swipe exposes single-comic delete action', (tester) async {
    useNarrowViewport(tester);
    ComicReadingStatistics? deleted;
    final target = comic(
      'delete-me',
      title: 'Delete Me',
      duration: const Duration(minutes: 30),
      lastReadAt: DateTime(2026, 8, 17),
    );
    await tester.pumpWidget(
      wrap(
        ReadingStatisticsPage(
          summary: summary(comics: [target]),
          onDelete: (comic) => deleted = comic,
        ),
      ),
    );
    await tester.pump();

    final tile = find.byKey(const ValueKey('reading-comic-1-delete-me'));
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.drag(tile, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(deleted, isNull);
    expect(
      find.text(
        'Delete all reading statistics for this comic, including other dates?',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(deleted, same(target));
  });

  testWidgets(
    'month navigation queries old records and keeps empty months usable',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 1, 15);
      record(store, 'current', now, 5);
      record(store, 'december', DateTime(2025, 12, 31), 2);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await tester.pump();
      expect(metric(tester, 'reading-period-total'), '5 min');
      await tester.tap(find.text('By Month'));
      await tester.pumpAndSettle();
      expect(find.text('January 2026'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('reading-next-period')))
            .onPressed,
        isNull,
      );
      expect(metric(tester, 'reading-active-days'), '1 / 15');
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('reading-day-20260116')))
            .onTap,
        isNull,
      );

      await tester.tap(find.byKey(const Key('reading-previous-period')));
      await tester.pumpAndSettle();
      expect(find.text('December 2025'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '2 min');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reading-comic-1-december')), findsOneWidget);
      expect(find.byKey(const Key('reading-comic-1-current')), findsNothing);
      expect(
        find.byKey(const Key('reading-statistics-calendar')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reading-statistics-trend')), findsNothing);
      expect(find.byTooltip('2025/12/31  2 min'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tapVisible(tester, find.byKey(const Key('reading-day-20251231')));
      expect(metric(tester, 'reading-detail-total'), '2 min');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tapVisible(
        tester,
        find.byKey(const Key('reading-previous-period')),
      );
      expect(find.text('November 2025'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '0 min');
      expect(
        find.text('No comics read in the selected period'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reading-next-period')), findsOneWidget);
      await tester.tap(find.byKey(const Key('reading-pick-month')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reading-month-dialog')), findsOneWidget);
      expect(find.byType(DatePickerDialog), findsNothing);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 500));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Last 7 Days').last);
      expect(find.byKey(const Key('reading-comic-1-current')), findsOneWidget);
      expect(find.byKey(const Key('reading-comic-1-december')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cross-month selection drives totals, daily details and equal-length arrows',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 11, 9);
      record(store, 'before', DateTime(2026, 10, 26), 10);
      record(store, 'first', DateTime(2026, 10, 27), 20);
      record(store, 'october', DateTime(2026, 10, 31), 30);
      record(store, 'last', DateTime(2026, 11, 2), 40);
      record(store, 'outside', DateTime(2026, 11, 3), 50);
      record(store, 'today', now, 60);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await enterRange(tester, DateTime(2026, 10, 27), DateTime(2026, 11, 2));
      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('Oct 27 – Nov 2'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '1 h 30 min');
      expect(metric(tester, 'reading-daily-average'), '12 min');
      expect(visibleMetric(tester, 'reading-daily-average'), '13 minutes');
      expect(metric(tester, 'reading-active-days'), '3 / 7');
      expect(visibleMetric(tester, 'reading-active-days'), '3 days');
      expect(metric(tester, 'reading-comic-count'), '3');
      expect(visibleMetric(tester, 'reading-comic-count'), '3 comics');
      expect(find.byKey(const Key('reading-comic-1-outside')), findsNothing);

      await tapVisible(tester, find.byKey(const Key('reading-bar-20261031')));
      expect(find.text('Oct 31'), findsOneWidget);
      expect(metric(tester, 'reading-detail-total'), '30 min');
      final details = find.byKey(const Key('reading-period-details'));
      expect(
        find.descendant(
          of: details,
          matching: find.byKey(const Key('reading-comic-1-october')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: details,
          matching: find.byKey(const Key('reading-comic-1-first')),
        ),
        findsNothing,
      );
      await tapVisible(
        tester,
        find.descendant(
          of: details,
          matching: find.byKey(const Key('reading-comic-1-october')),
        ),
      );
      expectBottomSheet(tester);
      expect(find.byKey(const Key('reading-open-comic')), findsOneWidget);
      expect(find.text('Reading in selected period: 30 min'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tapVisible(
        tester,
        find.byKey(const Key('reading-previous-period')),
      );
      expect(find.text('Oct 20 – Oct 26'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '10 min');
      expect(metric(tester, 'reading-active-days'), '1 / 7');
      await tester.tap(find.byKey(const Key('reading-next-period')));
      await tester.pumpAndSettle();
      expect(metric(tester, 'reading-period-total'), '1 h 30 min');
      await tester.tap(find.byKey(const Key('reading-next-period')));
      await tester.pumpAndSettle();
      expect(find.text('Last 7 Days'), findsOneWidget);
      expect(find.text('Nov 3 – Nov 9'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('reading-next-period')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('single-day ranges and presets apply only after confirmation', (
    tester,
  ) async {
    useNarrowViewport(tester);
    final store = createStore();
    final now = DateTime(2026, 11, 9);
    record(store, 'old', DateTime(2026, 10, 11), 11);
    record(store, 'yesterday', DateTime(2026, 11, 8), 8);
    record(store, 'today', now, 9);
    await tester.pumpWidget(wrap(storePage(store, now)));
    await enterRange(tester, DateTime(2026, 11, 8), DateTime(2026, 11, 8));
    expect(metric(tester, 'reading-period-total'), '8 min');
    expect(metric(tester, 'reading-daily-average'), '8 min');
    expect(metric(tester, 'reading-active-days'), '1 / 1');

    await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
    await tester.tap(find.byKey(const Key('reading-preset-month')));
    await tester.pumpAndSettle();
    expect(metric(tester, 'reading-period-total'), '8 min');
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Nov 8'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '8 min');

    await preset(tester, 'reading-preset-month');
    expect(find.text('Oct 11 – Nov 9'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '28 min');
    expect(metric(tester, 'reading-active-days'), '3 / 30');
    await preset(tester, 'reading-preset-today');
    expect(find.text('Nov 9'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '9 min');
    expect(metric(tester, 'reading-active-days'), '1 / 1');
    await preset(tester, 'reading-preset-week');
    expect(find.text('Last 7 Days'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '17 min');
    expect(metric(tester, 'reading-active-days'), '2 / 7');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'range sheet disables future days and cancels an unfinished range',
    (tester) async {
      useNarrowViewport(tester);
      final now = DateTime(2026, 11, 9);
      await tester.pumpWidget(wrap(storePage(createStore(), now)));
      await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('range-day-20261110')))
            .onTap,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('reading-range-next-month')),
            )
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.byKey(const Key('range-day-20261108')));
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('reading-range-apply')))
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.byKey(const Key('reading-range-cancel')));
      expect(find.byKey(const Key('reading-range-dialog')), findsNothing);
      expect(find.text('Last 7 Days'), findsOneWidget);
      expect(find.text('Nov 3 – Nov 9'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'month picker selects year and month directly and disables future months',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 11, 9);
      record(store, 'leap-day', DateTime(2024, 2, 29), 29);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await tester.tap(find.text('By Month'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reading-pick-month')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(find.byType(DateRangePickerDialog), findsNothing);
      expectBottomSheet(tester);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('reading-month-2026-12')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const Key('reading-pick-year')));
      await tester.pumpAndSettle();
      expect(find.byType(YearPicker), findsOneWidget);
      await tapVisible(tester, find.text('2024'));
      await tapVisible(tester, find.byKey(const Key('reading-month-2024-2')));
      expect(find.byKey(const Key('reading-month-dialog')), findsNothing);
      expect(find.text('February 2024'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '29 min');
      expect(metric(tester, 'reading-active-days'), '1 / 29');
      expect(find.byKey(const Key('reading-day-20240229')), findsOneWidget);
      expect(find.byKey(const Key('reading-day-20240230')), findsNothing);
      await tapVisible(tester, find.byKey(const Key('reading-pick-month')));
      await tapVisible(tester, find.byKey(const Key('reading-current-month')));
      expect(find.text('November 2026'), findsOneWidget);
      expect(find.byKey(const Key('reading-month-dialog')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'thirty-day trend drills into exact full and partial week boundaries',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 11, 9);
      record(store, 'first', DateTime(2026, 10, 11), 11);
      record(store, 'week-end', DateTime(2026, 10, 17), 17);
      record(store, 'next-week', DateTime(2026, 10, 18), 18);
      record(store, 'last-start', DateTime(2026, 11, 8), 8);
      record(store, 'last-end', now, 9);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await preset(tester, 'reading-preset-month');
      expect(metric(tester, 'reading-period-total'), '1 h 3 min');
      await tapVisible(tester, find.byKey(const Key('reading-bar-20261011')));
      expect(find.text('Oct 11 – Oct 17'), findsOneWidget);
      expect(metric(tester, 'reading-detail-total'), '28 min');
      final details = find.byKey(const Key('reading-period-details'));
      expect(
        find.descendant(
          of: details,
          matching: find.byKey(const Key('reading-comic-1-next-week')),
        ),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('reading-bar-20261108')));
      expect(find.text('Nov 8 – Nov 9'), findsOneWidget);
      expect(metric(tester, 'reading-detail-total'), '17 min');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all-time month bars navigate to months even with fewer than ninety days',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 11, 9);
      record(store, 'first', DateTime(2026, 10, 31), 31);
      record(store, 'november', DateTime(2026, 11, 1), 11);
      record(store, 'today', now, 9);
      record(store, 'future', DateTime(2026, 11, 10), 60);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await tester.tap(find.text('All Time'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reading-pick-range')), findsNothing);
      expect(find.byKey(const Key('reading-pick-month')), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('reading-next-period')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const Key('reading-previous-period')),
            )
            .onPressed,
        isNull,
      );
      expect(metric(tester, 'reading-period-total'), '51 min');
      expect(metric(tester, 'reading-active-days'), '3 / 10');
      expect(metric(tester, 'reading-comic-count'), '3');
      expect(find.byKey(const Key('reading-bar-20261109')), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('reading-all-period')))
            .onPressed,
        isNull,
      );
      await tapVisible(tester, find.byKey(const Key('reading-bar-20261031')));
      expect(find.text('October 2026'), findsOneWidget);
      expect(
        find.byKey(const Key('reading-statistics-calendar')),
        findsOneWidget,
      );
      expect(find.byType(BottomSheet), findsNothing);
      expect(metric(tester, 'reading-period-total'), '31 min');
      expect(metric(tester, 'reading-active-days'), '1 / 31');
      await tapVisible(tester, find.text('All Time'));
      await tapVisible(tester, find.byKey(const Key('reading-bar-20261101')));
      expect(find.text('November 2026'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '20 min');
      expect(metric(tester, 'reading-active-days'), '2 / 9');
      expect(find.byKey(const Key('reading-comic-1-future')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a long custom range uses month bars that open the selected month',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 11, 9);
      record(store, 'before-range', DateTime(2026, 7, 15), 15);
      record(store, 'first', DateTime(2026, 7, 31), 31);
      record(store, 'today', now, 9);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await enterRange(tester, DateTime(2026, 7, 31), now);
      expect(metric(tester, 'reading-period-total'), '40 min');
      expect(metric(tester, 'reading-active-days'), '2 / 102');
      await tapVisible(tester, find.byKey(const Key('reading-bar-20260731')));
      expect(find.text('July 2026'), findsOneWidget);
      expect(
        find.byKey(const Key('reading-statistics-calendar')),
        findsOneWidget,
      );
      expect(metric(tester, 'reading-period-total'), '46 min');
      expect(metric(tester, 'reading-active-days'), '2 / 31');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bars and past calendar dates expose accessible tap actions', (
    tester,
  ) async {
    useNarrowViewport(tester);
    final semantics = tester.ensureSemantics();
    try {
      final now = DateTime(2026, 11, 9);
      final store = createStore();
      record(store, 'today', now, 9);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(find.byKey(const Key('reading-bar-20261109')))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      await tester.tap(find.text('By Month'));
      await tester.pumpAndSettle();
      for (final day in [20261108, 20261109]) {
        expect(
          tester
              .getSemantics(find.byKey(Key('reading-day-$day')))
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
      }
      expect(
        tester
            .getSemantics(find.byKey(const Key('reading-day-20261110')))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'dark narrow layout supports large text, month picker and details',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 11, 9);
      record(
        store,
        'A long title for the accessible narrow statistics layout',
        now,
        69,
      );
      await tester.pumpWidget(
        wrap(
          storePage(store, now),
          brightness: Brightness.dark,
          textScale: 1.6,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('By Month'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tapVisible(tester, find.byKey(const Key('reading-day-20261109')));
      expect(metric(tester, 'reading-detail-total'), '1 h 9 min');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('reading-pick-month')));
      expect(find.byKey(const Key('reading-month-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Last 7 Days'));
      await enterRange(tester, DateTime(2026, 11, 8), now);
      expect(metric(tester, 'reading-period-total'), '1 h 9 min');
      expect(metric(tester, 'reading-active-days'), '1 / 2');
      expect(tester.takeException(), isNull);

      await enterRange(tester, DateTime(2025, 12, 31), DateTime(2026, 1, 2));
      expect(find.text('2025/12/31 – 2026/1/2'), findsOneWidget);
      expect(metric(tester, 'reading-active-days'), '0 / 3');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loads the sort preference from synced settings', (tester) async {
    final previous = appdata.settings['reading_statistics_sort'];
    appdata.settings['reading_statistics_sort'] = 'name_asc';
    addTearDown(() {
      appdata.settings['reading_statistics_sort'] = previous;
    });
    final comics = [
      comic(
        'a',
        title: 'Bravo',
        duration: const Duration(hours: 3),
        lastReadAt: DateTime(2026, 8, 10),
      ),
      comic(
        'b',
        title: 'Alpha',
        duration: const Duration(minutes: 30),
        lastReadAt: DateTime(2026, 8, 17),
      ),
    ];

    await tester.pumpWidget(
      wrap(ReadingStatisticsPage(summary: summary(comics: comics))),
    );
    await tester.pump();

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final alpha = tester
        .getTopLeft(find.byKey(const ValueKey('reading-comic-1-b')))
        .dy;
    final bravo = tester
        .getTopLeft(find.byKey(const ValueKey('reading-comic-1-a')))
        .dy;
    expect(alpha, lessThan(bravo));
    expect(
      (appdata.toJson()['settings'] as Map)['reading_statistics_sort'],
      'name_asc',
    );
  });

  testWidgets(
    'cancelling a full swipe leaves the comic available for deletion',
    (tester) async {
      useNarrowViewport(tester);
      var deleted = false;
      await tester.pumpWidget(
        wrap(
          ReadingStatisticsPage(
            summary: summary(),
            onDelete: (_) => deleted = true,
          ),
        ),
      );
      final tile = find.byKey(const Key('reading-comic-1-comic-1'));
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.drag(tile, const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tester.drag(tile, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.text('Delete Reading Statistics'), findsOneWidget);
      expect(deleted, isFalse);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(tile, findsOneWidget);
      expect(tester.getSize(tile).height, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.drag(tile, const Offset(-120, 0));
      await tester.pumpAndSettle();
      await tester.drag(tile, const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(deleted, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  group('sortComicReadingStatistics', () {
    final longAgo = comic(
      'a',
      title: 'Bravo',
      duration: const Duration(hours: 3),
      lastReadAt: DateTime(2026, 8, 10),
    );
    final recent = comic(
      'b',
      title: 'Alpha',
      duration: const Duration(minutes: 30),
      lastReadAt: DateTime(2026, 8, 17),
    );
    final items = [longAgo, recent];

    List<String> idsOf(ReadingStatisticsSortType type) =>
        sortComicReadingStatistics(items, type).map((e) => e.id).toList();

    test('orders by last read, duration and title', () {
      expect(idsOf(ReadingStatisticsSortType.lastRead), ['b', 'a']);
      expect(idsOf(ReadingStatisticsSortType.durationDesc), ['a', 'b']);
      expect(idsOf(ReadingStatisticsSortType.durationAsc), ['b', 'a']);
      expect(idsOf(ReadingStatisticsSortType.nameAsc), ['b', 'a']);
      expect(idsOf(ReadingStatisticsSortType.nameDesc), ['a', 'b']);
    });

    test('keeps the source list untouched', () {
      sortComicReadingStatistics(items, ReadingStatisticsSortType.nameAsc);
      expect(items.map((e) => e.id), ['a', 'b']);
    });

    test('breaks ties by last read time', () {
      final tied = [
        comic(
          'old',
          title: 'Same',
          duration: const Duration(hours: 1),
          lastReadAt: DateTime(2026, 8, 1),
        ),
        comic(
          'new',
          title: 'Same',
          duration: const Duration(hours: 1),
          lastReadAt: DateTime(2026, 8, 15),
        ),
      ];
      expect(
        sortComicReadingStatistics(
          tied,
          ReadingStatisticsSortType.durationDesc,
        ).map((e) => e.id),
        ['new', 'old'],
      );
    });

    test('unknown stored value falls back to last read', () {
      expect(
        ReadingStatisticsSortType.fromString('nonsense'),
        ReadingStatisticsSortType.lastRead,
      );
      expect(
        ReadingStatisticsSortType.fromString(null),
        ReadingStatisticsSortType.lastRead,
      );
      expect(
        ReadingStatisticsSortType.fromString('name_desc'),
        ReadingStatisticsSortType.nameDesc,
      );
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/pages/reading_statistics_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
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

  String metric(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(Key(key))).data!;

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

  Future<void> enterRange(
    WidgetTester tester,
    DateTime start,
    DateTime end,
  ) async {
    await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    String input(DateTime date) => '${date.month}/${date.day}/${date.year}';
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), input(start));
    await tester.enterText(fields.at(1), input(end));
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsNothing);
  }

  Future<void> preset(WidgetTester tester, String key) async {
    await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View This Period'));
    await tester.pumpAndSettle();
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
    final clear = tester.widget<PopupMenuItem<bool>>(
      find.byKey(const Key('clear-reading-statistics')),
    );
    expect(clear.enabled, isFalse);
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
    expect(cleared, isFalse);
    expect(find.byType(FilledButton), findsOneWidget);

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

  testWidgets('content fills a wide window instead of a fixed body width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrap(ReadingStatisticsPage(summary: summary())));
    await tester.pump();

    // 1600 minus the section's 20px horizontal padding on both sides.
    expect(
      tester.getSize(find.byKey(const Key('reading-statistics-summary'))).width,
      1560,
    );
    expect(
      tester.getSize(find.byKey(const Key('reading-statistics-trend'))).width,
      1520,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('duration stays on one line and is not clipped', (tester) async {
    useNarrowViewport(tester);
    await tester.pumpWidget(wrap(ReadingStatisticsPage(summary: summary())));
    await tester.pump();

    final label = formatReadingDuration(const Duration(hours: 1, minutes: 2));
    final duration = find.text(label);
    expect(duration, findsOneWidget);
    expect(tester.widget<Text>(duration).maxLines, 1);

    // The tile used to pin the duration to a fixed 84px, which wrapped values
    // like "2 h 6 min" even with room to spare.
    final paragraph = tester.renderObject<RenderParagraph>(duration);
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

    await tester.tap(find.byKey(const Key('sort-reading-statistics')));
    await tester.pumpAndSettle();
    expect(find.text('Reading Time Desc'), findsOneWidget);
    expect(find.text('Name Asc'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('list is rendered in sorted order, not source order', (
    tester,
  ) async {
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

    // Default sort is last read first, so 'b' must precede 'a' even though the
    // source list holds the opposite order.
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
      await tester.tap(find.text('Cancel'));
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
      expect(find.text('2026/10/27 – 11/2'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '1 h 30 min');
      expect(metric(tester, 'reading-daily-average'), '12 min');
      expect(metric(tester, 'reading-active-days'), '3 / 7');
      expect(metric(tester, 'reading-comic-count'), '3');
      expect(find.byKey(const Key('reading-comic-1-outside')), findsNothing);

      await tapVisible(tester, find.byKey(const Key('reading-bar-20261031')));
      expect(find.text('2026/10/31'), findsOneWidget);
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
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      await tapVisible(
        tester,
        find.byKey(const Key('reading-previous-period')),
      );
      expect(find.text('2026/10/20 – 10/26'), findsOneWidget);
      expect(metric(tester, 'reading-period-total'), '10 min');
      expect(metric(tester, 'reading-active-days'), '1 / 7');
      await tester.tap(find.byKey(const Key('reading-next-period')));
      await tester.pumpAndSettle();
      expect(metric(tester, 'reading-period-total'), '1 h 30 min');
      await tester.tap(find.byKey(const Key('reading-next-period')));
      await tester.pumpAndSettle();
      expect(find.text('Last 7 Days'), findsOneWidget);
      expect(find.text('2026/11/3 – 11/9'), findsOneWidget);
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
    expect(find.text('2026/11/8'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '8 min');

    await preset(tester, 'reading-preset-month');
    expect(find.text('2026/10/11 – 11/9'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '28 min');
    expect(metric(tester, 'reading-active-days'), '3 / 30');
    await preset(tester, 'reading-preset-today');
    expect(find.text('2026/11/9'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '9 min');
    expect(metric(tester, 'reading-active-days'), '1 / 1');
    await preset(tester, 'reading-preset-week');
    expect(find.text('Last 7 Days'), findsOneWidget);
    expect(metric(tester, 'reading-period-total'), '17 min');
    expect(metric(tester, 'reading-active-days'), '2 / 7');
    expect(tester.takeException(), isNull);
  });

  testWidgets('date input rejects future dates without changing the period', (
    tester,
  ) async {
    useNarrowViewport(tester);
    final now = DateTime(2026, 11, 9);
    await tester.pumpWidget(wrap(storePage(createStore(), now)));
    await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '11/10/2026');
    await tester.enterText(find.byType(TextField).at(1), '11/10/2026');
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Last 7 Days'), findsOneWidget);
    expect(find.text('2026/11/3 – 11/9'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
      expect(find.text('2026/10/11 – 10/17'), findsOneWidget);
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
      expect(find.text('2026/11/8 – 11/9'), findsOneWidget);
      expect(metric(tester, 'reading-detail-total'), '17 min');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all-time monthly buckets use partial calendar bounds and no date picker',
    (tester) async {
      useNarrowViewport(tester);
      final store = createStore();
      final now = DateTime(2026, 11, 9);
      record(store, 'first', DateTime(2026, 7, 31), 31);
      record(store, 'august', DateTime(2026, 8, 1), 8);
      record(store, 'november', DateTime(2026, 11, 1), 11);
      record(store, 'today', now, 9);
      record(store, 'future', DateTime(2026, 11, 10), 60);
      await tester.pumpWidget(wrap(storePage(store, now)));
      await tester.tap(find.text('All Time'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reading-pick-range')), findsNothing);
      expect(find.byKey(const Key('reading-pick-month')), findsNothing);
      expect(find.byKey(const Key('reading-next-period')), findsNothing);
      expect(metric(tester, 'reading-period-total'), '59 min');
      expect(metric(tester, 'reading-active-days'), '4 / 102');
      expect(metric(tester, 'reading-comic-count'), '4');
      await tester.tap(find.text('All Reading Records'));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsNothing);
      await tapVisible(tester, find.byKey(const Key('reading-bar-20260731')));
      expect(find.text('2026/7/31'), findsOneWidget);
      expect(metric(tester, 'reading-detail-total'), '31 min');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('reading-bar-20261101')));
      expect(find.text('2026/11/1 – 11/9'), findsOneWidget);
      expect(metric(tester, 'reading-detail-total'), '20 min');
      final details = find.byKey(const Key('reading-period-details'));
      expect(
        find.descendant(
          of: details,
          matching: find.byKey(const Key('reading-comic-1-future')),
        ),
        findsNothing,
      );
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
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Last 7 Days'));
      await enterRange(tester, DateTime(2026, 11, 8), now);
      expect(metric(tester, 'reading-period-total'), '1 h 9 min');
      expect(metric(tester, 'reading-active-days'), '1 / 2');
      expect(tester.takeException(), isNull);

      await tapVisible(tester, find.byKey(const Key('reading-pick-range')));
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '12/31/2025');
      await tester.enterText(find.byType(TextField).at(1), '1/2/2026');
      await tester.tap(find.byIcon(Icons.calendar_today));
      await tester.pumpAndSettle();
      expect(find.text('Dec 31, 2025'), findsOneWidget);
      expect(find.text('Jan 2, 2026'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('View This Period'));
      await tester.pumpAndSettle();
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

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

  Widget wrap(Widget child) => MaterialApp(home: child);

  void useNarrowViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('empty statistics disables clear and hides data sections', (
    tester,
  ) async {
    useNarrowViewport(tester);
    await tester.pumpWidget(
      wrap(ReadingStatisticsPage(summary: summary(withData: false))),
    );
    await tester.pump();

    final clear = tester.widget<IconButton>(
      find.byKey(const Key('clear-reading-statistics')),
    );
    expect(clear.onPressed, isNull);
    expect(find.byKey(const Key('reading-statistics-empty')), findsOneWidget);
    expect(find.byKey(const Key('reading-statistics-trend')), findsNothing);
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
    expect(find.byKey(const Key('reading-bar-8/17')), findsOneWidget);
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
      1560,
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
      final db = sqlite3.openInMemory();
      addTearDown(db.dispose);
      final store = ReadingStatisticsStore(db)..ensureSchema();
      void record(String id, DateTime day, int minutes) => store.recordDuration(
        id: id,
        type: ComicType(1),
        title: id,
        subtitle: '',
        cover: '',
        startedAt: day,
        duration: Duration(minutes: minutes),
      );
      final now = DateTime(2026, 1, 15);
      record('current', now, 5);
      record('december', DateTime(2025, 12, 31), 2);
      await tester.pumpWidget(
        wrap(
          ReadingStatisticsPage(
            now: now,
            loadSummary: (month) => store.readSummary(now: now, month: month),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Selected Period: 5 min'), findsOneWidget);
      await tester.tap(find.text('By Month'));
      await tester.pumpAndSettle();
      expect(find.text('2026-01'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('reading-next-month')))
            .onPressed,
        isNull,
      );

      await tester.tap(find.byKey(const Key('reading-previous-month')));
      await tester.pumpAndSettle();
      expect(find.text('2025-12'), findsOneWidget);
      expect(find.text('Selected Period: 2 min'), findsOneWidget);
      expect(find.byKey(const Key('reading-comic-1-december')), findsOneWidget);
      expect(find.byKey(const Key('reading-comic-1-current')), findsNothing);
      final lastBar = tester.widget<DecoratedBox>(
        find.byKey(const Key('reading-bar-12/31')),
      );
      final context = tester.element(
        find.byKey(const Key('reading-statistics-trend')),
      );
      expect(
        (lastBar.decoration as BoxDecoration).color,
        Theme.of(context).colorScheme.primary,
      );
      expect(find.byTooltip('2025/12/31  2 min'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('reading-previous-month')));
      await tester.pumpAndSettle();
      expect(find.text('2025-11'), findsOneWidget);
      expect(find.text('Selected Period: 0 min'), findsOneWidget);
      expect(
        find.text('No comics read in the selected period'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('reading-next-month')), findsOneWidget);
      await tester.tap(find.byKey(const Key('reading-pick-month')));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Last 7 Days').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reading-comic-1-current')), findsOneWidget);
      expect(find.byKey(const Key('reading-comic-1-december')), findsNothing);
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

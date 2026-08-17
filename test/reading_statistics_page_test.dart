import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/pages/reading_statistics_page.dart';
import 'package:venera/utils/translations.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  ReadingStatisticsSummary summary({bool withData = true}) {
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
          ? [
              ComicReadingStatistics(
                id: 'comic-1',
                // A non-local type avoids requiring LocalManager just to
                // render the list tile in this isolated widget test.
                type: ComicType(1),
                title: 'A long comic title that must fit on a narrow screen',
                subtitle: 'Subtitle',
                cover: '',
                duration: const Duration(hours: 1, minutes: 2),
                lastReadAt: today,
              ),
            ]
          : const [],
    );
  }

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
}

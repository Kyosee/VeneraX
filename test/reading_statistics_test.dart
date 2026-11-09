import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/reading_statistics.dart';

void main() {
  group('ReadingStatisticsStore', () {
    late CommonDatabase db;
    late ReadingStatisticsStore store;

    setUp(() {
      db = sqlite3.openInMemory();
      store = ReadingStatisticsStore(db)..ensureSchema();
    });

    tearDown(() => db.dispose());

    void record(
      String id,
      DateTime startedAt,
      Duration duration, {
      ComicType? type,
    }) {
      store.recordDuration(
        id: id,
        type: type ?? ComicType(1),
        title: 'Title $id',
        subtitle: 'Subtitle $id',
        cover: 'cover-$id',
        startedAt: startedAt,
        duration: duration,
      );
    }

    test('schema creation is idempotent and keeps rows', () {
      final now = DateTime(2026, 8, 17, 10);
      record('a', now, const Duration(minutes: 2));

      store.ensureSchema();

      expect(db.select('select count(*) from reading_statistics;').first[0], 1);
    });

    test('same comic and day accumulates duration', () {
      final now = DateTime(2026, 8, 17, 10);
      record('a', now, const Duration(minutes: 2));
      record(
        'a',
        now.add(const Duration(hours: 1)),
        const Duration(minutes: 3),
      );

      final summary = store.readSummary(now: now);

      expect(summary.today, const Duration(minutes: 5));
      expect(summary.recentComics.single.duration, const Duration(minutes: 5));
    });

    test('duration crossing midnight is split between days', () {
      final startedAt = DateTime(2026, 8, 16, 23, 59, 30);
      record('a', startedAt, const Duration(minutes: 1));

      final summary = store.readSummary(now: DateTime(2026, 8, 17, 12));

      expect(summary.daily[5].duration, const Duration(seconds: 30));
      expect(summary.daily[6].duration, const Duration(seconds: 30));
      expect(summary.today, const Duration(seconds: 30));
    });

    test(
      'summary separates sources and uses the same seven days for comics',
      () {
        final now = DateTime(2026, 8, 17, 12);
        record('same', now, const Duration(minutes: 2), type: ComicType(1));
        record('same', now, const Duration(minutes: 3), type: ComicType(2));
        record('old', DateTime(2026, 7, 1), const Duration(minutes: 5));
        record(
          'outside-week',
          DateTime(2026, 8, 10),
          const Duration(minutes: 4),
        );
        record('future', DateTime(2026, 8, 18), const Duration(minutes: 6));

        final summary = store.readSummary(now: now);

        expect(summary.today, const Duration(minutes: 5));
        expect(summary.total, const Duration(minutes: 20));
        expect(summary.lastSevenDays, const Duration(minutes: 5));
        expect(summary.periodTotal, const Duration(minutes: 5));
        expect(summary.recentComics, hasLength(2));
      },
    );

    test('historical month includes leap day and excludes adjacent months', () {
      record('before', DateTime(2024, 1, 31, 23), const Duration(minutes: 7));
      record('same', DateTime(2024, 2, 1), const Duration(minutes: 2));
      record(
        'same',
        DateTime(2024, 2, 29, 23, 59, 30),
        const Duration(minutes: 1),
      );
      record(
        'same',
        DateTime(2024, 2, 10),
        const Duration(minutes: 3),
        type: ComicType(2),
      );
      record('after', DateTime(2024, 3, 1), const Duration(minutes: 9));

      final result = store.readSummary(
        now: DateTime(2026, 11, 9),
        month: DateTime(2024, 2, 20),
      );
      expect(result.daily, hasLength(29));
      expect(result.daily.first.day, DateTime(2024, 2, 1));
      expect(result.daily.last.day, DateTime(2024, 2, 29));
      expect(result.daily[1].duration, Duration.zero);
      expect(result.daily.last.duration, const Duration(seconds: 30));
      expect(result.periodTotal, const Duration(minutes: 5, seconds: 30));
      expect(result.recentComics, hasLength(2));
      expect(
        result.recentComics.fold(
          Duration.zero,
          (sum, row) => sum + row.duration,
        ),
        result.periodTotal,
      );
      expect(result.today, Duration.zero);
      expect(result.lastSevenDays, Duration.zero);
    });

    test('historical December and empty month keep exact calendar bounds', () {
      record(
        'previous',
        DateTime(2025, 12, 31, 23, 59),
        const Duration(minutes: 2),
      );
      final december = store.readSummary(
        now: DateTime(2026, 11, 9),
        month: DateTime(2025, 12),
      );
      final january = store.readSummary(
        now: DateTime(2026, 11, 9),
        month: DateTime(2026, 1),
      );
      final empty = store.readSummary(
        now: DateTime(2026, 11, 9),
        month: DateTime(2026, 2),
      );
      expect(december.periodTotal, const Duration(minutes: 1));
      expect(january.periodTotal, const Duration(minutes: 1));
      expect(empty.daily, hasLength(28));
      expect(empty.periodTotal, Duration.zero);
      expect(empty.recentComics, isEmpty);
      expect(empty.total, const Duration(minutes: 2));
    });

    test(
      'custom range crosses years and aggregates only its own comic rows',
      () {
        final now = DateTime(2026, 1, 10);
        record('before', DateTime(2025, 12, 29), const Duration(minutes: 9));
        record('same', DateTime(2025, 12, 30), const Duration(minutes: 2));
        record('same', DateTime(2026, 1, 2), const Duration(minutes: 3));
        record(
          'same',
          DateTime(2026, 1, 1),
          const Duration(minutes: 1),
          type: ComicType(2),
        );
        store.recordDuration(
          id: 'same',
          type: ComicType(1),
          title: 'Latest in range',
          subtitle: 'Updated subtitle',
          cover: 'updated-cover',
          startedAt: DateTime(2026, 1, 2, 12),
          duration: const Duration(minutes: 2),
        );
        record('same', DateTime(2026, 1, 3), const Duration(minutes: 8));

        final result = store.readSummary(
          now: now,
          start: DateTime(2025, 12, 30, 16),
          end: DateTime(2026, 1, 2, 2),
        );

        expect(result.daily.map((day) => readingDayKey(day.day)), [
          20251230,
          20251231,
          20260101,
          20260102,
        ]);
        expect(result.dayCount, 4);
        expect(result.readingDays, 3);
        expect(result.periodTotal, const Duration(minutes: 8));
        expect(result.averageDaily, const Duration(minutes: 2));
        expect(result.recentComics, hasLength(2));
        expect(
          result.recentComics.fold(
            Duration.zero,
            (sum, row) => sum + row.duration,
          ),
          result.periodTotal,
        );
        final firstSource = result.recentComics.singleWhere(
          (c) => c.type.value == 1,
        );
        expect(firstSource.duration, const Duration(minutes: 7));
        expect(firstSource.title, 'Latest in range');
        expect(firstSource.subtitle, 'Updated subtitle');
        expect(firstSource.cover, 'updated-cover');
        expect(firstSource.lastReadAt, DateTime(2026, 1, 2, 12, 2));
      },
    );

    test('custom leap-day and single-day ranges include both boundaries', () {
      record('a', DateTime(2024, 2, 28), const Duration(minutes: 3));
      record('a', DateTime(2024, 2, 29, 12), const Duration(minutes: 6));
      record('a', DateTime(2024, 3, 1), const Duration(minutes: 3));
      final result = store.readSummary(
        now: DateTime(2026, 11, 9),
        start: DateTime(2024, 2, 28),
        end: DateTime(2024, 3, 1),
      );
      expect(result.dayCount, 3);
      expect(result.readingDays, 3);
      expect(result.averageDaily, const Duration(minutes: 4));
      final day = store.readSummary(
        now: DateTime(2026, 11, 9),
        start: DateTime(2024, 2, 29, 23),
        end: DateTime(2024, 2, 29, 1),
      );
      expect(day.daily.single.day, DateTime(2024, 2, 29));
      expect(day.periodTotal, const Duration(minutes: 6));
      expect(day.averageDaily, day.periodTotal);
    });

    test('range and current month stop at today and ignore future records', () {
      final now = DateTime(2026, 11, 9, 15);
      record('yesterday', DateTime(2026, 11, 8), const Duration(minutes: 2));
      record('today', now, const Duration(minutes: 3));
      record('future', DateTime(2026, 11, 10), const Duration(minutes: 7));
      final range = store.readSummary(
        now: now,
        start: DateTime(2026, 11, 8),
        end: DateTime(2026, 11, 12),
      );
      expect(range.dayCount, 2);
      expect(range.daily.last.day, DateTime(2026, 11, 9));
      expect(range.periodTotal, const Duration(minutes: 5));
      expect(range.averageDaily, const Duration(minutes: 2, seconds: 30));
      expect(
        range.recentComics.map((c) => c.id),
        containsAll(['yesterday', 'today']),
      );
      expect(range.recentComics.map((c) => c.id), isNot(contains('future')));
      final month = store.readSummary(now: now, month: DateTime(2026, 11));
      expect(month.dayCount, 9);
      expect(month.readingDays, 2);
      expect(month.periodTotal, range.periodTotal);
      expect(month.averageDaily.inMilliseconds, 300000 ~/ 9);
    });

    test(
      'all time starts at first recorded day and retains zero reading days',
      () {
        final now = DateTime(2026, 11, 9);
        record('same', DateTime(2026, 10, 31), const Duration(minutes: 20));
        record('same', now, const Duration(minutes: 30), type: ComicType(2));
        record('future', DateTime(2026, 11, 10), const Duration(minutes: 60));
        final result = store.readSummary(now: now, allTime: true);
        expect(result.dayCount, 10);
        expect(result.daily.first.day, DateTime(2026, 10, 31));
        expect(result.daily.last.day, now);
        expect(result.readingDays, 2);
        expect(result.periodTotal, const Duration(minutes: 50));
        expect(result.averageDaily, const Duration(minutes: 5));
        expect(result.recentComics, hasLength(2));
        expect(
          result.recentComics.fold(
            Duration.zero,
            (sum, row) => sum + row.duration,
          ),
          result.periodTotal,
        );
      },
    );

    test('empty all-time and future-only data use a single zero day', () {
      final now = DateTime(2026, 11, 9);
      void expectEmpty(ReadingStatisticsSummary result) {
        expect(result.daily.single.day, now);
        expect(result.periodTotal, Duration.zero);
        expect(result.readingDays, 0);
        expect(result.averageDaily, Duration.zero);
        expect(result.recentComics, isEmpty);
      }

      expectEmpty(store.readSummary(now: now, allTime: true));
      expectEmpty(ReadingStatisticsSummary.empty(now, allTime: true));
      record('future', DateTime(2026, 11, 10), const Duration(minutes: 1));
      expectEmpty(store.readSummary(now: now, allTime: true));
    });

    test('empty summaries share normalized bounds and day-count semantics', () {
      final now = DateTime(2026, 11, 9, 12);
      expect(ReadingStatisticsSummary.empty(now).dayCount, 7);
      final month = ReadingStatisticsSummary.empty(
        now,
        month: DateTime(2026, 11),
      );
      expect(month.dayCount, 9);
      final range = ReadingStatisticsSummary.empty(
        now,
        start: DateTime(2024, 2, 28, 12),
        end: DateTime(2024, 3, 1, 12),
      );
      expect(range.daily.map((day) => readingDayKey(day.day)), [
        20240228,
        20240229,
        20240301,
      ]);
      expect(range.averageDaily, Duration.zero);
      final emptyDaily = ReadingStatisticsSummary(
        today: Duration.zero,
        lastSevenDays: Duration.zero,
        total: Duration.zero,
        daily: const [],
        recentComics: const [],
      );
      expect(emptyDaily.averageDaily, Duration.zero);
    });

    test('average includes non-reading days at millisecond precision', () {
      final now = DateTime(2026, 11, 9);
      record('a', now, const Duration(milliseconds: 1001));
      final result = store.readSummary(
        now: now,
        start: DateTime(2026, 11, 8),
        end: now,
      );
      expect(result.dayCount, 2);
      expect(result.readingDays, 1);
      expect(result.averageDaily, const Duration(milliseconds: 500));
    });

    test('rejects incomplete, conflicting, reversed, and future ranges', () {
      final now = DateTime(2026, 11, 9);
      final tomorrow = DateTime(2026, 11, 10);
      for (final read in <ReadingStatisticsSummary Function()>[
        () => store.readSummary(now: now, start: now),
        () => store.readSummary(now: now, end: now),
        () => store.readSummary(now: now, month: now, start: now, end: now),
        () => store.readSummary(now: now, allTime: true, month: now),
        () => store.readSummary(now: now, allTime: true, start: now, end: now),
        () =>
            store.readSummary(now: now, start: now, end: DateTime(2026, 11, 8)),
        () => store.readSummary(now: now, start: tomorrow, end: tomorrow),
        () => store.readSummary(now: now, month: DateTime(2026, 12)),
        () => ReadingStatisticsSummary.empty(now, start: now),
        () => ReadingStatisticsSummary.empty(now, allTime: true, month: now),
        () =>
            ReadingStatisticsSummary.empty(now, start: tomorrow, end: tomorrow),
      ]) {
        expect(read, throwsArgumentError);
      }
    });

    test('clear removes statistics only', () {
      db.execute('create table history (id text primary key, hidden int);');
      db.execute("insert into history values ('keep', 1);");
      record('a', DateTime(2026, 8, 17), const Duration(minutes: 2));

      store.clear();

      expect(db.select('select count(*) from reading_statistics;').first[0], 0);
      expect(db.select('select id from history;').first['id'], 'keep');
    });

    test('remove deletes every day for only the matching comic and type', () {
      final now = DateTime(2026, 8, 17, 10);
      record('target', now, const Duration(minutes: 2));
      record(
        'target',
        now.subtract(const Duration(days: 1)),
        const Duration(minutes: 3),
      );
      record('target', now, const Duration(minutes: 4), type: ComicType(2));
      record('keep', now, const Duration(minutes: 5));

      store.remove('target', ComicType(1));

      final summary = store.readSummary(now: now);
      expect(summary.total, const Duration(minutes: 9));
      expect(summary.recentComics, hasLength(2));
      expect(
        summary.recentComics.map((comic) => (comic.id, comic.type.value)),
        containsAll([('target', 2), ('keep', 1)]),
      );
    });
  });

  group('ReadingTimeTracker', () {
    late DateTime wallTime;
    late Duration elapsed;
    late ReadingTimeTracker tracker;

    setUp(() {
      wallTime = DateTime(2026, 8, 17, 10);
      elapsed = Duration.zero;
      tracker = ReadingTimeTracker(
        wallNow: () => wallTime,
        elapsedNow: () => elapsed,
      );
    });

    test('checkpoints only active elapsed time without duplication', () {
      tracker.start();
      elapsed = const Duration(seconds: 30);
      final first = tracker.checkpoint()!;
      elapsed = const Duration(seconds: 45);
      final second = tracker.stop()!;

      expect(first.startedAt, wallTime);
      expect(first.duration, const Duration(seconds: 30));
      expect(second.startedAt, wallTime.add(const Duration(seconds: 30)));
      expect(second.duration, const Duration(seconds: 15));
      expect(tracker.stop(), isNull);
    });

    test('pause and resume exclude inactive time', () {
      tracker.start();
      elapsed = const Duration(seconds: 10);
      expect(tracker.stop()!.duration, const Duration(seconds: 10));

      wallTime = wallTime.add(const Duration(minutes: 5));
      elapsed = const Duration(minutes: 5, seconds: 10);
      tracker.start();
      elapsed = const Duration(minutes: 5, seconds: 30);
      final resumed = tracker.stop()!;

      expect(resumed.startedAt, wallTime);
      expect(resumed.duration, const Duration(seconds: 20));
    });
  });
}

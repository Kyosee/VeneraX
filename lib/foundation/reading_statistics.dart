import 'package:sqlite3/common.dart';

import 'comic_type.dart';

class ReadingDurationBucket {
  const ReadingDurationBucket({
    required this.startedAt,
    required this.duration,
  });

  final DateTime startedAt;
  final Duration duration;

  int get day => readingDayKey(startedAt);
}

class DailyReadingDuration {
  const DailyReadingDuration({required this.day, required this.duration});

  final DateTime day;
  final Duration duration;
}

class ComicReadingStatistics {
  const ComicReadingStatistics({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.cover,
    required this.duration,
    required this.lastReadAt,
  });

  final String id;
  final ComicType type;
  final String title;
  final String subtitle;
  final String cover;
  final Duration duration;
  final DateTime lastReadAt;

  ComicReadingStatistics add(Duration value) => ComicReadingStatistics(
    id: id,
    type: type,
    title: title,
    subtitle: subtitle,
    cover: cover,
    duration: duration + value,
    lastReadAt: lastReadAt,
  );
}

enum ReadingStatisticsSortType {
  lastRead("last_read"),
  durationDesc("duration_desc"),
  durationAsc("duration_asc"),
  nameAsc("name_asc"),
  nameDesc("name_desc");

  const ReadingStatisticsSortType(this.value);

  final String value;

  static ReadingStatisticsSortType fromString(String? value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return lastRead;
  }
}

/// Orders the per-comic rows for display. Ties fall back to last-read time so
/// the order stays stable when durations or titles match.
List<ComicReadingStatistics> sortComicReadingStatistics(
  List<ComicReadingStatistics> comics,
  ReadingStatisticsSortType sortType,
) {
  final result = comics.toList();
  int byLastRead(ComicReadingStatistics a, ComicReadingStatistics b) =>
      b.lastReadAt.compareTo(a.lastReadAt);
  result.sort((a, b) {
    final primary = switch (sortType) {
      ReadingStatisticsSortType.lastRead => byLastRead(a, b),
      ReadingStatisticsSortType.durationDesc => b.duration.compareTo(
        a.duration,
      ),
      ReadingStatisticsSortType.durationAsc => a.duration.compareTo(b.duration),
      ReadingStatisticsSortType.nameAsc => a.title.compareTo(b.title),
      ReadingStatisticsSortType.nameDesc => b.title.compareTo(a.title),
    };
    return primary != 0 ? primary : byLastRead(a, b);
  });
  return result;
}

class ReadingStatisticsSummary {
  const ReadingStatisticsSummary({
    required this.today,
    required this.lastSevenDays,
    required this.total,
    required this.daily,
    required this.recentComics,
  });

  final Duration today;
  final Duration lastSevenDays;
  final Duration total;
  final List<DailyReadingDuration> daily;
  final List<ComicReadingStatistics> recentComics;

  Duration get periodTotal =>
      daily.fold(Duration.zero, (total, day) => total + day.duration);

  int get dayCount => daily.length;

  int get readingDays =>
      daily.where((day) => day.duration > Duration.zero).length;

  Duration get averageDaily => dayCount == 0
      ? Duration.zero
      : Duration(milliseconds: periodTotal.inMilliseconds ~/ dayCount);

  factory ReadingStatisticsSummary.empty(
    DateTime now, {
    DateTime? month,
    DateTime? start,
    DateTime? end,
    bool allTime = false,
  }) {
    final period = _readingPeriod(
      now,
      month: month,
      start: start,
      end: end,
      allTime: allTime,
    );
    return ReadingStatisticsSummary(
      today: Duration.zero,
      lastSevenDays: Duration.zero,
      total: Duration.zero,
      daily: List.generate(_readingDayCount(period.start, period.end), (index) {
        return DailyReadingDuration(
          day: DateTime(
            period.start.year,
            period.start.month,
            period.start.day + index,
          ),
          duration: Duration.zero,
        );
      }),
      recentComics: const [],
    );
  }
}

DateTime _readingDateOnly(DateTime value) {
  final local = value.toLocal();
  return DateTime(local.year, local.month, local.day);
}

({DateTime start, DateTime end}) _readingPeriod(
  DateTime now, {
  DateTime? month,
  DateTime? start,
  DateTime? end,
  bool allTime = false,
  DateTime? firstDay,
}) {
  if ((start == null) != (end == null)) {
    throw ArgumentError('Both start and end are required for a date range.');
  }
  if ((month != null && (start != null || allTime)) ||
      (allTime && start != null)) {
    throw ArgumentError('Choose a month, date range, or all time.');
  }
  final today = _readingDateOnly(now);
  final from = start != null
      ? _readingDateOnly(start)
      : month != null
      ? DateTime(month.year, month.month)
      : allTime
      ? firstDay ?? today
      : DateTime(today.year, today.month, today.day - 6);
  final requestedEnd = end != null
      ? _readingDateOnly(end)
      : month != null
      ? DateTime(month.year, month.month + 1, 0)
      : today;
  if (from.isAfter(requestedEnd) || from.isAfter(today)) {
    throw ArgumentError('The range must start no later than its end or today.');
  }
  return (start: from, end: requestedEnd.isAfter(today) ? today : requestedEnd);
}

// UTC calendar dates count days without daylight-saving offsets.
int _readingDayCount(DateTime start, DateTime end) =>
    DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
    1;

int readingDayKey(DateTime value) =>
    value.year * 10000 + value.month * 100 + value.day;

DateTime readingDateFromDayKey(int value) =>
    DateTime(value ~/ 10000, (value % 10000) ~/ 100, value % 100);

List<ReadingDurationBucket> splitReadingDurationByDay(
  DateTime startedAt,
  Duration duration,
) {
  if (duration <= Duration.zero) return const [];
  final result = <ReadingDurationBucket>[];
  var cursor = startedAt;
  var remaining = duration;
  while (remaining > Duration.zero) {
    final nextDay = cursor.isUtc
        ? DateTime.utc(cursor.year, cursor.month, cursor.day + 1)
        : DateTime(cursor.year, cursor.month, cursor.day + 1);
    final untilNextDay = nextDay.difference(cursor);
    final piece = remaining < untilNextDay ? remaining : untilNextDay;
    if (piece > Duration.zero) {
      result.add(ReadingDurationBucket(startedAt: cursor, duration: piece));
    }
    cursor = cursor.add(piece);
    remaining -= piece;
  }
  return result;
}

class ReadingStatisticsStore {
  ReadingStatisticsStore(this.db);

  final CommonDatabase db;

  void ensureSchema() {
    db.execute('''
      create table if not exists reading_statistics (
        day int not null,
        id text not null,
        type int not null,
        title text not null,
        subtitle text not null,
        cover text not null,
        duration_ms int not null default 0,
        last_read_time int not null,
        primary key (day, id, type)
      );
    ''');
    db.execute('''
      create index if not exists reading_statistics_last_read_idx
      on reading_statistics(last_read_time desc);
    ''');
  }

  void recordDuration({
    required String id,
    required ComicType type,
    required String title,
    required String subtitle,
    required String cover,
    required DateTime startedAt,
    required Duration duration,
  }) {
    final buckets = splitReadingDurationByDay(
      startedAt,
      duration,
    ).where((bucket) => bucket.duration.inMilliseconds > 0).toList();
    if (buckets.isEmpty) return;
    db.execute('BEGIN TRANSACTION;');
    try {
      for (final bucket in buckets) {
        db.execute(
          '''
          insert into reading_statistics (
            day, id, type, title, subtitle, cover, duration_ms, last_read_time
          ) values (?, ?, ?, ?, ?, ?, ?, ?)
          on conflict(day, id, type) do update set
            title = excluded.title,
            subtitle = excluded.subtitle,
            cover = excluded.cover,
            duration_ms = duration_ms + excluded.duration_ms,
            last_read_time = max(last_read_time, excluded.last_read_time);
          ''',
          [
            bucket.day,
            id,
            type.value,
            title,
            subtitle,
            cover,
            bucket.duration.inMilliseconds,
            bucket.startedAt.add(bucket.duration).millisecondsSinceEpoch,
          ],
        );
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }

  ReadingStatisticsSummary readSummary({
    DateTime? now,
    DateTime? month,
    DateTime? start,
    DateTime? end,
    bool allTime = false,
  }) {
    final current = now ?? DateTime.now();
    final today = _readingDateOnly(current);
    final sevenDayStart = DateTime(today.year, today.month, today.day - 6);
    final todayKey = readingDayKey(today);
    final firstDay = allTime
        ? db.select('select min(day) from reading_statistics where day <= ?;', [
                todayKey,
              ]).first[0]
              as int?
        : null;
    final period = _readingPeriod(
      current,
      month: month,
      start: start,
      end: end,
      allTime: allTime,
      firstDay: firstDay == null ? null : readingDateFromDayKey(firstDay),
    );
    final sevenDayKey = readingDayKey(sevenDayStart);
    final startKey = readingDayKey(period.start);
    final endKey = readingDayKey(period.end);

    final dailyRows = db.select(
      '''
      select day, sum(duration_ms) as duration_ms
      from reading_statistics
      where day >= ? and day <= ?
      group by day;
      ''',
      [startKey, endKey],
    );
    final dailyValues = <int, Duration>{
      for (final row in dailyRows)
        row['day'] as int: Duration(
          milliseconds: (row['duration_ms'] as num).toInt(),
        ),
    };
    final daily = List.generate(_readingDayCount(period.start, period.end), (
      index,
    ) {
      final day = DateTime(
        period.start.year,
        period.start.month,
        period.start.day + index,
      );
      return DailyReadingDuration(
        day: day,
        duration: dailyValues[readingDayKey(day)] ?? Duration.zero,
      );
    });

    final recentRows = db.select(
      '''
      select id, type, title, subtitle, cover, duration_ms, last_read_time
      from reading_statistics
      where day >= ? and day <= ?
      order by last_read_time desc;
      ''',
      [startKey, endKey],
    );
    final recentComics = <String, ComicReadingStatistics>{};
    for (final row in recentRows) {
      final type = ComicType(row['type'] as int);
      final key = '${type.value}:${row['id']}';
      final duration = Duration(
        milliseconds: (row['duration_ms'] as num).toInt(),
      );
      final existing = recentComics[key];
      if (existing == null) {
        recentComics[key] = ComicReadingStatistics(
          id: row['id'] as String,
          type: type,
          title: row['title'] as String,
          subtitle: row['subtitle'] as String,
          cover: row['cover'] as String,
          duration: duration,
          lastReadAt: DateTime.fromMillisecondsSinceEpoch(
            row['last_read_time'] as int,
          ),
        );
      } else {
        recentComics[key] = existing.add(duration);
      }
    }

    Duration sum({int? fromDay, int? onlyDay}) {
      final where = onlyDay != null
          ? 'where day = ?'
          : fromDay != null
          ? 'where day >= ? and day <= ?'
          : '';
      final args = onlyDay != null
          ? <Object?>[onlyDay]
          : fromDay != null
          ? <Object?>[fromDay, todayKey]
          : const <Object?>[];
      final value = db
          .select(
            'select sum(duration_ms) as duration_ms from reading_statistics $where;',
            args,
          )
          .first['duration_ms'];
      return Duration(milliseconds: value == null ? 0 : (value as num).toInt());
    }

    return ReadingStatisticsSummary(
      today: sum(onlyDay: todayKey),
      lastSevenDays: sum(fromDay: sevenDayKey),
      total: sum(),
      daily: daily,
      recentComics: recentComics.values.toList(growable: false),
    );
  }

  void remove(String id, ComicType type) {
    db.execute('delete from reading_statistics where id = ? and type = ?;', [
      id,
      type.value,
    ]);
  }

  void clear() => db.execute('delete from reading_statistics;');
}

class ReadingTimeSlice {
  const ReadingTimeSlice({required this.startedAt, required this.duration});

  final DateTime startedAt;
  final Duration duration;
}

class ReadingTimeTracker {
  ReadingTimeTracker({
    DateTime Function()? wallNow,
    Duration Function()? elapsedNow,
  }) : _wallNow = wallNow ?? DateTime.now,
       _elapsedNow = elapsedNow ?? _defaultElapsedNow;

  static final Stopwatch _clock = Stopwatch()..start();

  static Duration _defaultElapsedNow() => _clock.elapsed;

  final DateTime Function() _wallNow;
  final Duration Function() _elapsedNow;

  bool _active = false;
  late DateTime _segmentStartedAt;
  late Duration _segmentStartedElapsed;
  late Duration _lastCheckpointElapsed;

  bool get isActive => _active;

  void start() {
    if (_active) return;
    _segmentStartedAt = _wallNow();
    _segmentStartedElapsed = _elapsedNow();
    _lastCheckpointElapsed = _segmentStartedElapsed;
    _active = true;
  }

  ReadingTimeSlice? checkpoint() {
    if (!_active) return null;
    final elapsed = _elapsedNow();
    final duration = elapsed - _lastCheckpointElapsed;
    if (duration <= Duration.zero) return null;
    final startedAt = _segmentStartedAt.add(
      _lastCheckpointElapsed - _segmentStartedElapsed,
    );
    _lastCheckpointElapsed = elapsed;
    return ReadingTimeSlice(startedAt: startedAt, duration: duration);
  }

  ReadingTimeSlice? stop() {
    if (!_active) return null;
    final result = checkpoint();
    _active = false;
    return result;
  }
}

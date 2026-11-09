import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/reading_statistics.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

import 'reading_statistics_date_picker.dart';

const _sortKey = 'reading_statistics_sort';

enum _ReadingRange { recent, month, allTime }

Comic _readingStatisticsComic(ComicReadingStatistics comic) => Comic(
  comic.title,
  comic.cover,
  comic.id,
  comic.subtitle,
  null,
  '',
  comic.type.sourceKey,
  null,
  null,
);

class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({
    super.key,
    this.summary,
    this.onClear,
    this.onDelete,
    this.now,
    this.loadSummary,
  });

  /// Test seams avoid opening the history database in widget tests.
  final ReadingStatisticsSummary? summary;
  final VoidCallback? onClear;
  final ValueChanged<ComicReadingStatistics>? onDelete;
  final DateTime? now;

  /// Null boundaries request all time; otherwise both dates are inclusive.
  final ReadingStatisticsSummary Function(DateTime? start, DateTime? end)?
  loadSummary;

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  late ReadingStatisticsSortType sortType;
  _ReadingRange _range = _ReadingRange.recent;
  late DateTime _month;
  DateTimeRange? _customRange;

  DateTime get _now => widget.now ?? DateTime.now();
  DateTime get _today => DateUtils.dateOnly(_now);
  DateTime get _currentMonth => DateTime(_today.year, _today.month);
  DateTimeRange get _recent => DateTimeRange(
    start: DateTime(_today.year, _today.month, _today.day - 6),
    end: _today,
  );

  DateTimeRange? get _period {
    if (_range == _ReadingRange.allTime) return null;
    if (_range == _ReadingRange.recent) return _customRange ?? _recent;
    final last = DateTime(_month.year, _month.month + 1, 0);
    return DateTimeRange(
      start: _month,
      end: last.isAfter(_today) ? _today : last,
    );
  }

  @override
  void initState() {
    super.initState();
    _month = _currentMonth;
    final syncedValue = appdata.settings[_sortKey];
    final storedValue = syncedValue ?? appdata.implicitData[_sortKey];
    sortType = ReadingStatisticsSortType.fromString(storedValue?.toString());
    if (syncedValue == null && storedValue != null) {
      appdata.settings[_sortKey] = sortType.value;
      unawaited(appdata.saveData());
    }
  }

  ReadingStatisticsSummary _load(DateTimeRange? period) {
    if (widget.loadSummary != null) {
      return widget.loadSummary!(period?.start, period?.end);
    }
    if (widget.summary != null) return widget.summary!;
    return HistoryManager().getReadingStatistics(
      now: _now,
      start: period?.start,
      end: period?.end,
      allTime: period == null,
    );
  }

  List<ComicReadingStatistics> _comics(ReadingStatisticsSummary data) =>
      sortComicReadingStatistics(
        data.recentComics
            .where((comic) => isBlocked(_readingStatisticsComic(comic)) == null)
            .toList(),
        sortType,
      );

  @override
  Widget build(BuildContext context) {
    if (widget.summary != null || widget.loadSummary != null) {
      return _buildPage(context, _load(_period));
    }
    return ListenableBuilder(
      listenable: HistoryManager(),
      builder: (context, _) => _buildPage(context, _load(_period)),
    );
  }

  Widget _buildPage(BuildContext context, ReadingStatisticsSummary data) {
    final comics = _comics(data);
    return Scaffold(
      backgroundColor: context.colorScheme.surfaceContainerLow,
      body: CustomScrollView(
        slivers: [
          SliverAppbar(
            title: Text('Reading Statistics'.tl),
            actions: [
              PopupMenuButton<bool>(
                key: const Key('reading-statistics-more'),
                tooltip: 'More'.tl,
                icon: const Icon(Icons.more_horiz),
                onSelected: (_) => _confirmClear(context),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    key: const Key('clear-reading-statistics'),
                    value: true,
                    enabled: data.total > Duration.zero,
                    child: Text('Clear Reading Statistics'.tl),
                  ),
                ],
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: _PageSection(
              top: 8,
              child: Column(
                children: [
                  _buildTabs(),
                  const SizedBox(height: 8),
                  _buildDateNavigation(),
                  const SizedBox(height: 8),
                  _StatisticsCard(
                    data: data,
                    month: _range == _ReadingRange.month ? _month : null,
                    today: _today,
                    onSelect: _showPeriodDetails,
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _PageSection(
              top: 20,
              bottom: 8,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Comics Read'.tl,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (comics.isNotEmpty)
                    TextButton.icon(
                      key: const Key('sort-reading-statistics'),
                      onPressed: _showSortDialog,
                      icon: const Icon(Icons.sort, size: 18),
                      label: Text('Sort'.tl),
                    ),
                ],
              ),
            ),
          ),
          if (comics.isEmpty)
            SliverToBoxAdapter(
              child: _PageSection(
                top: 0,
                child: Padding(
                  key: const Key('reading-statistics-empty'),
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Column(
                    children: [
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 36,
                        color: context.colorScheme.outline,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        (data.total == Duration.zero
                                ? 'No reading statistics yet'
                                : 'No comics read in the selected period')
                            .tl,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: comics.length,
              itemBuilder: (context, index) => _PageSection(
                top: 0,
                child: _RecentComicTile(
                  comic: comics[index],
                  total: data.periodTotal,
                  onDelete: _removeReadingStatisticsForComic,
                  onOpen: _openComic,
                ),
              ),
            ),
          if (comics.length != data.recentComics.length)
            SliverToBoxAdapter(
              child: _PageSection(
                child: Text(
                  'Blocked comics are hidden from this list'.tl,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 24),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() => DecoratedBox(
    decoration: BoxDecoration(
      color: context.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Padding(
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final range in _ReadingRange.values)
            Expanded(
              child: Semantics(
                selected: _range == range,
                child: TextButton(
                  onPressed: () => setState(() => _range = range),
                  style: TextButton.styleFrom(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    backgroundColor: _range == range
                        ? context.colorScheme.surface
                        : Colors.transparent,
                    foregroundColor: _range == range
                        ? context.colorScheme.onSurface
                        : context.colorScheme.onSurfaceVariant,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 12,
                    ),
                  ),
                  child: Text(switch (range) {
                    _ReadingRange.recent =>
                      (_customRange == null ? 'Last 7 Days' : 'Custom').tl,
                    _ReadingRange.month => 'By Month'.tl,
                    _ReadingRange.allTime => 'All Time'.tl,
                  }, textAlign: TextAlign.center),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _buildDateNavigation() {
    final period = _period;
    if (period == null) {
      return SizedBox(
        height: 48,
        child: Center(child: Text('All Reading Records'.tl)),
      );
    }
    final monthly = _range == _ReadingRange.month;
    final days = _dayCount(period.start, period.end);
    final nextEnd = _shiftDate(period.end, days);
    final canBack = monthly
        ? _month.year > 1 || _month.month > 1
        : _shiftDate(period.start, -days).year >= 1;
    final canForward = monthly
        ? _month.isBefore(_currentMonth)
        : !nextEnd.isAfter(_today);
    final label = monthly
        ? MaterialLocalizations.of(context).formatMonthYear(_month)
        : _rangeLabel(period.start, period.end);
    return Row(
      children: [
        IconButton(
          key: const Key('reading-previous-period'),
          tooltip: (monthly ? 'Previous Month' : 'Previous Period').tl,
          onPressed: canBack ? () => _movePeriod(-1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: TextButton(
            key: Key(monthly ? 'reading-pick-month' : 'reading-pick-range'),
            onPressed: monthly ? _pickMonth : _pickRange,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.expand_more, size: 18),
              ],
            ),
          ),
        ),
        IconButton(
          key: const Key('reading-next-period'),
          tooltip: (monthly ? 'Next Month' : 'Next Period').tl,
          onPressed: canForward ? () => _movePeriod(1) : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }

  void _movePeriod(int delta) {
    setState(() {
      if (_range == _ReadingRange.month) {
        _month = DateTime(_month.year, _month.month + delta);
      } else {
        final period = _period!;
        final days = _dayCount(period.start, period.end) * delta;
        _setRange(
          DateTimeRange(
            start: _shiftDate(period.start, days),
            end: _shiftDate(period.end, days),
          ),
        );
      }
    });
  }

  void _setRange(DateTimeRange range) {
    _customRange = range == _recent ? null : range;
  }

  Future<void> _pickRange() async {
    final selected = await showReadingDateRangePicker(
      context: context,
      initialRange: _period!,
      today: _today,
    );
    if (selected != null && mounted) {
      setState(() => _setRange(selected));
    }
  }

  Future<void> _pickMonth() async {
    final selected = await showReadingMonthPicker(
      context: context,
      initialMonth: _month,
      today: _today,
    );
    if (selected != null && mounted) setState(() => _month = selected);
  }

  void _openComic(ComicReadingStatistics comic) {
    context.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.type.sourceKey,
        cover: comic.cover,
        title: comic.title,
      ),
    );
  }

  void _showPeriodDetails(DateTime start, DateTime end) {
    final period = DateTimeRange(start: start, end: end);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.72,
        child: ListenableBuilder(
          listenable: HistoryManager(),
          builder: (context, _) {
            final data = _load(period);
            final comics = _comics(data);
            return Column(
              key: const Key('reading-period-details'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _rangeLabel(start, end),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close'.tl,
                        onPressed: () => Navigator.pop(sheetContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    formatReadingDuration(data.periodTotal),
                    key: const Key('reading-detail-total'),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: comics.isEmpty
                      ? Center(
                          child: Text(
                            'No comics read in the selected period'.tl,
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          itemCount: comics.length,
                          itemBuilder: (context, index) => _RecentComicTile(
                            comic: comics[index],
                            total: data.periodTotal,
                            onOpen: (comic) {
                              Navigator.pop(sheetContext);
                              _openComic(comic);
                            },
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _showSortDialog() {
    var selected = sortType;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return ContentDialog(
              title: 'Sort'.tl,
              content: RadioGroup<ReadingStatisticsSortType>(
                groupValue: selected,
                onChanged: (v) {
                  setDialogState(() {
                    selected = v ?? selected;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<ReadingStatisticsSortType>(
                      title: Text('Last Read'.tl),
                      value: ReadingStatisticsSortType.lastRead,
                    ),
                    RadioListTile<ReadingStatisticsSortType>(
                      title: Text('Reading Time Desc'.tl),
                      value: ReadingStatisticsSortType.durationDesc,
                    ),
                    RadioListTile<ReadingStatisticsSortType>(
                      title: Text('Reading Time Asc'.tl),
                      value: ReadingStatisticsSortType.durationAsc,
                    ),
                    RadioListTile<ReadingStatisticsSortType>(
                      title: Text('Name Asc'.tl),
                      value: ReadingStatisticsSortType.nameAsc,
                    ),
                    RadioListTile<ReadingStatisticsSortType>(
                      title: Text('Name Desc'.tl),
                      value: ReadingStatisticsSortType.nameDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _applySort(selected);
                  },
                  child: Text('Confirm'.tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _applySort(ReadingStatisticsSortType value) {
    if (value == sortType) return;
    setState(() {
      sortType = value;
    });
    appdata.settings[_sortKey] = value.value;
    unawaited(appdata.saveData());
  }

  void _confirmClear(BuildContext context) {
    showConfirmDialog(
      context: context,
      title: 'Clear Reading Statistics'.tl,
      content: 'Are you sure you want to clear reading statistics?'.tl,
      confirmText: 'Clear',
      btnColor: context.colorScheme.error,
      onConfirm: widget.onClear ?? HistoryManager().clearReadingStatistics,
    );
  }

  void _removeReadingStatisticsForComic(ComicReadingStatistics comic) {
    showConfirmDialog(
      context: context,
      title: 'Delete Reading Statistics'.tl,
      content:
          'Delete all reading statistics for this comic, including other dates?'
              .tl,
      confirmText: 'Delete',
      btnColor: context.colorScheme.error,
      onConfirm: () {
        if (widget.onDelete != null) {
          widget.onDelete!(comic);
        } else {
          HistoryManager().removeReadingStatistics(comic.id, comic.type);
        }
      },
    );
  }
}

class _PageSection extends StatelessWidget {
  const _PageSection({required this.child, this.top = 16, this.bottom = 0});
  final Widget child;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(20, top, 20, bottom), child: child);
}

class _StatisticsCard extends StatelessWidget {
  const _StatisticsCard({
    required this.data,
    required this.month,
    required this.today,
    required this.onSelect,
  });
  final ReadingStatisticsSummary data;
  final DateTime? month;
  final DateTime today;
  final void Function(DateTime start, DateTime end) onSelect;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      key: const Key('reading-statistics-summary'),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reading Time'.tl,
            style: text.bodyMedium?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              formatReadingDuration(data.periodTotal),
              key: const Key('reading-period-total'),
              style: text.displaySmall?.copyWith(
                fontWeight: FontWeight.w600,
                letterSpacing: -1,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Metric(
                  label: 'Daily Average'.tl,
                  value: formatReadingDuration(data.averageDaily),
                  valueKey: const Key('reading-daily-average'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Metric(
                  label: 'Reading Days'.tl,
                  value: '${data.readingDays} / ${data.dayCount}',
                  valueKey: const Key('reading-active-days'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Metric(
                  label: 'Comics Read'.tl,
                  value: data.recentComics.length.toString(),
                  valueKey: const Key('reading-comic-count'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          const Divider(height: 1),
          const SizedBox(height: 16),
          Text(
            (month == null ? 'Reading Trend' : 'Reading Calendar').tl,
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          if (month != null)
            _ReadingCalendar(
              month: month!,
              today: today,
              daily: data.daily,
              onSelect: onSelect,
            )
          else
            _ReadingTrend(daily: data.daily, today: today, onSelect: onSelect),
          const SizedBox(height: 12),
          Text(
            (month == null
                    ? 'Tap a bar to view reading details'
                    : 'Tap a date to view reading details')
                .tl,
            style: text.bodySmall?.copyWith(
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.valueKey,
  });
  final String label;
  final String value;
  final Key valueKey;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: context.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 6),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          value,
          key: valueKey,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ],
  );
}

typedef _TrendBucket = ({DateTime start, DateTime end, Duration duration});

List<_TrendBucket> _trendBuckets(List<DailyReadingDuration> daily) {
  final buckets = <_TrendBucket>[];
  for (var index = 0; index < daily.length;) {
    final first = index;
    var duration = Duration.zero;
    do {
      duration += daily[index].duration;
      index++;
    } while (index < daily.length &&
        (daily.length > 90
            ? daily[index].day.year == daily[first].day.year &&
                  daily[index].day.month == daily[first].day.month
            : index - first < (daily.length > 14 ? 7 : 1)));
    buckets.add((
      start: daily[first].day,
      end: daily[index - 1].day,
      duration: duration,
    ));
  }
  return buckets;
}

class _ReadingTrend extends StatelessWidget {
  const _ReadingTrend({
    required this.daily,
    required this.today,
    required this.onSelect,
  });
  final List<DailyReadingDuration> daily;
  final DateTime today;
  final void Function(DateTime start, DateTime end) onSelect;

  @override
  Widget build(BuildContext context) {
    final buckets = _trendBuckets(daily);
    final maxMs = buckets.fold<int>(
      0,
      (value, item) => math.max(value, item.duration.inMilliseconds),
    );
    return SizedBox(
      key: const Key('reading-statistics-trend'),
      height: 166,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = buckets.length > 14
              ? math.max(constraints.maxWidth, buckets.length * 48.0)
              : constraints.maxWidth;
          return SingleChildScrollView(
            key: ValueKey('reading-trend-${daily.firstOrNull?.day}'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Stack(
                children: [
                  Positioned.fill(
                    bottom: 28,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: List.generate(
                        3,
                        (_) => const Divider(height: 1),
                      ),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var index = 0; index < buckets.length; index++)
                        Expanded(
                          child: _buildBar(
                            context,
                            buckets[index],
                            maxMs,
                            showLabel:
                                buckets.length <= 8 ||
                                index.isEven ||
                                index == buckets.length - 1,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBar(
    BuildContext context,
    _TrendBucket item,
    int maxMs, {
    required bool showLabel,
  }) {
    final factor = maxMs == 0 ? 0.0 : item.duration.inMilliseconds / maxMs;
    final description =
        '${_rangeLabel(item.start, item.end)}  ${formatReadingDuration(item.duration)}';
    final includesToday =
        !today.isBefore(item.start) && !today.isAfter(item.end);
    final label = daily.length > 90
        ? '${item.start.year}/${item.start.month}'
        : '${item.start.month}/${item.start.day}';
    return Tooltip(
      message: description,
      child: Semantics(
        label: description,
        button: true,
        excludeSemantics: true,
        onTap: () => onSelect(item.start, item.end),
        child: InkWell(
          key: ValueKey('reading-bar-${readingDayKey(item.start)}'),
          borderRadius: BorderRadius.circular(6),
          onTap: () => onSelect(item.start, item.end),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: 32,
                      height: math.max(3, factor * 128),
                      decoration: BoxDecoration(
                        color: includesToday
                            ? context.colorScheme.primary
                            : context.colorScheme.primary.withValues(
                                alpha: .35,
                              ),
                        borderRadius: BorderRadius.circular(5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 20,
                  child: showLabel
                      ? FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadingCalendar extends StatelessWidget {
  const _ReadingCalendar({
    required this.month,
    required this.today,
    required this.daily,
    required this.onSelect,
  });
  final DateTime month;
  final DateTime today;
  final List<DailyReadingDuration> daily;
  final void Function(DateTime start, DateTime end) onSelect;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    final firstWeekday = localizations.firstDayOfWeekIndex;
    final offset = (month.weekday % 7 - firstWeekday + 7) % 7;
    final count = DateUtils.getDaysInMonth(month.year, month.month);
    final rows = ((count + offset) / 7).ceil();
    final values = {for (final d in daily) readingDayKey(d.day): d.duration};
    final maxMs = daily.fold<int>(
      0,
      (value, d) => math.max(value, d.duration.inMilliseconds),
    );
    return Column(
      key: const Key('reading-statistics-calendar'),
      children: [
        Row(
          children: List.generate(
            7,
            (index) => Expanded(
              child: Center(
                child: Text(
                  localizations.narrowWeekdays[(index + firstWeekday) % 7],
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        for (var row = 0; row < rows; row++)
          Row(
            children: List.generate(7, (column) {
              final day = row * 7 + column - offset + 1;
              if (day < 1 || day > count) {
                return const Expanded(child: SizedBox(height: 44));
              }
              final date = DateTime(month.year, month.month, day);
              final duration = values[readingDayKey(date)] ?? Duration.zero;
              final future = date.isAfter(today);
              final factor = maxMs == 0 ? 0.0 : duration.inMilliseconds / maxMs;
              final color = factor == 0
                  ? context.colorScheme.surfaceContainerLow
                  : Color.lerp(
                      context.colorScheme.primaryContainer,
                      context.colorScheme.primary,
                      factor,
                    )!;
              final description =
                  '${_rangeLabel(date, date)}  ${formatReadingDuration(duration)}';
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Tooltip(
                    message: description,
                    child: Semantics(
                      label: description,
                      button: true,
                      enabled: !future,
                      excludeSemantics: true,
                      onTap: future ? null : () => onSelect(date, date),
                      child: Material(
                        color: future ? Colors.transparent : color,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          key: ValueKey('reading-day-${readingDayKey(date)}'),
                          borderRadius: BorderRadius.circular(8),
                          onTap: future ? null : () => onSelect(date, date),
                          child: Container(
                            alignment: Alignment.center,
                            constraints: const BoxConstraints(minHeight: 38),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: DateUtils.isSameDay(date, today)
                                  ? Border.all(
                                      color: context.colorScheme.primary,
                                      width: 2,
                                    )
                                  : null,
                            ),
                            child: Text(
                              '$day',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: future
                                        ? context.colorScheme.onSurface
                                              .withValues(alpha: .3)
                                        : factor > .55
                                        ? context.colorScheme.onPrimary
                                        : context.colorScheme.onSurface,
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
      ],
    );
  }
}

class _RecentComicTile extends StatelessWidget {
  const _RecentComicTile({
    required this.comic,
    required this.total,
    required this.onOpen,
    this.onDelete,
  });
  final ComicReadingStatistics comic;
  final Duration total;
  final ValueChanged<ComicReadingStatistics> onOpen;
  final ValueChanged<ComicReadingStatistics>? onDelete;

  @override
  Widget build(BuildContext context) {
    final image = comic.cover.isEmpty
        ? null
        : findImageProvider(_readingStatisticsComic(comic));
    final ratio = total.inMilliseconds == 0
        ? 0.0
        : (comic.duration.inMilliseconds / total.inMilliseconds).clamp(
            0.0,
            1.0,
          );
    final tile = Material(
      color: context.colorScheme.surface,
      child: InkWell(
        key: ValueKey('reading-comic-${comic.type.value}-${comic.id}'),
        onTap: () => onOpen(comic),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 58,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: context.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: image == null
                    ? const Icon(Icons.menu_book_outlined)
                    : AnimatedImage(image: image, fit: BoxFit.cover),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              comic.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          const SizedBox(width: 8),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth * .55,
                            ),
                            child: Text(
                              formatReadingDuration(comic.duration),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelLarge,
                            ),
                          ),
                        ],
                      ),
                      if (comic.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          comic.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: context.colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 3,
                              borderRadius: BorderRadius.circular(3),
                              backgroundColor:
                                  context.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '${(ratio * 100).round()}%',
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: context.colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (onDelete == null) return tile;
    return SwipeActionTile(
      key: ValueKey('reading-statistics-swipe-${comic.type.value}-${comic.id}'),
      groupTag: 'reading-statistics',
      endPane: SwipePane(
        dismissOnFullSwipe: true,
        keepItemOnFullSwipe: true,
        onFullSwipe: () => onDelete!(comic),
        actions: [
          SwipeAction(
            icon: Icons.delete_outline,
            label: 'Delete'.tl,
            onPressed: () => onDelete!(comic),
          ),
        ],
      ),
      child: tile,
    );
  }
}

DateTime _shiftDate(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);

int _dayCount(DateTime start, DateTime end) =>
    DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
    1;

String _rangeLabel(DateTime start, DateTime end) {
  final first = '${start.year}/${start.month}/${start.day}';
  if (DateUtils.isSameDay(start, end)) return first;
  final last = start.year == end.year
      ? '${end.month}/${end.day}'
      : '${end.year}/${end.month}/${end.day}';
  return '$first – $last';
}

String formatReadingDuration(Duration duration) {
  if (duration == Duration.zero) return '@m min'.tlParams({'m': 0});
  if (duration < const Duration(minutes: 1)) {
    return 'Less than a minute'.tl;
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0 && minutes > 0) {
    return '@h h @m min'.tlParams({'h': hours, 'm': minutes});
  }
  if (hours > 0) {
    return '@h h'.tlParams({'h': hours});
  }
  return '@m min'.tlParams({'m': minutes});
}

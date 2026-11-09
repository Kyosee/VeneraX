import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
  DateTime? _selectedDay;

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
    sortType = storedValue == null
        ? ReadingStatisticsSortType.durationDesc
        : ReadingStatisticsSortType.fromString(storedValue.toString());
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
    final original = Theme.of(context);
    final dark = original.brightness == Brightness.dark;
    final theme = original.copyWith(
      colorScheme: original.colorScheme.copyWith(
        surface: dark ? const Color(0xff20262e) : Colors.white,
        primaryContainer: Color.lerp(
          dark ? const Color(0xff20262e) : Colors.white,
          original.colorScheme.primary,
          dark ? .14 : .09,
        ),
        onPrimaryContainer: original.colorScheme.primary,
        surfaceContainerLow: dark
            ? const Color(0xff15191f)
            : const Color(0xfff4f6f9),
        surfaceContainerHighest: dark
            ? const Color(0xff2c3440)
            : const Color(0xffedf0f4),
        outlineVariant: dark
            ? const Color(0xff2c3440)
            : const Color(0xffedf0f4),
        onSurface: dark ? const Color(0xfff1f4f9) : const Color(0xff202937),
        onSurfaceVariant: dark
            ? const Color(0xff929baa)
            : const Color(0xff7a8493),
      ),
    );
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          if (widget.summary != null || widget.loadSummary != null) {
            return _buildPage(context, _load(_period));
          }
          return ListenableBuilder(
            listenable: HistoryManager(),
            builder: (context, _) => _buildPage(context, _load(_period)),
          );
        },
      ),
    );
  }

  Widget _buildPage(BuildContext context, ReadingStatisticsSummary data) {
    final comics = _comics(data);
    final overline = switch (_range) {
      _ReadingRange.month => 'Reading This Month',
      _ReadingRange.allTime => 'All-Time Reading',
      _ReadingRange.recent =>
        _customRange == null
            ? 'Reading in the Last 7 Days'
            : 'Reading in Selected Period',
    };
    return Scaffold(
      backgroundColor: context.colorScheme.surfaceContainerLow,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            centerTitle: true,
            toolbarHeight: 55,
            backgroundColor: context.colorScheme.surfaceContainerLow,
            surfaceTintColor: Colors.transparent,
            title: Text(
              'Reading Statistics'.tl,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            actions: [
              IconButton(
                key: const Key('reading-statistics-more'),
                tooltip: 'More'.tl,
                icon: const Icon(Icons.more_horiz),
                onPressed: () => _showMore(context, data.total > Duration.zero),
              ),
              const SizedBox(width: 6),
            ],
          ),
          SliverToBoxAdapter(
            child: _PageSection(
              top: 4,
              child: Column(
                children: [
                  _buildTabs(context),
                  const SizedBox(height: 18),
                  _buildDateNavigation(context),
                  const SizedBox(height: 14),
                  _StatisticsCard(
                    data: data,
                    overline: overline.tl,
                    month: _range == _ReadingRange.month ? _month : null,
                    allTime: _range == _ReadingRange.allTime,
                    selectedDay: _selectedDay,
                    today: _today,
                    onSelect: (start, end) =>
                        _showPeriodDetails(context, start, end),
                    onSelectMonth: (month) => setState(() {
                      _month = DateTime(month.year, month.month);
                      _range = _ReadingRange.month;
                    }),
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
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: (switch (_range) {
                              _ReadingRange.month => 'Comics This Month',
                              _ReadingRange.allTime => 'All Comics Read',
                              _ReadingRange.recent => 'Comics Read',
                            }).tl,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          TextSpan(
                            text:
                                '  ${'@n titles'.tlParams({'n': comics.length})}',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (comics.isNotEmpty)
                    TextButton(
                      key: const Key('sort-reading-statistics'),
                      onPressed: () => _applySort(
                        sortType == ReadingStatisticsSortType.durationDesc
                            ? ReadingStatisticsSortType.nameAsc
                            : ReadingStatisticsSortType.durationDesc,
                      ),
                      onLongPress: () => _showSortDialog(context),
                      style: TextButton.styleFrom(
                        foregroundColor: context.colorScheme.onSurfaceVariant,
                        padding: const EdgeInsets.only(left: 8),
                        minimumSize: const Size(40, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _sortLabel(sortType).tl,
                            style: const TextStyle(fontSize: 11),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.sort, size: 14),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (comics.isEmpty)
            SliverToBoxAdapter(
              child: _PageSection(
                top: 0,
                child: Container(
                  key: const Key('reading-statistics-empty'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 28,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surface,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    (data.total == Duration.zero
                            ? 'No reading statistics yet'
                            : 'No comics read in the selected period')
                        .tl,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: comics.length,
              itemBuilder: (_, index) => _PageSection(
                top: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    top: index == 0 ? const Radius.circular(20) : Radius.zero,
                    bottom: index == comics.length - 1
                        ? const Radius.circular(20)
                        : Radius.zero,
                  ),
                  child: _RecentComicTile(
                    comic: comics[index],
                    total: data.periodTotal,
                    divider: index != comics.length - 1,
                    onDelete: (comic) =>
                        _removeReadingStatisticsForComic(context, comic),
                    onOpen: (comic) => _showComicActions(context, comic),
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: _PageSection(
              top: 14,
              child: Text(
                (_range == _ReadingRange.allTime
                        ? 'Counted from the first reading record'
                        : 'Daily average includes every date in the selected period')
                    .tl,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          if (comics.length != data.recentComics.length)
            SliverToBoxAdapter(
              child: _PageSection(
                top: 6,
                child: Text(
                  'Blocked comics are hidden from this list'.tl,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: SizedBox(height: MediaQuery.paddingOf(context).bottom + 28),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: context.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        for (final range in _ReadingRange.values)
          Expanded(
            child: Semantics(
              selected: range == _range,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1.5),
                child: TextButton(
                  onPressed: () => setState(() => _range = range),
                  style: TextButton.styleFrom(
                    backgroundColor: range == _range
                        ? context.colorScheme.surface
                        : Colors.transparent,
                    foregroundColor: range == _range
                        ? context.colorScheme.onSurface
                        : context.colorScheme.onSurfaceVariant,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                    minimumSize: const Size(0, 33),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    (switch (range) {
                      _ReadingRange.recent =>
                        _customRange == null ? 'Last 7 Days' : 'Custom',
                      _ReadingRange.month => 'By Month',
                      _ReadingRange.allTime => 'All Time',
                    }).tl,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _buildDateNavigation(BuildContext context) {
    final period = _period;
    final monthly = _range == _ReadingRange.month;
    final days = period == null ? 0 : _dayCount(period.start, period.end);
    final canBack =
        period != null &&
        (monthly
            ? _month.year > 1 || _month.month > 1
            : _shiftDate(period.start, -days).year >= 1);
    final canForward =
        period != null &&
        (monthly
            ? _month.isBefore(_currentMonth)
            : !_shiftDate(period.end, days).isAfter(_today));
    final label = period == null
        ? 'All Reading Records'.tl
        : monthly
        ? MaterialLocalizations.of(context).formatMonthYear(_month)
        : _shortRangeLabel(context, period.start, period.end);
    return Row(
      children: [
        IconButton(
          key: const Key('reading-previous-period'),
          tooltip: (monthly ? 'Previous Month' : 'Previous Period').tl,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          padding: const EdgeInsets.all(6),
          iconSize: 18,
          onPressed: canBack ? () => _movePeriod(-1) : null,
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: TextButton(
            key: Key(
              monthly
                  ? 'reading-pick-month'
                  : period == null
                  ? 'reading-all-period'
                  : 'reading-pick-range',
            ),
            onPressed: period == null
                ? null
                : monthly
                ? () => _pickMonth(context)
                : () => _pickRange(context),
            style: TextButton.styleFrom(
              disabledForegroundColor: context.colorScheme.onSurface,
              foregroundColor: context.colorScheme.onSurface,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (period != null &&
                      !monthly &&
                      period.start.year == period.end.year) ...[
                    const SizedBox(width: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _tint(context),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        '${period.start.year}',
                        style: TextStyle(
                          fontSize: 10,
                          color: context.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                  if (period != null) ...[
                    const SizedBox(width: 5),
                    const Icon(Icons.expand_more, size: 14),
                  ],
                ],
              ),
            ),
          ),
        ),
        IconButton(
          key: const Key('reading-next-period'),
          tooltip: (monthly ? 'Next Month' : 'Next Period').tl,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          padding: const EdgeInsets.all(6),
          iconSize: 18,
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

  Future<void> _pickRange(BuildContext context) async {
    final selected = await showReadingDateRangePicker(
      context: context,
      initialRange: _period!,
      today: _today,
    );
    if (selected != null && mounted) {
      setState(() => _setRange(selected));
    }
  }

  Future<void> _pickMonth(BuildContext context) async {
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

  Future<void> _showPeriodDetails(
    BuildContext context,
    DateTime start,
    DateTime end,
  ) async {
    final pageContext = context;
    setState(() => _selectedDay = start);
    await showReadingStatisticsSheet<void>(
      context: context,
      builder: (sheetContext) => ListenableBuilder(
        listenable: HistoryManager(),
        builder: (context, _) {
          final data = _load(DateTimeRange(start: start, end: end));
          final comics = _comics(data);
          final single = DateUtils.isSameDay(start, end);
          return Column(
            key: const Key('reading-period-details'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetHeading(
                title: _shortRangeLabel(context, start, end),
                subtitle: single
                    ? '@year · Daily Reading Records'.tlParams({
                        'year': start.year,
                      })
                    : '@days Days of Reading'.tlParams({
                        'days': _dayCount(start, end),
                      }),
              ),
              const SizedBox(height: 18),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(
                    _readingDurationLabel(data.periodTotal),
                    semanticsLabel: formatReadingDuration(data.periodTotal),
                    key: const Key('reading-detail-total'),
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '@n titles'.tlParams({'n': comics.length}),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (comics.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    'No comics read in the selected period'.tl,
                    textAlign: TextAlign.center,
                  ),
                )
              else
                SizedBox(
                  height: math.min(
                    comics.length * 81.0,
                    MediaQuery.sizeOf(context).height * .46,
                  ),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: comics.length,
                    itemBuilder: (context, index) => _RecentComicTile(
                      comic: comics[index],
                      total: data.periodTotal,
                      detail: single,
                      divider: index != comics.length - 1,
                      horizontal: 0,
                      onOpen: (comic) {
                        Navigator.pop(sheetContext);
                        _showComicActions(pageContext, comic);
                      },
                    ),
                  ),
                ),
              if (single) ...[
                const SizedBox(height: 12),
                Divider(height: 1, color: context.colorScheme.outlineVariant),
                const SizedBox(height: 12),
                Text(
                  'Tap a comic to view details and continue reading'.tl,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
    if (mounted) setState(() => _selectedDay = null);
  }

  String _sortLabel(ReadingStatisticsSortType type) => switch (type) {
    ReadingStatisticsSortType.durationDesc => 'Time First',
    ReadingStatisticsSortType.nameAsc => 'Name Order',
    ReadingStatisticsSortType.lastRead => 'Last Read',
    ReadingStatisticsSortType.durationAsc => 'Reading Time Asc',
    ReadingStatisticsSortType.nameDesc => 'Name Desc',
  };

  void _showSortDialog(BuildContext context) {
    showReadingStatisticsSheet<void>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SheetHeading(title: 'Sort'.tl),
          for (final type in ReadingStatisticsSortType.values)
            ListTile(
              title: Text(
                (switch (type) {
                  ReadingStatisticsSortType.durationDesc => 'Reading Time Desc',
                  ReadingStatisticsSortType.nameAsc => 'Name Asc',
                  _ => _sortLabel(type),
                }).tl,
              ),
              trailing: sortType == type ? const Icon(Icons.check) : null,
              onTap: () {
                Navigator.pop(context);
                _applySort(type);
              },
            ),
        ],
      ),
    );
  }

  void _applySort(ReadingStatisticsSortType value) {
    if (value == sortType) return;
    setState(() => sortType = value);
    appdata.settings[_sortKey] = value.value;
    unawaited(appdata.saveData());
  }

  void _showMore(BuildContext context, bool hasData) {
    showReadingStatisticsSheet<void>(
      context: context,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHeading(title: 'Manage Statistics'.tl),
          _SheetAction(
            label: 'How Statistics Work'.tl,
            onPressed: () {
              Navigator.pop(sheetContext);
              showReadingStatisticsSheet<void>(
                context: context,
                builder: (context) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SheetHeading(title: 'How Statistics Work'.tl),
                    const SizedBox(height: 16),
                    Text(
                      'Daily average includes days without reading. Reading time comes from recorded reading sessions.'
                          .tl,
                      style: const TextStyle(fontSize: 13, height: 1.7),
                    ),
                  ],
                ),
              );
            },
          ),
          _SheetAction(
            actionKey: const Key('clear-reading-statistics'),
            label: 'Clear All Reading Statistics'.tl,
            danger: true,
            onPressed: hasData
                ? () {
                    Navigator.pop(sheetContext);
                    _confirmClear(context);
                  }
                : null,
          ),
        ],
      ),
    );
  }

  void _confirmClear(BuildContext context) {
    showReadingStatisticsSheet<void>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHeading(title: 'Clear All Reading Statistics?'.tl),
          const SizedBox(height: 12),
          Text(
            'This permanently deletes reading time for every date. Comics, favorites and reading progress are kept.'
                .tl,
            style: TextStyle(
              fontSize: 12,
              height: 1.8,
              color: context.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          _SheetAction(
            label: 'Keep Records'.tl,
            filled: true,
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              (widget.onClear ?? HistoryManager().clearReadingStatistics)();
            },
            style: FilledButton.styleFrom(
              backgroundColor: context.colorScheme.error,
            ),
            child: Text('Confirm Clear'.tl),
          ),
        ],
      ),
    );
  }

  void _showComicActions(BuildContext context, ComicReadingStatistics comic) {
    showReadingStatisticsSheet<void>(
      context: context,
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHeading(
            title: comic.title,
            subtitle: 'Reading in selected period: @time'.tlParams({
              'time': _readingDurationLabel(comic.duration),
            }),
          ),
          const SizedBox(height: 12),
          _SheetAction(
            actionKey: const Key('reading-open-comic'),
            label: 'View Comic / Continue Reading'.tl,
            filled: true,
            onPressed: () {
              Navigator.pop(sheetContext);
              _openComic(comic);
            },
          ),
          _SheetAction(
            actionKey: const Key('reading-delete-comic'),
            label: 'Delete Statistics for This Comic'.tl,
            danger: true,
            onPressed: () {
              Navigator.pop(sheetContext);
              _removeReadingStatisticsForComic(context, comic);
            },
          ),
        ],
      ),
    );
  }

  void _removeReadingStatisticsForComic(
    BuildContext context,
    ComicReadingStatistics comic,
  ) {
    showReadingStatisticsSheet<void>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SheetHeading(title: 'Delete Reading Statistics'.tl),
          const SizedBox(height: 12),
          Text(
            'Delete all reading statistics for this comic, including other dates?'
                .tl,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 16),
          _SheetAction(
            label: 'Cancel'.tl,
            filled: true,
            onPressed: () => Navigator.pop(context),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colorScheme.error,
            ),
            onPressed: () {
              Navigator.pop(context);
              if (widget.onDelete != null) {
                widget.onDelete!(comic);
              } else {
                HistoryManager().removeReadingStatistics(comic.id, comic.type);
              }
            },
            child: Text('Delete'.tl),
          ),
        ],
      ),
    );
  }
}

class _SheetHeading extends StatelessWidget {
  const _SheetHeading({required this.title, this.subtitle});
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 5),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.6,
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
      IconButton(
        tooltip: 'Close'.tl,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: const EdgeInsets.all(8),
        iconSize: 18,
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close),
      ),
    ],
  );
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.label,
    this.onPressed,
    this.filled = false,
    this.danger = false,
    this.actionKey,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final bool danger;
  final Key? actionKey;
  @override
  Widget build(BuildContext context) => TextButton(
    key: actionKey,
    onPressed: onPressed,
    style: TextButton.styleFrom(
      backgroundColor: filled ? _tint(context) : Colors.transparent,
      foregroundColor: danger
          ? context.colorScheme.error
          : filled
          ? context.colorScheme.primary
          : context.colorScheme.onSurface,
      alignment: filled ? Alignment.center : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    child: Text(label, style: TextStyle(fontSize: filled ? 13 : 14)),
  );
}

class _PageSection extends StatelessWidget {
  const _PageSection({required this.child, this.top = 16, this.bottom = 0});
  final Widget child;
  final double top;
  final double bottom;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(16, top, 16, bottom), child: child);
}

class _StatisticsCard extends StatelessWidget {
  const _StatisticsCard({
    required this.data,
    required this.overline,
    required this.month,
    required this.allTime,
    required this.today,
    required this.onSelect,
    required this.onSelectMonth,
    this.selectedDay,
  });
  final ReadingStatisticsSummary data;
  final String overline;
  final DateTime? month;
  final bool allTime;
  final DateTime today;
  final DateTime? selectedDay;
  final void Function(DateTime start, DateTime end) onSelect;
  final ValueChanged<DateTime> onSelectMonth;

  @override
  Widget build(BuildContext context) {
    final muted = context.colorScheme.onSurfaceVariant;
    final monthlyBars = allTime || data.dayCount > 90;
    final label = month != null
        ? 'Reading Calendar'
        : monthlyBars
        ? 'Monthly Overview'
        : data.dayCount > 14
        ? 'Reading by Period'
        : 'Daily Reading';
    final caption = month != null
        ? 'Tap a date for details'
        : !monthlyBars && data.dayCount > 14
        ? 'Every 7 Days · Minutes'
        : 'Minutes';
    final number = TextStyle(
      fontSize: 47,
      height: 1.1,
      fontWeight: FontWeight.w600,
      letterSpacing: -2,
      color: context.colorScheme.onSurface,
    );
    final unit = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      color: muted,
    );
    final duration = data.periodTotal;
    return Container(
      key: const Key('reading-statistics-summary'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 21, 18, 16),
      decoration: BoxDecoration(
        color: context.colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_outlined, size: 13, color: muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  overline,
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text.rich(
              TextSpan(
                style: number,
                children: [
                  TextSpan(text: '${duration.inHours}'),
                  TextSpan(text: ' ${'hours'.tl}  ', style: unit),
                  TextSpan(text: '${duration.inMinutes.remainder(60)}'),
                  TextSpan(text: ' ${'minutes'.tl}', style: unit),
                ],
              ),
              key: const Key('reading-period-total'),
              semanticsLabel: formatReadingDuration(duration),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _Metric(
                  label: 'Daily Average'.tl,
                  value:
                      '${(data.averageDaily.inMilliseconds / 60000).round()}',
                  unit: 'minutes'.tl,
                  valueKey: const Key('reading-daily-average'),
                  semanticValue: formatReadingDuration(data.averageDaily),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Metric(
                  label: 'Reading Days'.tl,
                  value: '${data.readingDays}',
                  unit: 'days'.tl,
                  valueKey: const Key('reading-active-days'),
                  semanticValue: '${data.readingDays} / ${data.dayCount}',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Metric(
                  label: 'Comics Read'.tl,
                  value: '${data.recentComics.length}',
                  unit: 'comics'.tl,
                  valueKey: const Key('reading-comic-count'),
                  semanticValue: '${data.recentComics.length}',
                ),
              ),
            ],
          ),
          const SizedBox(height: 17),
          Divider(height: 1, color: context.colorScheme.outlineVariant),
          const SizedBox(height: 17),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  label.tl,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  caption.tl,
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 10, color: muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (month != null)
            _ReadingCalendar(
              month: month!,
              today: today,
              daily: data.daily,
              selectedDay: selectedDay,
              onSelect: onSelect,
            )
          else ...[
            _ReadingTrend(
              daily: data.daily,
              today: today,
              monthly: monthlyBars,
              onSelect: onSelect,
              onSelectMonth: onSelectMonth,
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: context.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    allTime
                        ? 'All Recorded Data'.tl
                        : data.daily.any(
                            (d) => DateUtils.isSameDay(d.day, today),
                          )
                        ? 'Read Today: @time'.tlParams({
                            'time': _readingDurationLabel(data.today),
                          })
                        : '@days days selected · @active reading days'.tlParams(
                            {'days': data.dayCount, 'active': data.readingDays},
                          ),
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    (monthlyBars ? 'Tap to view month' : 'Tap for details').tl,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.unit,
    required this.valueKey,
    required this.semanticValue,
  });
  final String label;
  final String value;
  final String unit;
  final Key valueKey;
  final String semanticValue;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: context.colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 5),
      FittedBox(
        fit: BoxFit.scaleDown,
        child: Text.rich(
          TextSpan(
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            children: [
              TextSpan(text: value),
              TextSpan(
                text: ' $unit',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          key: valueKey,
          semanticsLabel: semanticValue,
        ),
      ),
    ],
  );
}

typedef _TrendBucket = ({DateTime start, DateTime end, Duration duration});
List<_TrendBucket> _trendBuckets(
  List<DailyReadingDuration> daily,
  bool monthly,
) {
  final buckets = <_TrendBucket>[];
  for (var index = 0; index < daily.length;) {
    final first = index;
    var duration = Duration.zero;
    do {
      duration += daily[index].duration;
      index++;
    } while (index < daily.length &&
        (monthly
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
    required this.monthly,
    required this.onSelect,
    required this.onSelectMonth,
  });
  final List<DailyReadingDuration> daily;
  final DateTime today;
  final bool monthly;
  final void Function(DateTime start, DateTime end) onSelect;
  final ValueChanged<DateTime> onSelectMonth;

  @override
  Widget build(BuildContext context) {
    final buckets = _trendBuckets(daily, monthly);
    final peak = buckets.fold<double>(
      0,
      (value, item) => math.max(value, item.duration.inMilliseconds / 60000),
    );
    final maxMinutes = math.max(
      !monthly && daily.length <= 14 ? 120 : 60,
      (peak / 60).ceil() * 60,
    );
    return SizedBox(
      key: const Key('reading-statistics-trend'),
      height:
          152 + math.max(14, MediaQuery.textScalerOf(context).scale(10) * 1.5),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = math.max(constraints.maxWidth, buckets.length * 38.0);
          return SingleChildScrollView(
            key: ValueKey('reading-trend-${daily.firstOrNull?.day}'),
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final entry in [
                    (12.0, maxMinutes),
                    (80.0, maxMinutes ~/ 2),
                    (148.0, 0),
                  ]) ...[
                    Positioned(
                      left: 0,
                      right: 0,
                      top: entry.$1,
                      child: CustomPaint(
                        size: const Size(double.infinity, 1),
                        painter: _DashedLine(
                          context.colorScheme.outlineVariant,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: entry.$1 - 12,
                      child: Text(
                        '${entry.$2}',
                        style: TextStyle(
                          fontSize: 9,
                          color: context.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.only(right: 22),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final item in buckets)
                          Expanded(child: _bar(context, item, maxMinutes)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bar(BuildContext context, _TrendBucket item, int maxMinutes) {
    final isToday =
        DateUtils.isSameDay(item.start, today) &&
        DateUtils.isSameDay(item.end, today);
    final minutes = item.duration.inMilliseconds / 60000;
    final height = math.max(3.0, minutes / maxMinutes * 136);
    final label = monthly
        ? (daily.first.day.year != daily.last.day.year
              ? '${item.start.year}/${item.start.month}'
              : DateFormat.MMM(
                  Localizations.localeOf(context).toString(),
                ).format(item.start))
        : isToday
        ? 'Today'.tl
        : '${item.start.month}/${item.start.day}';
    void select() {
      if (monthly) {
        onSelectMonth(item.start);
      } else {
        onSelect(item.start, item.end);
      }
    }

    final description =
        '${_rangeLabel(item.start, item.end)}  ${formatReadingDuration(item.duration)}';
    return Tooltip(
      message: description,
      child: Semantics(
        label: description,
        button: true,
        excludeSemantics: true,
        onTap: select,
        child: InkWell(
          key: ValueKey('reading-bar-${readingDayKey(item.start)}'),
          onTap: select,
          borderRadius: BorderRadius.circular(5),
          child: Column(
            children: [
              SizedBox(
                height: 148,
                child: Stack(
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.none,
                  children: [
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Container(
                        width: 23,
                        height: height,
                        decoration: BoxDecoration(
                          color: isToday
                              ? context.colorScheme.primary
                              : Color.lerp(
                                  context.colorScheme.surface,
                                  context.colorScheme.primary,
                                  .27,
                                ),
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(5),
                            bottom: Radius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    if (isToday)
                      Positioned(
                        bottom: height + 4,
                        child: Text(
                          '@m m'.tlParams({'m': item.duration.inMinutes}),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: context.colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: isToday ? FontWeight.w600 : FontWeight.w400,
                  color: isToday
                      ? context.colorScheme.primary
                      : context.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedLine extends CustomPainter {
  const _DashedLine(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 6) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(math.min(x + 3, size.width), 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_DashedLine oldDelegate) => color != oldDelegate.color;
}

class _ReadingCalendar extends StatelessWidget {
  const _ReadingCalendar({
    required this.month,
    required this.today,
    required this.daily,
    required this.onSelect,
    this.selectedDay,
  });
  final DateTime month;
  final DateTime today;
  final List<DailyReadingDuration> daily;
  final DateTime? selectedDay;
  final void Function(DateTime start, DateTime end) onSelect;
  Color _heat(BuildContext context, int level) {
    if (level == 0) return context.colorScheme.surfaceContainerHighest;
    return Color.lerp(
      context.colorScheme.surface,
      context.colorScheme.primary,
      switch (level) {
        1 => .08,
        2 => .25,
        3 => .55,
        _ => .92,
      },
    )!;
  }

  @override
  Widget build(BuildContext context) {
    final loc = MaterialLocalizations.of(context);
    final first = loc.firstDayOfWeekIndex;
    final offset = (month.weekday % 7 - first + 7) % 7;
    final count = DateUtils.getDaysInMonth(month.year, month.month);
    final values = {
      for (final day in daily) readingDayKey(day.day): day.duration,
    };
    return Column(
      key: const Key('reading-statistics-calendar'),
      children: [
        Row(
          children: List.generate(
            7,
            (i) => Expanded(
              child: Center(
                child: Text(
                  loc.narrowWeekdays[(i + first) % 7],
                  style: TextStyle(
                    fontSize: 10,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 5),
        for (var row = 0; row < ((count + offset) / 7).ceil(); row++)
          Row(
            children: List.generate(7, (col) {
              final number = row * 7 + col - offset + 1;
              if (number < 1 || number > count) {
                return const Expanded(child: SizedBox(height: 37));
              }
              final date = DateTime(month.year, month.month, number);
              final duration = values[readingDayKey(date)] ?? Duration.zero;
              final n = duration.inMilliseconds / 60000;
              final level = n == 0
                  ? 0
                  : n < 45
                  ? 1
                  : n < 70
                  ? 2
                  : n < 95
                  ? 3
                  : 4;
              final future = date.isAfter(today);
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
                        borderRadius: BorderRadius.circular(7),
                        color: future
                            ? Colors.transparent
                            : _heat(context, level),
                        child: InkWell(
                          key: ValueKey('reading-day-${readingDayKey(date)}'),
                          borderRadius: BorderRadius.circular(7),
                          onTap: future ? null : () => onSelect(date, date),
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 31),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(7),
                              border: DateUtils.isSameDay(date, selectedDay)
                                  ? Border.all(
                                      color: context.colorScheme.primary,
                                      width: 2,
                                    )
                                  : null,
                            ),
                            child: Text(
                              '$number',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                                color: future
                                    ? context.colorScheme.onSurfaceVariant
                                          .withValues(alpha: .4)
                                    : level == 4
                                    ? context.colorScheme.onPrimary
                                    : level == 0
                                    ? context.colorScheme.onSurfaceVariant
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
        const SizedBox(height: 9),
        Row(
          children: [
            Expanded(
              child: Text(
                'Darker means more reading'.tl,
                style: TextStyle(
                  fontSize: 9,
                  color: context.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              'Less'.tl,
              style: TextStyle(
                fontSize: 9,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
            for (var level = 1; level <= 4; level++)
              Container(
                margin: const EdgeInsets.only(left: 3),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _heat(context, level),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 3),
            Text(
              'More reading'.tl,
              style: TextStyle(
                fontSize: 9,
                color: context.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
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
    this.divider = false,
    this.detail = false,
    this.horizontal = 14,
  });
  final ComicReadingStatistics comic;
  final Duration total;
  final ValueChanged<ComicReadingStatistics> onOpen;
  final ValueChanged<ComicReadingStatistics>? onDelete;
  final bool divider;
  final bool detail;
  final double horizontal;

  @override
  Widget build(BuildContext context) {
    final image = comic.cover.isEmpty
        ? null
        : findImageProvider(_readingStatisticsComic(comic));
    final ratio = total.inMilliseconds <= 0
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
          padding: EdgeInsets.symmetric(horizontal: horizontal),
          child: Container(
            decoration: BoxDecoration(
              border: divider
                  ? Border(
                      bottom: BorderSide(
                        color: context.colorScheme.outlineVariant,
                      ),
                    )
                  : null,
            ),
            padding: const EdgeInsets.symmetric(vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 54,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: image == null
                      ? const Icon(Icons.menu_book_outlined, size: 22)
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
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 5),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth * .5,
                              ),
                              child: Text(
                                _readingDurationLabel(
                                  comic.duration,
                                  compact: true,
                                ),
                                semanticsLabel: formatReadingDuration(
                                  comic.duration,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 7),
                        if (detail)
                          Text(
                            'Reading Time on This Date'.tl,
                            style: TextStyle(
                              fontSize: 10,
                              color: context.colorScheme.onSurfaceVariant,
                            ),
                          )
                        else
                          Row(
                            children: [
                              Expanded(
                                child: LinearProgressIndicator(
                                  value: ratio,
                                  minHeight: 3,
                                  color: context.colorScheme.primary.withValues(
                                    alpha: .65,
                                  ),
                                  borderRadius: BorderRadius.circular(3),
                                  backgroundColor:
                                      context.colorScheme.outlineVariant,
                                ),
                              ),
                              const SizedBox(width: 9),
                              Text(
                                '${(ratio * 100).round()}%',
                                style: TextStyle(
                                  fontSize: 9,
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

Color _tint(BuildContext context) =>
    Color.lerp(context.colorScheme.surface, context.colorScheme.primary, .09)!;

DateTime _shiftDate(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);
int _dayCount(DateTime start, DateTime end) =>
    DateTime.utc(
      end.year,
      end.month,
      end.day,
    ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
    1;

String _shortRangeLabel(BuildContext context, DateTime start, DateTime end) {
  final loc = MaterialLocalizations.of(context);
  if (start.year != end.year) return _rangeLabel(start, end);
  final first = loc.formatShortMonthDay(start);
  if (DateUtils.isSameDay(start, end)) return first;
  return '$first – ${loc.formatShortMonthDay(end)}';
}

String _rangeLabel(DateTime start, DateTime end) {
  final first = '${start.year}/${start.month}/${start.day}';
  if (DateUtils.isSameDay(start, end)) return first;
  final last = start.year == end.year
      ? '${end.month}/${end.day}'
      : '${end.year}/${end.month}/${end.day}';
  return '$first – $last';
}

String _readingDurationLabel(Duration duration, {bool compact = false}) {
  if (duration < const Duration(minutes: 1)) {
    return formatReadingDuration(duration);
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0 && minutes > 0) {
    return (compact ? '@h h @m m' : '@h hr @m min').tlParams({
      'h': hours,
      'm': minutes,
    });
  }
  if (hours > 0) return (compact ? '@h h.' : '@h hr').tlParams({'h': hours});
  return (compact ? '@m m' : '@m min').tlParams({'m': minutes});
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

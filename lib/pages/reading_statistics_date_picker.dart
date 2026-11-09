import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:venera/utils/translations.dart';

/// Shared sheet geometry keeps statistics actions consistent with the preview.
Future<T?> showReadingStatisticsSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  barrierColor: const Color(0x480A111A),
  backgroundColor: Theme.of(context).colorScheme.surface,
  constraints: BoxConstraints(
    maxWidth: 600,
    maxHeight:
        MediaQuery.sizeOf(context).height -
        MediaQuery.paddingOf(context).top -
        24,
  ),
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
  ),
  clipBehavior: Clip.antiAlias,
  builder: (context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: .3),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 18),
          builder(context),
        ],
      ),
    ),
  ),
);

Future<DateTimeRange?> showReadingDateRangePicker({
  required BuildContext context,
  required DateTimeRange initialRange,
  required DateTime today,
}) => showReadingStatisticsSheet<DateTimeRange>(
  context: context,
  builder: (context) =>
      _ReadingDateRangePicker(initialRange: initialRange, today: today),
);

class _ReadingDateRangePicker extends StatefulWidget {
  const _ReadingDateRangePicker({
    required this.initialRange,
    required this.today,
  });
  final DateTimeRange initialRange;
  final DateTime today;

  @override
  State<_ReadingDateRangePicker> createState() =>
      _ReadingDateRangePickerState();
}

class _ReadingDateRangePickerState extends State<_ReadingDateRangePicker> {
  late DateTime _start = DateUtils.dateOnly(widget.initialRange.start);
  late DateTime? _end = DateUtils.dateOnly(widget.initialRange.end);
  late DateTime _month = DateTime(_end!.year, _end!.month);
  bool _selectStart = true;

  DateTime get _today => DateUtils.dateOnly(widget.today);

  void _pickDay(DateTime day) {
    if (day.isAfter(_today)) return;
    setState(() {
      if (_selectStart || day.isBefore(_start)) {
        _start = day;
        _end = null;
        _selectStart = false;
      } else {
        _end = day;
        _selectStart = true;
      }
    });
  }

  void _preset(int days) {
    setState(() {
      _start = DateTime(_today.year, _today.month, _today.day - days + 1);
      _end = _today;
      _selectStart = true;
      _month = DateTime(_today.year, _today.month);
    });
  }

  void _chooseEdge(bool start) {
    setState(() {
      _selectStart = start;
      final date = start ? _start : _end ?? _start;
      _month = DateTime(date.year, date.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final valid = _end != null && !_end!.isBefore(_start);
    final days = valid
        ? DateTime.utc(_end!.year, _end!.month, _end!.day)
                  .difference(
                    DateTime.utc(_start.year, _start.month, _start.day),
                  )
                  .inDays +
              1
        : 0;
    return _PickerContents(
      key: const Key('reading-range-dialog'),
      title: 'Select Date Range'.tl,
      subtitle: 'Select the start date, then the end date'.tl,
      children: [
        const SizedBox(height: 18),
        Row(
          children: [
            for (final preset in [
              (1, 'Today', 'today'),
              (7, 'Last 7 Days', 'week'),
              (30, 'Last 30 Days', 'month'),
            ]) ...[
              if (preset.$1 != 1) const SizedBox(width: 8),
              Expanded(
                child: _pickerButton(
                  context,
                  key: Key('reading-preset-${preset.$3}'),
                  label: preset.$2.tl,
                  fontSize: 12,
                  minHeight: 35,
                  radius: 9,
                  selected: days == preset.$1 && _end == _today,
                  onPressed: () => _preset(preset.$1),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 15),
        Row(
          children: [
            Expanded(child: _dateField(true)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                'to'.tl,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ),
            Expanded(child: _dateField(false)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              key: const Key('reading-range-previous-month'),
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: 'Previous Month'.tl,
              onPressed: _month.year == 1 && _month.month == 1
                  ? null
                  : () => setState(
                      () => _month = DateTime(_month.year, _month.month - 1),
                    ),
              icon: const Icon(Icons.chevron_left, size: 20),
            ),
            Expanded(
              child: Text(
                MaterialLocalizations.of(context).formatMonthYear(_month),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              key: const Key('reading-range-next-month'),
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: 'Next Month'.tl,
              onPressed: DateUtils.isSameMonth(_month, _today)
                  ? null
                  : () => setState(
                      () => _month = DateTime(_month.year, _month.month + 1),
                    ),
              icon: const Icon(Icons.chevron_right, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _calendar(),
        const SizedBox(height: 14),
        Semantics(
          liveRegion: true,
          child: Text(
            valid
                ? 'Selected @days days, including both dates'.tlParams({
                    'days': days,
                  })
                : 'Select an end date; tap the start date again for one day'.tl,
            key: const Key('reading-range-help'),
            style: TextStyle(
              fontSize: 11,
              height: 1.6,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _pickerButton(
                context,
                key: const Key('reading-range-cancel'),
                label: 'Cancel'.tl,
                selected: true,
                onPressed: () => Navigator.pop(context),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              flex: 3,
              child: _pickerButton(
                context,
                key: const Key('reading-range-apply'),
                label: 'View This Period'.tl,
                primary: true,
                onPressed: valid
                    ? () => Navigator.pop(
                        context,
                        DateTimeRange(start: _start, end: _end!),
                      )
                    : null,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _dateField(bool start) {
    final colors = Theme.of(context).colorScheme;
    final selected = _selectStart == start;
    final date = start ? _start : _end;
    return Material(
      color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
        ),
      ),
      child: InkWell(
        key: Key(start ? 'reading-range-start' : 'reading-range-end'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => _chooseEdge(start),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (start ? 'Start Date' : 'End Date').tl,
                style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 5),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  date == null
                      ? 'Choose a date'.tl
                      : DateFormat('yyyy/MM/dd').format(date),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _calendar() {
    final colors = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    final firstWeekday = localizations.firstDayOfWeekIndex;
    final offset = (_month.weekday % 7 - firstWeekday + 7) % 7;
    final count = DateUtils.getDaysInMonth(_month.year, _month.month);
    return Column(
      children: [
        Row(
          children: List.generate(
            7,
            (index) => Expanded(
              child: Text(
                localizations.narrowWeekdays[(firstWeekday + index) % 7],
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        for (var row = 0; row < ((offset + count) / 7).ceil(); row++)
          Padding(
            padding: EdgeInsets.only(top: row == 0 ? 0 : 5),
            child: Row(
              children: List.generate(7, (column) {
                final number = row * 7 + column - offset + 1;
                if (number < 1 || number > count) {
                  return const Expanded(child: SizedBox(height: 37));
                }
                final date = DateTime(_month.year, _month.month, number);
                final endpoint = date == _start || date == _end;
                final inside =
                    _end != null &&
                    !date.isBefore(_start) &&
                    !date.isAfter(_end!);
                final future = date.isAfter(_today);
                final isToday = date == _today;
                final foreground = endpoint
                    ? colors.onPrimary
                    : inside || isToday
                    ? colors.primary
                    : colors.onSurface;
                final radius = BorderRadius.circular(
                  endpoint
                      ? 8
                      : inside
                      ? 3
                      : 8,
                );
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2.5),
                    child: Semantics(
                      label: localizations.formatFullDate(date),
                      selected: endpoint || inside,
                      button: true,
                      enabled: !future,
                      onTap: future ? null : () => _pickDay(date),
                      excludeSemantics: true,
                      child: Material(
                        color: endpoint
                            ? colors.primary
                            : inside
                            ? colors.primaryContainer
                            : Colors.transparent,
                        borderRadius: radius,
                        child: InkWell(
                          key: ValueKey(
                            'range-day-${date.year * 10000 + date.month * 100 + date.day}',
                          ),
                          borderRadius: radius,
                          onTap: future ? null : () => _pickDay(date),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 37),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    '$number',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: endpoint || isToday
                                          ? FontWeight.w600
                                          : FontWeight.normal,
                                      color: future
                                          ? foreground.withValues(alpha: .3)
                                          : foreground,
                                    ),
                                  ),
                                ),
                                if (isToday)
                                  Positioned(
                                    bottom: 4,
                                    child: Container(
                                      width: 3,
                                      height: 3,
                                      decoration: BoxDecoration(
                                        color: foreground,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}

Future<DateTime?> showReadingMonthPicker({
  required BuildContext context,
  required DateTime initialMonth,
  required DateTime today,
}) => showReadingStatisticsSheet<DateTime>(
  context: context,
  builder: (context) =>
      _ReadingMonthPicker(initialMonth: initialMonth, today: today),
);

class _ReadingMonthPicker extends StatefulWidget {
  const _ReadingMonthPicker({required this.initialMonth, required this.today});
  final DateTime initialMonth;
  final DateTime today;

  @override
  State<_ReadingMonthPicker> createState() => _ReadingMonthPickerState();
}

class _ReadingMonthPickerState extends State<_ReadingMonthPicker> {
  late int _year = widget.initialMonth.year;
  bool _chooseYear = false;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    return _PickerContents(
      key: const Key('reading-month-dialog'),
      title: 'Choose Month'.tl,
      subtitle: 'Jump directly to the month you want'.tl,
      children: [
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(
              key: const Key('reading-previous-year'),
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: 'Previous Year'.tl,
              onPressed: _year > 1 ? () => setState(() => _year--) : null,
              icon: const Icon(Icons.chevron_left, size: 20),
            ),
            Expanded(
              child: TextButton(
                key: const Key('reading-pick-year'),
                onPressed: () => setState(() => _chooseYear = !_chooseYear),
                child: Text(
                  '$_year',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const Key('reading-next-year'),
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              tooltip: 'Next Year'.tl,
              onPressed: _year < widget.today.year
                  ? () => setState(() => _year++)
                  : null,
              icon: const Icon(Icons.chevron_right, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 20),
        if (_chooseYear)
          SizedBox(
            height: 222,
            child: YearPicker(
              key: ValueKey(_year),
              firstDate: DateTime(1),
              lastDate: widget.today,
              currentDate: widget.today,
              selectedDate: DateTime(_year),
              onChanged: (date) => setState(() {
                _year = date.year;
                _chooseYear = false;
              }),
            ),
          )
        else
          for (var row = 0; row < 4; row++)
            Padding(
              padding: EdgeInsets.only(top: row == 0 ? 0 : 10),
              child: Row(
                children: List.generate(5, (index) {
                  if (index.isOdd) return const SizedBox(width: 10);
                  final month = DateTime(_year, row * 3 + index ~/ 2 + 1);
                  return Expanded(
                    child: _pickerButton(
                      context,
                      key: ValueKey('reading-month-$_year-${month.month}'),
                      label: DateFormat.MMM(locale).format(month),
                      fontSize: 14,
                      minHeight: 48,
                      selected: DateUtils.isSameMonth(
                        month,
                        widget.initialMonth,
                      ),
                      onPressed: month.isAfter(widget.today)
                          ? null
                          : () => Navigator.pop(context, month),
                    ),
                  );
                }),
              ),
            ),
        const SizedBox(height: 12),
        _pickerButton(
          context,
          key: const Key('reading-current-month'),
          label: 'Back to This Month'.tl,
          selected: true,
          onPressed: () => Navigator.pop(
            context,
            DateTime(widget.today.year, widget.today.month),
          ),
        ),
      ],
    );
  }
}

class _PickerContents extends StatelessWidget {
  const _PickerContents({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close'.tl,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
      ...children,
    ],
  );
}

Widget _pickerButton(
  BuildContext context, {
  Key? key,
  required String label,
  required VoidCallback? onPressed,
  bool selected = false,
  bool primary = false,
  double fontSize = 13,
  double minHeight = 44,
  double radius = 12,
}) {
  final colors = Theme.of(context).colorScheme;
  return TextButton(
    key: key,
    style: TextButton.styleFrom(
      backgroundColor: primary
          ? colors.primary
          : selected
          ? colors.primaryContainer
          : colors.surfaceContainerLow,
      foregroundColor: primary
          ? colors.onPrimary
          : selected
          ? colors.primary
          : colors.onSurface,
      disabledBackgroundColor: colors.surfaceContainerLow,
      disabledForegroundColor: colors.onSurface.withValues(alpha: .3),
      minimumSize: Size(0, minHeight),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
        fontSize: fontSize,
        fontWeight: primary || selected ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
    onPressed: onPressed,
    child: Text(label, textAlign: TextAlign.center),
  );
}

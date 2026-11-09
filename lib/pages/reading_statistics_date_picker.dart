import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:venera/utils/translations.dart';

Future<DateTimeRange?> showReadingDateRangePicker({
  required BuildContext context,
  required DateTimeRange initialRange,
  required DateTime today,
}) => showDialog<DateTimeRange>(
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
  late DateTimeRange _draft = widget.initialRange;
  int _revision = 0;

  void _preset(int days) {
    setState(() {
      _draft = DateTimeRange(
        start: DateTime(
          widget.today.year,
          widget.today.month,
          widget.today.day - days + 1,
        ),
        end: widget.today,
      );
      _revision++;
    });
  }

  TextStyle _rangeHeaderStyle(BuildContext context, double width) {
    final style = Theme.of(context).textTheme.titleLarge!;
    final localizations = MaterialLocalizations.of(context);
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
      maxLines: 1,
    );
    var longest = 0.0;
    final dates = [
      for (var month = 1; month <= 12; month++)
        localizations.formatShortDate(DateTime(widget.today.year, month, 28)),
      localizations.dateRangeStartLabel,
      localizations.dateRangeEndLabel,
    ];
    for (final date in dates) {
      painter.text = TextSpan(text: '$date – $date', style: style);
      painter.layout();
      if (painter.width > longest) longest = painter.width;
    }
    painter.dispose();
    // The native range header leaves its start label outside Flexible.
    final available =
        width - (MediaQuery.sizeOf(context).width < 360 ? 42 : 72) - 64;
    final factor = (available / longest).clamp(0.0, 1.0);
    return style.copyWith(fontSize: style.fontSize! * factor);
  }

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600, maxHeight: 800),
      child: Material(
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => DatePickerTheme(
                  data: DatePickerTheme.of(context).copyWith(
                    rangePickerHeaderHeadlineStyle: _rangeHeaderStyle(
                      context,
                      constraints.maxWidth,
                    ),
                  ),
                  child: DateRangePickerDialog(
                    key: ValueKey(_revision),
                    initialDateRange: _draft,
                    firstDate: DateTime(1),
                    lastDate: widget.today,
                    currentDate: widget.today,
                    helpText: 'Select Date Range'.tl,
                    saveText: 'View This Period'.tl,
                    confirmText: 'Confirm'.tl,
                    cancelText: 'Cancel'.tl,
                  ),
                ),
              ),
            ),
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ActionChip(
                      key: const Key('reading-preset-today'),
                      label: Text('Today'.tl),
                      onPressed: () => _preset(1),
                    ),
                    ActionChip(
                      key: const Key('reading-preset-week'),
                      label: Text('Last 7 Days'.tl),
                      onPressed: () => _preset(7),
                    ),
                    ActionChip(
                      key: const Key('reading-preset-month'),
                      label: Text('Last 30 Days'.tl),
                      onPressed: () => _preset(30),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

Future<DateTime?> showReadingMonthPicker({
  required BuildContext context,
  required DateTime initialMonth,
  required DateTime today,
}) => showDialog<DateTime>(
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
    return AlertDialog(
      key: const Key('reading-month-dialog'),
      title: Text('Choose Month'.tl),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  key: const Key('reading-previous-year'),
                  tooltip: 'Previous Year'.tl,
                  onPressed: _year > 1 ? () => setState(() => _year--) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: TextButton(
                    key: const Key('reading-pick-year'),
                    onPressed: () => setState(() => _chooseYear = !_chooseYear),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$_year'),
                          const SizedBox(width: 4),
                          Icon(
                            _chooseYear ? Icons.expand_less : Icons.expand_more,
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('reading-next-year'),
                  tooltip: 'Next Year'.tl,
                  onPressed: _year < widget.today.year
                      ? () => setState(() => _year++)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            SizedBox(
              height: 240,
              child: _chooseYear
                  ? YearPicker(
                      key: ValueKey(_year),
                      firstDate: DateTime(1),
                      lastDate: widget.today,
                      currentDate: widget.today,
                      selectedDate: DateTime(_year),
                      onChanged: (date) => setState(() {
                        _year = date.year;
                        _chooseYear = false;
                      }),
                    )
                  : GridView(
                      padding: EdgeInsets.zero,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisExtent: 48,
                            mainAxisSpacing: 8,
                            crossAxisSpacing: 4,
                          ),
                      children: List.generate(12, (index) {
                        final month = DateTime(_year, index + 1);
                        final selected = DateUtils.isSameMonth(
                          month,
                          widget.initialMonth,
                        );
                        return TextButton(
                          key: ValueKey('reading-month-$_year-${index + 1}'),
                          style: selected
                              ? TextButton.styleFrom(
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.primaryContainer,
                                )
                              : null,
                          onPressed: month.isAfter(widget.today)
                              ? null
                              : () => Navigator.pop(context, month),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(DateFormat.MMM(locale).format(month)),
                          ),
                        );
                      }),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'.tl),
        ),
      ],
    );
  }
}

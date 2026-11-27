import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/holiday.dart';

void main() {
  test('Christmas starts and ends at local midnight', () {
    final christmas = (holiday: Holiday.christmas, year: 2026);
    expect(holidayAt(DateTime(2026, 12, 23, 23, 59, 59)), isNull);
    expect(holidayAt(DateTime(2026, 12, 24)), christmas);
    expect(holidayAt(DateTime(2026, 12, 25, 23, 59, 59)), christmas);
    expect(holidayAt(DateTime(2026, 12, 26)), isNull);
  });

  test('both days of each New Year use the incoming year on the card', () {
    for (final year in [2026, 2027, 2028, 2039, 2099]) {
      final newYear = (holiday: Holiday.newYear, year: year + 1);
      expect(holidayAt(DateTime(year, 12, 30, 23, 59, 59)), isNull);
      expect(holidayAt(DateTime(year, 12, 31)), newYear);
      expect(holidayAt(DateTime(year, 12, 31, 23, 59, 59)), newYear);
      expect(holidayAt(DateTime(year + 1, 1, 1)), newYear);
      expect(holidayAt(DateTime(year + 1, 1, 1, 23, 59, 59)), newYear);
      expect(holidayAt(DateTime(year + 1, 1, 2)), isNull);
      expect(
        newYear.dismissalKey,
        isNot(holidayAt(DateTime(year + 1, 12, 31))!.dismissalKey),
      );
    }
  });
}

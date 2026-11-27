enum Holiday { christmas, newYear }

typedef HolidayOccurrence = ({Holiday holiday, int year});

extension HolidayOccurrenceKey on HolidayOccurrence {
  String get dismissalKey => '${holiday.name}-$year';
}

HolidayOccurrence? holidayAt(DateTime local) {
  if (local.month == 12) {
    if (local.day == 24 || local.day == 25) {
      return (holiday: Holiday.christmas, year: local.year);
    }
    if (local.day == 31) {
      return (holiday: Holiday.newYear, year: local.year + 1);
    }
  }
  if (local.month == 1 && local.day == 1) {
    return (holiday: Holiday.newYear, year: local.year);
  }
  return null;
}

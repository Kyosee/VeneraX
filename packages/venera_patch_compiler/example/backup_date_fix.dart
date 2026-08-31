// A real patch, written as ordinary Dart and compiled against the surface
// manifest emitted by `patch_tool surface`.
//
// This is the #51 fix: a backup file name's leading segment is normally
// days-since-epoch, but older and foreign backups store a full millisecond
// timestamp. Multiplying that by 86400000 overflows 64-bit int and throws a
// RangeError that aborts the whole directory scan.
import 'package:venera_patch_compiler/annotations.dart';

@PatchOverride('backupDateFromLeadingSegment')
int fixedDate(int value) {
  const msPerDay = 86400000;
  const maxValidMs = 8640000000000000;
  var ms = value.abs() <= maxValidMs ~/ msPerDay ? value * msPerDay : value;
  if (ms > maxValidMs) ms = maxValidMs;
  if (ms < -maxValidMs) ms = -maxValidMs;
  return ms;
}

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data_sync.dart';

void main() {
  group('RemoteBackupInfo.fromFileName', () {
    test('parses numeric version and platform', () {
      var info = RemoteBackupInfo.fromFileName('20240-7.android.venera');
      expect(info.version, 7);
      expect(info.platform, 'android');
    });

    test('two-digit version outranks single-digit by value, not string order',
        () {
      // Regression: file names were previously sorted lexicographically, which
      // ranks "...-9.venera" above "...-10.venera" and reversed the sync
      // direction once the version crossed into double digits.
      var v9 = RemoteBackupInfo.fromFileName('20240-9.windows.venera');
      var v10 = RemoteBackupInfo.fromFileName('20240-10.android.venera');

      // The bug: string comparison puts v9 first.
      expect('20240-9.windows.venera'.compareTo('20240-10.android.venera') > 0,
          isTrue);
      // The fix: numeric version correctly ranks v10 as newer.
      expect(v10.version > v9.version, isTrue);
    });

    test('malformed name falls back to version 0', () {
      expect(RemoteBackupInfo.fromFileName('garbage.venera').version, 0);
    });

    test('does not overflow on legacy millisecond-timestamp file names', () {
      // Regression for issue #51: older/foreign backups name files with a full
      // millisecondsSinceEpoch leading segment (13 digits) instead of
      // days-since-epoch (5 digits). The parser multiplied that by 86400000,
      // overflowing 64-bit int on Android and throwing
      // RangeError (millisecondsSinceEpoch) ... 6355900559421187072, which
      // aborted the whole directory scan and blocked WebDAV download.
      late RemoteBackupInfo info;
      expect(
        () => info =
            RemoteBackupInfo.fromFileName('1781595522559-3.android.venera'),
        returnsNormally,
      );
      expect(info.version, 3);
      expect(info.platform, 'android');
      // A millisecond leading segment must be read as milliseconds directly,
      // not multiplied. 1781595522559 ms since epoch == 2026-06-16.
      expect(info.date, DateTime.fromMillisecondsSinceEpoch(1781595522559));
    });

    test('day-precision file names still resolve to the right date', () {
      // 20621 days since epoch == 2026-06-16; the common path must be unchanged.
      var info = RemoteBackupInfo.fromFileName('20621-3.android.venera');
      expect(info.date, DateTime.fromMillisecondsSinceEpoch(20621 * 86400000));
      expect(info.version, 3);
    });

    test('absurdly large leading segment is clamped, never throws', () {
      // Even a value too big to be a real timestamp must not crash the scan.
      late RemoteBackupInfo info;
      expect(
        () => info = RemoteBackupInfo.fromFileName(
            '99999999999999999999-1.android.venera'),
        returnsNormally,
      );
      expect(info.version, 1);
    });
  });
}

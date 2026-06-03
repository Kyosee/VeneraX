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
  });
}

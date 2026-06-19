import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/download_keepalive.dart';

void main() {
  group('formatDownloadStatus', () {
    test('appends transfer speed when it is positive', () {
      expect(
        formatDownloadStatus(title: 'Comic', message: 'Ep.1 3/10', speed: 1024),
        'Comic · Ep.1 3/10 · 1.00 KB/s',
      );
    });

    test('omits speed segment when speed is zero', () {
      expect(
        formatDownloadStatus(title: 'Comic', message: '3/10', speed: 0),
        'Comic · 3/10',
      );
    });

    test('falls back to title only when message is empty', () {
      expect(
        formatDownloadStatus(title: 'Comic', message: '', speed: 0),
        'Comic',
      );
    });
  });
}

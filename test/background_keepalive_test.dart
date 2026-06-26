import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/background_keepalive.dart';

void main() {
  group('formatTaskStatus', () {
    test('appends detail after the title', () {
      expect(
        formatTaskStatus(title: 'My Folder', detail: '3/10'),
        'My Folder · 3/10',
      );
    });

    test('falls back to title only when detail is null', () {
      expect(formatTaskStatus(title: 'My Folder'), 'My Folder');
    });

    test('falls back to title only when detail is empty/blank', () {
      expect(formatTaskStatus(title: 'My Folder', detail: ''), 'My Folder');
      expect(formatTaskStatus(title: 'My Folder', detail: '   '), 'My Folder');
    });

    test('trims surrounding whitespace from detail', () {
      expect(
        formatTaskStatus(title: 'Comic', detail: '  Extracting  '),
        'Comic · Extracting',
      );
    });
  });

  group('syncKeepAliveActive', () {
    test('stays active while any single sync flag is set', () {
      expect(
        syncKeepAliveActive(
          uploading: true,
          downloading: false,
          syncingImages: false,
          waiting: false,
        ),
        isTrue,
      );
      expect(
        syncKeepAliveActive(
          uploading: false,
          downloading: true,
          syncingImages: false,
          waiting: false,
        ),
        isTrue,
      );
      // The overlap case that the shared 'sync' tag must survive: a data
      // up/download has finished but a deferred image-pack sync is still running.
      expect(
        syncKeepAliveActive(
          uploading: false,
          downloading: false,
          syncingImages: true,
          waiting: false,
        ),
        isTrue,
      );
      // A queued operation waiting its turn must hold the notification across the
      // hand-off so it doesn't flicker between two back-to-back syncs.
      expect(
        syncKeepAliveActive(
          uploading: false,
          downloading: false,
          syncingImages: false,
          waiting: true,
        ),
        isTrue,
      );
    });

    test('is released only when every sync flag is clear', () {
      expect(
        syncKeepAliveActive(
          uploading: false,
          downloading: false,
          syncingImages: false,
          waiting: false,
        ),
        isFalse,
      );
    });
  });
}

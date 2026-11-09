import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/background_keepalive.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed translation updates can still remove native task state',
    () async {
      const channel = MethodChannel('venera/background_keepalive');
      final updated = Completer<void>();
      final removed = Completer<void>();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'notificationGranted') return true;
        if (call.method == 'update') {
          updated.complete();
          return false;
        }
        if (call.method == 'remove') {
          expect(call.arguments, {'tag': BackgroundKeepAlive.tagPreTranslate});
          removed.complete();
          return true;
        }
        throw StateError('Unexpected method ${call.method}');
      });
      try {
        final service = BackgroundKeepAlive.instance;
        service.update(BackgroundKeepAlive.tagPreTranslate, 'Test');
        await updated.future;
        await Future<void>.delayed(Duration.zero);
        service.remove(BackgroundKeepAlive.tagPreTranslate);
        await removed.future.timeout(const Duration(seconds: 3));
      } finally {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

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

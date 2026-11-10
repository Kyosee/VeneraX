import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_follow_queue.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_update_scope.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/ohos_follow_scheduler.dart';
import 'package:venera/foundation/reading_widget.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/translations.dart';

/// Runs only inside the native extension's exclusive data lease.
void runOhosFollowWorker(List<String> args) {
  overrideIO(() {
    runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        App.isBackgroundTask = true;
        Log.isMuted = true;
        var cancelled = false;
        const channel = OhosFollowScheduler.channel;
        channel.setMethodCallHandler((call) async {
          if (call.method == 'stop') cancelled = true;
        });
        final deadline = Timer(
          const Duration(seconds: 90),
          () => cancelled = true,
        );
        var outcome = 'failed';
        var stage = 'data';
        void markStage(String value) {
          stage = value;
          unawaited(channel.invokeMethod<void>('stage', {'stage': value}));
        }

        try {
          cancelled =
              (await channel.invokeMethod<bool>('ready') ?? false) || cancelled;
          if (cancelled || args.length != 3) {
            outcome = 'cancelled';
            return;
          }
          markStage('data');
          App.initBackgroundTask(args[0], args[1], args[2]);
          await appdata.init();
          if (!FollowUpdateScope.isConfigured ||
              !FollowUpdateScope.isPastFixedTime(
                FollowUpdateScope.fixedTime,
                DateTime.now(),
              )) {
            outcome = 'disabled';
            return;
          }
          markStage('translation');
          await AppTranslation.init();
          markStage('network');
          await nativeInitRhttp();
          markStage('stores');
          await SingleInstanceCookieJar.createInstance();
          await LocalFavoritesManager().init();
          await App.domain.init(App.dataPath);
          markStage('sources');
          await JsEngine().init();
          await ComicSourceManager().init();
          if (cancelled) {
            outcome = 'cancelled';
            return;
          }
          markStage('checks');
          final entries = dedupeFollowUpdateEntries({
            for (final folder in FollowUpdateScope.folders())
              folder: LocalFavoritesManager().getComicsWithUpdatesInfo(folder),
          });
          final byKey = {
            for (final entry in entries) entry.comic.identityKey: entry,
          };
          final updateTimes = {
            for (final entry in entries)
              entry.comic.identityKey: entry.comic.updateTime,
          };
          final queue = BackgroundFollowQueue(
            '${App.dataPath}/ohos_follow_queue.json',
          );
          queue.reconcile(updateTimes);
          Future<void> notifyPending() async {
            final pending = queue.pending;
            if (pending.isEmpty) return;
            final sent = await channel.invokeMethod<bool>('notify', {
              'status':
                  '${"Follow Updates".tl} · ${"@c updates".tlParams({'c': pending.length})}',
            });
            if (sent == true) queue.acknowledge(pending);
          }

          // New slow requests must not delay previously committed results.
          await notifyPending();
          final due = entries
              .where(
                (entry) =>
                    FollowUpdateScope.isDue(entry.comic.lastCheckDateTime),
              )
              .map((entry) => entry.comic.identityKey)
              .toSet();
          while (!cancelled && due.isNotEmpty) {
            final batch = queue.takeBatch(due, updateTimes);
            if (batch.isEmpty) break;
            due.removeAll(batch);
            await Future.wait(
              batch.map((key) async {
                final entry = byKey[key]!;
                final result = await updateComic(
                  entry.comic,
                  entry.folders,
                  shouldCancel: () => cancelled,
                );
                queue.complete(key, updated: result.updated);
                if (result.errorMessage == null && !cancelled) {
                  DataSync().requestAutoUpload();
                }
              }),
            );
            // Keep source request bursts bounded and cancellation responsive.
            for (var i = 0; i < 12 && !cancelled && due.isNotEmpty; i++) {
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
          }
          await notifyPending();
          outcome = cancelled ? 'cancelled' : 'checked';
          await ReadingWidgetService.instance.refresh(
            kinds: const [
              ReadingWidgetKind.following,
              ReadingWidgetKind.updates,
            ],
            loadCovers: false,
          );
        } catch (_) {
          // Do not send source URLs, credentials or comic titles to system logs.
        } finally {
          deadline.cancel();
          markStage('cleanup');
          try {
            JsEngine().dispose();
          } catch (_) {
            // Native engine teardown remains responsible for isolate cleanup.
          }
          try {
            SingleInstanceCookieJar.instance?.dispose();
            if (LocalFavoritesManager().isInitialized) {
              LocalFavoritesManager().close();
            }
            if (App.domain.isInitialized) App.domain.close();
          } finally {
            await channel.invokeMethod<void>('finished', {
              'outcome': outcome,
              'stage': stage,
            });
          }
        }
      },
      (error, stack) {
        // Native teardown still owns the deadline and data lease on async errors.
      },
    );
  });
}

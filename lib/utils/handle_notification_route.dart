import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/auth_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/tasks_page.dart';

bool _isHandling = false;

/// Only the most recent tap navigates; older ones still waiting give up.
int _latestTap = 0;

/// Waits until the app is foreground, the main navigator exists and is unlocked.
///
/// A cold start delivers the tap before the main page is built (loading,
/// disclaimer or lock screen still showing). Gives up after about a minute.
Future<NavigatorState?> waitForUnlockedMainNavigator() async {
  for (var i = 0; i < 600; i++) {
    final navigator = App.mainNavigatorKey?.currentState;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    // Native launch events can arrive before the rendering surface resumes.
    final foreground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (foreground &&
        navigator != null &&
        navigator.mounted &&
        !AuthPage.isActive) {
      return navigator;
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

/// Closes root routes (reader, dialogs) stacked over the main page, so a page
/// pushed into the main navigator is not hidden beneath them.
void revealMainNavigator(NavigatorState navigator) {
  final host = ModalRoute.of(navigator.context);
  if (host == null || host.isCurrent) return;
  host.navigator?.popUntil((route) => route == host || route.isFirst);
}

Widget? _pageFor(String event) => switch (event) {
      'follow_updates' => const FollowUpdatesPage(),
      'tasks' => const TasksPage(),
      'downloading' => const DownloadingPage(),
      _ => null,
    };

/// Opens a single background-task notification route in the main navigator.
Future<void> openNotificationRoute(String event) async {
  final page = _pageFor(event);
  if (page == null) return;
  final tap = ++_latestTap;
  final navigator = await waitForUnlockedMainNavigator();
  if (navigator == null || tap != _latestTap) return;
  revealMainNavigator(navigator);
  navigator.context.to(() => page);
}

/// Handle taps on background-task notifications (Android only).
///
/// Each foreground service tags its notification's PendingIntent with a route
/// string (see the native `*KeepAliveService`); MainActivity forwards it over
/// the `venera/notification_route` event channel. Here we map the route to a
/// page and navigate, so tapping a follow-update / sync / download card lands
/// on the matching screen instead of merely opening the app (#148).
void handleNotificationRoute() {
  if (_isHandling) return;
  _isHandling = true;

  const channel = EventChannel('venera/notification_route');
  // listen, not await-for: a tap waiting on the lock screen must not hold up
  // later taps, and one failure must not end the subscription.
  channel.receiveBroadcastStream().listen((event) {
    if (event is! String) return;
    openNotificationRoute(event).catchError((Object e, StackTrace s) {
      Log.error("Notification Route", e, s);
    });
  });
}

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/tasks_page.dart';

bool _isHandling = false;

Future<BuildContext?> _mainNavigatorContext() async {
  var context = App.mainNavigatorKey?.currentContext;
  if (context == null) {
    // The nested navigator can lag a cold start; wait briefly for it to attach.
    await Future.delayed(const Duration(milliseconds: 200));
    context = App.mainNavigatorKey?.currentContext;
  }
  return context;
}

/// Opens a single background-task notification route in the main navigator.
Future<void> openNotificationRoute(String event) async {
  final context = await _mainNavigatorContext();
  if (context == null) return;

  switch (event) {
    case 'follow_updates':
      context.to(() => const FollowUpdatesPage());
    case 'tasks':
      context.to(() => const TasksPage());
    case 'downloading':
      context.to(() => const DownloadingPage());
  }
}

/// Handle taps on background-task notifications (Android only).
///
/// Each foreground service tags its notification's PendingIntent with a route
/// string (see the native `*KeepAliveService`); MainActivity forwards it over
/// the `venera/notification_route` event channel. Here we map the route to a
/// page and navigate, so tapping a follow-update / sync / download card lands
/// on the matching screen instead of merely opening the app (#148).
void handleNotificationRoute() async {
  if (_isHandling) return;
  _isHandling = true;

  var channel = const EventChannel('venera/notification_route');
  await for (var event in channel.receiveBroadcastStream()) {
    if (event is! String) continue;
    await openNotificationRoute(event);
  }
}

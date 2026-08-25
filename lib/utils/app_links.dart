import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

typedef AppLinkCandidate = ({String sourceKey, LinkHandler? linkHandler});
typedef AppLinkTarget = ({String sourceKey, String comicId});

final AppLinks _appLinks = AppLinks();
final List<Uri> _pendingAppLinks = [];
StreamSubscription<Uri>? _appLinkSubscription;
bool _appLinkHandlingReady = false;

/// Starts listening before source initialization so a cold-start link is not
/// lost. Links stay queued until [handleLinks] marks the source registry ready.
void startAppLinkCapture() {
  _appLinkSubscription ??= _appLinks.uriLinkStream.listen(
    (uri) {
      if (!_appLinkHandlingReady) {
        _pendingAppLinks.add(uri);
        return;
      }
      unawaited(_handleCapturedAppLink(uri));
    },
    onError: (Object error, StackTrace stackTrace) {
      Log.error('App Link', error, stackTrace);
    },
  );
}

/// Enables routing after installed comic sources have finished loading.
void handleLinks() {
  startAppLinkCapture();
  _appLinkHandlingReady = true;
  final pending = List<Uri>.from(_pendingAppLinks);
  _pendingAppLinks.clear();
  for (final uri in pending) {
    unawaited(_handleCapturedAppLink(uri));
  }
}

@visibleForTesting
AppLinkTarget? resolveAppLink(Uri uri, Iterable<AppLinkCandidate> candidates) {
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;

  for (final candidate in candidates) {
    final handler = candidate.linkHandler;
    if (handler == null ||
        !handler.domains.any((domain) => domain.trim().toLowerCase() == host)) {
      continue;
    }
    try {
      final id = handler.linkToId(uri.toString());
      if (id != null && id.isNotEmpty) {
        return (sourceKey: candidate.sourceKey, comicId: id);
      }
    } catch (e, s) {
      Log.error('App Link', e, s);
    }
  }
  return null;
}

Future<bool> handleAppLink(Uri uri) async {
  final target = resolveAppLink(
    uri,
    ComicSource.all().map(
      (source) => (sourceKey: source.key, linkHandler: source.linkHandler),
    ),
  );
  if (target == null) return false;

  if (App.mainNavigatorKey?.currentContext == null) {
    await Future.delayed(const Duration(milliseconds: 200));
  }
  final context = App.mainNavigatorKey?.currentContext;
  if (context == null) return false;
  context.to(() => ComicPage(id: target.comicId, sourceKey: target.sourceKey));
  return true;
}

Future<void> _handleCapturedAppLink(Uri uri) async {
  try {
    await handleAppLink(uri);
  } catch (e, s) {
    Log.error('App Link', e, s);
  }
}

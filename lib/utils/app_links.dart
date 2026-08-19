import 'dart:async';
import 'package:app_links/app_links.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';

/// Registers the app as a handler for comic links (issue #72).
///
/// Covers both entry paths:
/// - cold start: the app is launched by an external link (getInitialLink)
/// - warm start: the app is already running (uriLinkStream)
void handleLinks() {
  final appLinks = AppLinks();
  appLinks.getInitialLink().then((uri) {
    if (uri != null) {
      handleAppLink(uri);
    }
  });
  appLinks.uriLinkStream.listen((uri) {
    handleAppLink(uri);
  });
}

/// Resolves an external link to a comic and opens its detail page.
///
/// Accepted link forms:
/// - `https://<domain>/...` where <domain> is declared by a source's
///   `comic.link.domains` (e.g. nhentai.net/g/123456)
/// - `venerax://open?url=<urlencoded>` carrying a full comic url
/// - `venerax://<host>/<path>` shorthand that maps back to https
Future<bool> handleAppLink(Uri uri) async {
  var target = uri;

  // Unwrap the custom scheme into a regular https url.
  if (target.scheme == 'venerax') {
    if (target.host == 'open') {
      final encoded = target.queryParameters['url'];
      if (encoded == null) return false;
      target = Uri.parse(encoded);
    } else {
      target = Uri(
        scheme: 'https',
        host: target.host,
        port: target.hasPort ? target.port : null,
        path: target.path,
        query: target.query,
      );
    }
  }

  if (target.scheme != 'https' && target.scheme != 'http') return false;

  // On a cold start the sources may not be registered yet; wait for them
  // (they are loaded during app init, but the initial link can arrive first).
  var attempts = 0;
  while (ComicSource.all().isEmpty && attempts < 50) {
    await Future.delayed(const Duration(milliseconds: 100));
    attempts++;
  }
  if (ComicSource.all().isEmpty) return false;

  final host = target.host.replaceFirst(RegExp(r'^www\.'), '');

  for (final source in ComicSource.all()) {
    final handler = source.linkHandler;
    if (handler == null || !handler.domains.contains(host)) continue;
    final id = handler.linkToId(target.toString());
    if (id == null || id.isEmpty) return false;

    // The navigator is set once the UI is up; wait briefly if needed.
    attempts = 0;
    while (App.mainNavigatorKey?.currentContext == null && attempts < 50) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }
    App.mainNavigatorKey?.currentContext?.to(() {
      return ComicPage(id: id, sourceKey: source.key);
    });
    return true;
  }
  return false;
}

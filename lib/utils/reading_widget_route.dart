import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/reading_widget.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/local_comics_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/handle_notification_route.dart';
import 'package:venera/utils/translations.dart';

typedef ReadingWidgetTarget = ({ReadingWidgetKind kind, String? id, int? type});

ReadingWidgetTarget? resolveReadingWidgetLink(Uri uri) {
  if (uri.scheme != 'venerax' ||
      uri.host != 'reading-widget' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.toString().length > 4096) {
    return null;
  }
  final kind = uri.path == '/read'
      ? ReadingWidgetKind.history
      : ReadingWidgetKind.values
            .where(
              (kind) =>
                  uri.path == '/${kind.name}' ||
                  uri.path == '/${kind.name}/read',
            )
            .firstOrNull;
  if (kind == null) return null;
  if (uri.path == '/${kind.name}' && !uri.hasQuery) {
    return (kind: kind, id: null, type: null);
  }
  if (!(uri.path == '/read' || uri.path == '/${kind.name}/read') ||
      uri.queryParametersAll.length != 2 ||
      uri.queryParametersAll['id']?.length != 1 ||
      uri.queryParametersAll['type']?.length != 1) {
    return null;
  }
  final id = uri.queryParameters['id'];
  final type = int.tryParse(uri.queryParameters['type'] ?? '');
  if (id == null || id.isEmpty || type == null) return null;
  return (kind: kind, id: id, type: type);
}

int _latestReadingWidgetTap = 0;

Future<bool> handleReadingWidgetLink(Uri uri) async {
  final target = resolveReadingWidgetLink(uri);
  if (target == null) return false;
  final tap = ++_latestReadingWidgetTap;
  final navigator = await waitForUnlockedMainNavigator();
  if (navigator == null || tap != _latestReadingWidgetTap) return true;
  revealMainNavigator(navigator);
  if (target.id != null) {
    final type = ComicType(target.type!);
    final local = App.local.isInitialized
        ? App.local.find(target.id!, type)
        : null;
    final comic = switch (target.kind) {
      ReadingWidgetKind.history =>
        HistoryManager()
            .getRecent()
            .where((item) => item.id == target.id && item.type == type)
            .firstOrNull,
      ReadingWidgetKind.local => local,
      ReadingWidgetKind.following || ReadingWidgetKind.updates =>
        readingWidgetFollowedComics()
            .where(
              (item) =>
                  item.id == target.id &&
                  item.type == type &&
                  (target.kind != ReadingWidgetKind.updates ||
                      item.hasNewUpdate == true),
            )
            .firstOrNull,
    };
    // A stale card must not reopen an item that was hidden, removed or blocked.
    if (comic != null && isReadingWidgetHistoryVisible(comic)) {
      if (local != null && local.status != LocalComicStatus.notDownloaded) {
        local.read();
        return true;
      }
      if (target.kind != ReadingWidgetKind.local &&
          type.comicSource?.loadComicInfo != null) {
        App.rootContext.to(
          () => ReaderWithLoading(id: comic.id, sourceKey: comic.sourceKey),
        );
        return true;
      }
    }
    navigator.context.showMessage(
      message: 'This comic is no longer available'.tl,
    );
  }
  navigator.context.to(
    () => switch (target.kind) {
      ReadingWidgetKind.history => const HistoryPage(),
      ReadingWidgetKind.local => const LocalComicsPage(),
      ReadingWidgetKind.following => const FollowUpdatesPage(showAll: true),
      ReadingWidgetKind.updates => const FollowUpdatesPage(),
    },
  );
  return true;
}

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/reading_widget.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/handle_notification_route.dart';
import 'package:venera/utils/translations.dart';

typedef ReadingWidgetTarget = ({String? id, int? type});

ReadingWidgetTarget? resolveReadingWidgetLink(Uri uri) {
  if (uri.scheme != 'venerax' ||
      uri.host != 'reading-widget' ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.toString().length > 4096) {
    return null;
  }
  if (uri.path == '/history' && !uri.hasQuery) return (id: null, type: null);
  if (uri.path != '/read' ||
      uri.queryParametersAll.length != 2 ||
      uri.queryParametersAll['id']?.length != 1 ||
      uri.queryParametersAll['type']?.length != 1) {
    return null;
  }
  final id = uri.queryParameters['id'];
  final type = int.tryParse(uri.queryParameters['type'] ?? '');
  if (id == null || id.isEmpty || type == null) return null;
  return (id: id, type: type);
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
    final history = HistoryManager()
        .getRecent()
        .where((item) => item.id == target.id && item.type == type)
        .firstOrNull;
    // A stale card must not reopen an item that was hidden, removed or blocked.
    if (history != null && isReadingWidgetHistoryVisible(history)) {
      final local = App.local.isInitialized
          ? App.local.find(target.id!, type)
          : null;
      if (local != null && local.status != LocalComicStatus.notDownloaded) {
        local.read();
        return true;
      }
      if (type.comicSource?.loadComicInfo != null) {
        navigator.context.to(
          () => ReaderWithLoading(id: history.id, sourceKey: history.sourceKey),
        );
        return true;
      }
    }
    navigator.context.showMessage(
      message: 'This comic is no longer available'.tl,
    );
  }
  navigator.context.to(() => const HistoryPage());
  return true;
}

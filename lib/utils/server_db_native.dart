import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';

class ServerHistoryPage {
  const ServerHistoryPage({required this.items, required this.total});

  final List<History> items;
  final int total;
}

class ServerDbClient {
  const ServerDbClient();

  Future<ServerHistoryPage?> listHistory({int limit = 100, int offset = 0}) {
    return Future.value(null);
  }

  Future<bool> upsertHistory(History history) {
    return Future.value(false);
  }

  Future<bool> deleteHistory(String id, ComicType type) {
    return Future.value(false);
  }

  Future<bool> clearHistory() {
    return Future.value(false);
  }
}

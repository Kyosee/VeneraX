import 'package:venera/foundation/sqlite_connection_web.dart';

Future<void> initPlatformServices() async {
  await initWebSqlite();
}

void initAndroidExtras() {}

Future<void> trySetHighRefreshRate() async {}

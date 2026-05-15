import 'package:display_mode/display_mode.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio_io.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';

Future<void> initPlatformServices() async {
  await Future.wait([_initRhttp(), SAFTaskWorker().init()]);
}

Future<void> _initRhttp() async {
  try {
    await nativeInitRhttp();
  } catch (e, s) {
    Log.error("Rhttp", "Failed to initialize rhttp/RustLib: $e\n$s");
  }
}

void initAndroidExtras() {
  handleLinks();
  handleTextShare();
}

Future<void> trySetHighRefreshRate() async {
  try {
    await FlutterDisplayMode.setHighRefreshRate();
  } catch (e) {
    Log.error("Display Mode", "Failed to set high refresh rate: $e");
  }
}

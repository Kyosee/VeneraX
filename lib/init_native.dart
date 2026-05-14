import 'package:display_mode/display_mode.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';

Future<void> initPlatformServices() async {
  await Future.wait([Rhttp.init(), SAFTaskWorker().init()]);
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

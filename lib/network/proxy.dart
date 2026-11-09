import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

Future<String?> getProxy() async {
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

Future<String?> _getProxy() async {
  if ((appdata.settings['proxy'] as String).removeAllBlank == "direct") {
    return null;
  }
  if (appdata.settings['proxy'] != "system") return appdata.settings['proxy'];

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  return parseSystemProxy(res);
}

String? parseSystemProxy(String value) {
  var authority = value.trim();
  if (authority.contains('=')) {
    final https = authority
        .split(';')
        .map((entry) => entry.trim())
        .where((entry) => entry.startsWith('https='))
        .firstOrNull;
    if (https == null) return null;
    authority = https.substring(6).trim();
  }
  if (authority.isEmpty || RegExp(r'[\s/\\?#@;]').hasMatch(authority)) {
    return null;
  }
  final uri = Uri.tryParse('//$authority');
  if (uri == null ||
      uri.host.isEmpty ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535) {
    return null;
  }
  return uri.authority;
}

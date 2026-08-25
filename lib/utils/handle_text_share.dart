import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/pages/aggregated_search_page.dart';
import 'package:venera/utils/app_links.dart';

bool _isHandling = false;

final _sharedUrlPattern = RegExp(
  r'''https?://[^\s<>"']+''',
  caseSensitive: false,
);

const _trailingSharedUrlPunctuation = '.,;:，。；：！？、';

String _trimSharedUrl(String value) {
  while (value.isNotEmpty &&
      _trailingSharedUrlPunctuation.contains(value[value.length - 1])) {
    value = value.substring(0, value.length - 1);
  }
  for (final pair in const [
    ('(', ')'),
    ('[', ']'),
    ('{', '}'),
    ('（', '）'),
    ('［', '］'),
    ('【', '】'),
    ('《', '》'),
    ('「', '」'),
    ('『', '』'),
  ]) {
    int count(String character) => value.split(character).length - 1;
    final opens = count(pair.$1);
    while (value.endsWith(pair.$2) && count(pair.$2) > opens) {
      value = value.substring(0, value.length - 1);
    }
  }
  return value;
}

@visibleForTesting
List<Uri> extractSharedHttpUris(String text) {
  final result = <Uri>[];
  final seen = <String>{};
  for (final match in _sharedUrlPattern.allMatches(text)) {
    final value = _trimSharedUrl(match.group(0)!);
    final uri = Uri.tryParse(value);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        !seen.add(uri.toString())) {
      continue;
    }
    result.add(uri);
  }
  return result;
}

@visibleForTesting
Future<bool> tryHandleSharedTextLinks(
  String text,
  Future<bool> Function(Uri uri) handleLink,
) async {
  for (final uri in extractSharedHttpUris(text)) {
    if (await handleLink(uri)) return true;
  }
  return false;
}

/// Handle text share event.
/// Supported source links open directly; other text falls back to search.
void handleTextShare() async {
  if (_isHandling) return;
  _isHandling = true;

  var channel = EventChannel('venera/text_share');
  await for (var event in channel.receiveBroadcastStream()) {
    if (App.mainNavigatorKey == null) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    if (event is String) {
      if (await tryHandleSharedTextLinks(event, handleAppLink)) continue;
      App.rootContext.to(() => AggregatedSearchPage(keyword: event));
    }
  }
}

import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

/// Translates recognized bubble texts through a user-configured
/// OpenAI-compatible chat endpoint.
///
/// The app ships with no endpoint, key or vendor — everything is supplied by
/// the user in settings, so translation quality is whatever model they point
/// it at. All bubbles of a page go out as ONE request (id + text list), which
/// both preserves cross-bubble context and keeps latency at one round-trip
/// per page.
abstract class LlmTranslator {
  static String get _rawUrl =>
      (appdata.settings['imageTranslationLlmUrl'] as String? ?? '').trim();

  static String get _apiKey =>
      (appdata.settings['imageTranslationLlmKey'] as String? ?? '').trim();

  static String get _model =>
      (appdata.settings['imageTranslationLlmModel'] as String? ?? '').trim();

  /// A key is optional on purpose: local gateways (ollama, lm-studio,
  /// one-api instances on LAN) often run without authentication.
  static bool get isConfigured => _rawUrl.isNotEmpty && _model.isNotEmpty;

  /// Whether just the URL is set — enough to try fetching the model list
  /// before the user has picked a model.
  static bool get baseUrlConfigured => _rawUrl.isNotEmpty;

  /// Accepts either a base URL ("https://host/v1") or a full chat-completions
  /// URL; normalizes to the latter.
  static String get _endpoint {
    var url = _rawUrl;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) {
      return url;
    }
    return '$url/chat/completions';
  }

  /// Base URL with any trailing '/chat/completions' and slashes stripped, so
  /// sibling endpoints (e.g. '/models') can be derived from it.
  static String get _baseUrl {
    var url = _rawUrl;
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) {
      url = url.substring(0, url.length - '/chat/completions'.length);
    }
    return url;
  }

  /// Fetches the model id list from the endpoint's `/models` (OpenAI-style).
  /// Returns the ids; throws with a readable message on failure so the UI can
  /// fall back to manual entry.
  static Future<List<String>> fetchModels() async {
    if (_rawUrl.isEmpty) {
      throw Exception('LLM API URL not configured');
    }
    var dio = AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    try {
      var response = await dio.get('$_baseUrl/models');
      if (response.statusCode != 200) {
        throw Exception(
          'Endpoint returned ${response.statusCode}: '
          '${_briefBody(response.data)}',
        );
      }
      var data = response.data;
      // OpenAI shape: {data: [{id: ...}, ...]}. Some gateways return a bare
      // list or {models:[...]} (ollama); tolerate all three.
      List<dynamic>? list;
      if (data is Map && data['data'] is List) {
        list = data['data'] as List;
      } else if (data is Map && data['models'] is List) {
        list = data['models'] as List;
      } else if (data is List) {
        list = data;
      }
      if (list == null) {
        throw Exception('Unexpected /models response');
      }
      var ids = <String>[];
      for (var item in list) {
        if (item is Map) {
          var id = item['id'] ?? item['name'] ?? item['model'];
          if (id is String && id.isNotEmpty) ids.add(id);
        } else if (item is String && item.isNotEmpty) {
          ids.add(item);
        }
      }
      ids.sort();
      return ids;
    } finally {
      dio.close();
    }
  }

  static String _targetName(String targetLang) {
    return switch (targetLang) {
      'zh' => '简体中文',
      'zh-TW' => '繁体中文（台湾用语习惯）',
      'en' => 'English',
      _ => targetLang,
    };
  }

  /// Translates [texts] into [targetLang]. The result list is aligned with
  /// the input; entries the model refused/failed are empty strings.
  static Future<List<String>> translateBatch(
    List<String> texts,
    String targetLang,
  ) async {
    if (texts.isEmpty) return const [];
    var systemPrompt =
        '你是专业的漫画对白翻译引擎。将用户提供的 JSON 数组中每个对象的 text '
        '字段翻译成${_targetName(targetLang)}。要求：符合漫画口语风格，简洁自然；'
        '拟声词按含义意译；OCR 造成的少量错字请按上下文推断原意；'
        '人名与专有名词保持前后一致。'
        '只输出 JSON 数组，格式为 [{"id":0,"text":"译文"}]，'
        '每个 id 恰好出现一次，不要输出任何其他内容。';
    var payload = jsonEncode([
      for (var i = 0; i < texts.length; i++) {'id': i, 'text': texts[i]},
    ]);

    var dio = AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 120),
        headers: {
          'Content-Type': 'application/json',
          if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    Object? lastError;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        var response = await dio.post(
          _endpoint,
          data: {
            'model': _model,
            // No sampling params: some endpoints only accept their model's
            // fixed values (e.g. "only 1 is allowed") and reject the request
            // outright; the server-side default works everywhere.
            'messages': [
              {'role': 'system', 'content': systemPrompt},
              {'role': 'user', 'content': payload},
            ],
          },
        );
        if (response.statusCode != 200) {
          throw Exception(
            'LLM endpoint returned ${response.statusCode}: '
            '${_briefBody(response.data)}',
          );
        }
        var content =
            response.data['choices']?[0]?['message']?['content'] as String?;
        if (content == null || content.isEmpty) {
          throw Exception('LLM response has no content');
        }
        return _parse(content, texts.length);
      } catch (e) {
        lastError = e;
        Log.warning('Image Translation', 'LLM request failed: $e');
      }
    }
    throw Exception('LLM translation failed: $lastError');
  }

  /// Extracts the JSON array from the model output (tolerating code fences
  /// and surrounding prose) and aligns it by id.
  static List<String> _parse(String content, int count) {
    var start = content.indexOf('[');
    var end = content.lastIndexOf(']');
    if (start == -1 || end <= start) {
      throw Exception('LLM response is not a JSON array');
    }
    var items = jsonDecode(content.substring(start, end + 1));
    if (items is! List) {
      throw Exception('LLM response is not a JSON array');
    }
    var results = List.filled(count, '');
    for (var item in items) {
      if (item is! Map) continue;
      var id = item['id'];
      var text = item['text'];
      if (id is int && id >= 0 && id < count && text is String) {
        results[id] = text.trim();
      }
    }
    return results;
  }

  static String _briefBody(Object? body) {
    var text = body.toString();
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}

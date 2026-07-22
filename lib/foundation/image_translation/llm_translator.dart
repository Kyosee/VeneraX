import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

/// One page's translation outcome: the per-bubble texts (aligned with the
/// input, empty where the model refused/failed) plus any proper-noun
/// renderings the model reported for this page, which the caller folds back
/// into the comic's glossary so later pages/chapters stay consistent.
class LlmTranslationResult {
  const LlmTranslationResult(this.texts, this.glossary);

  final List<String> texts;

  /// source term -> agreed translation, discovered on this page.
  final Map<String, String> glossary;
}

/// Translates recognized bubble texts through a user-configured
/// OpenAI-compatible chat endpoint.
///
/// The app ships with no endpoint, key or vendor — everything is supplied by
/// the user in settings, so translation quality is whatever model they point
/// it at. All bubbles of a page go out as ONE request, together with the
/// comic's running glossary so names stay consistent across pages/chapters.
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

  /// Translates [texts] into [targetLang]. [glossary] carries agreed
  /// translations of names/proper nouns established on earlier pages of the
  /// same comic; it is sent to the model as a must-follow reference so a
  /// character's name is rendered the same way across pages and chapters.
  ///
  /// The returned [LlmTranslationResult] holds the aligned translations plus
  /// any new name/proper-noun pairs the model reported for this page, which
  /// the caller merges back into the comic's glossary.
  static Future<LlmTranslationResult> translateBatch(
    List<String> texts,
    String targetLang, {
    Map<String, String> glossary = const {},
  }) async {
    if (texts.isEmpty) {
      return const LlmTranslationResult([], {});
    }
    var target = _targetName(targetLang);
    var systemPrompt =
        '你是专业的漫画对白翻译引擎。将用户提供的 JSON 对象中 lines 数组里每个元素的 '
        'text 字段翻译成$target。要求：符合漫画口语风格，简洁自然；'
        '拟声词按含义意译；OCR 造成的少量错字请按上下文推断原意。\n'
        '同一部漫画跨页阅读，人名、地名、招式名等专有名词的译法必须前后一致：'
        'glossary 字段给出的是已确定的译法（键为原文，值为译文），出现时必须沿用。\n'
        '同时，请把本次新出现（glossary 中没有）的人名与专有名词，连同你采用的译法，'
        '收集到 names 字段返回，供后续页面保持一致。\n'
        '只输出一个 JSON 对象，格式为 '
        '{"lines":[{"id":0,"text":"译文"}],"names":{"原文":"译文"}}，'
        'lines 中每个 id 恰好出现一次，不要输出任何其他内容。';
    var payload = jsonEncode({
      if (glossary.isNotEmpty) 'glossary': glossary,
      'lines': [
        for (var i = 0; i < texts.length; i++) {'id': i, 'text': texts[i]},
      ],
    });

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

  /// Parses the model output into aligned translations plus reported names.
  ///
  /// The prompt asks for a JSON object
  /// `{"lines":[{"id,"text"}],"names":{...}}`, but models sometimes return a
  /// bare `[{"id","text"}]` array (ignoring the wrapper). Both shapes are
  /// accepted so a slightly non-compliant model still works; a bare array
  /// simply yields no new glossary entries.
  static LlmTranslationResult _parse(String content, int count) {
    var object = _extractJsonObject(content);
    List<dynamic>? lines;
    var names = <String, String>{};
    if (object is Map) {
      if (object['lines'] is List) {
        lines = object['lines'] as List;
      }
      if (object['names'] is Map) {
        (object['names'] as Map).forEach((k, v) {
          if (k is String && v is String && k.trim().isNotEmpty && v.trim().isNotEmpty) {
            names[k.trim()] = v.trim();
          }
        });
      }
    } else if (object is List) {
      lines = object;
    }
    if (lines == null) {
      throw Exception('LLM response is not in the expected JSON shape');
    }
    var results = List.filled(count, '');
    for (var item in lines) {
      if (item is! Map) continue;
      var id = item['id'];
      var text = item['text'];
      if (id is int && id >= 0 && id < count && text is String) {
        results[id] = text.trim();
      }
    }
    return LlmTranslationResult(results, names);
  }

  /// Pulls the first JSON object or array out of [content], tolerating code
  /// fences and surrounding prose. Prefers an object (the requested shape);
  /// falls back to an array.
  static dynamic _extractJsonObject(String content) {
    var objStart = content.indexOf('{');
    var objEnd = content.lastIndexOf('}');
    var arrStart = content.indexOf('[');
    var arrEnd = content.lastIndexOf(']');
    // An object wrapping the array has its '{' before the '['.
    if (objStart != -1 && objEnd > objStart &&
        (arrStart == -1 || objStart < arrStart)) {
      try {
        return jsonDecode(content.substring(objStart, objEnd + 1));
      } catch (_) {
        // fall through to array
      }
    }
    if (arrStart != -1 && arrEnd > arrStart) {
      return jsonDecode(content.substring(arrStart, arrEnd + 1));
    }
    throw Exception('LLM response has no JSON payload');
  }

  static String _briefBody(Object? body) {
    var text = body.toString();
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}

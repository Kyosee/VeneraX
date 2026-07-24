import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_prompt.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/app_dio.dart';

export 'package:venera/foundation/image_translation/translation_prompt.dart'
    show LlmTranslationResult;

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

  /// Re-exposed so callers that already depend on [LlmTranslator] (e.g. the
  /// service's glossary sanitizer) keep working after the shared prompt/format
  /// logic moved to [TranslationPrompt].
  static bool isValidGlossaryTerm(String source, String translation) =>
      TranslationPrompt.isValidGlossaryTerm(source, translation);

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
    var systemPrompt = TranslationPrompt.systemPrompt(targetLang);
    var payload = TranslationPrompt.userPayload(texts, glossary: glossary);

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
        return TranslationPrompt.parse(content, texts.length);
      } catch (e) {
        lastError = e;
        Log.warning('Image Translation', 'LLM request failed: $e');
      }
    }
    throw Exception('LLM translation failed: $lastError');
  }

  static String _briefBody(Object? body) {
    var text = body.toString();
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}

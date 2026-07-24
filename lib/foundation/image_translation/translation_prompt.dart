import 'dart:convert';

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

/// The prompt/format contract shared by every translation engine (the
/// user-configured API endpoint and the on-device local model alike).
///
/// Keeping the system prompt, request payload and response parsing in one
/// place means both engines send the model the exact same instructions and
/// read back the exact same JSON shape — so a comic reads consistently no
/// matter which engine produced a given page, and the glossary/name-tracking
/// behaviour is identical.
abstract class TranslationPrompt {
  /// Human-readable target-language name for the system prompt.
  static String targetName(String targetLang) {
    return switch (targetLang) {
      'zh' => '简体中文',
      'zh-TW' => '繁体中文（台湾用语习惯）',
      'en' => 'English',
      'ja' => '日本語',
      'ko' => '한국어',
      'fr' => 'Français',
      'de' => 'Deutsch',
      'es' => 'Español',
      'ru' => 'Русский',
      _ => targetLang,
    };
  }

  /// The system prompt instructing the model how to translate comic bubbles,
  /// keep names consistent via the running glossary, and report new names.
  static String systemPrompt(String targetLang) {
    var target = targetName(targetLang);
    return '你是资深的二次元漫画本地化译者，热爱 ACGN 文化。将用户提供的 JSON 对象中 lines '
        '数组里每个元素的 text 字段翻译成$target。要求：像真人说话一样自然口语化，'
        '贴合二次元漫画的语气和氛围，避免生硬的机翻腔；'
        '在符合角色人设和场景的前提下，可以适度使用当下流行的二次元/网络用语，'
        '但不要硬凑或滥用，宁可平实也不要出戏；'
        '语气词、拟声词按含义和情绪意译；OCR 造成的少量错字请按上下文推断原意。\n'
        '同一部漫画跨页阅读，人名、地名、招式名等专有名词的译法必须前后一致：'
        'glossary 字段给出的是已确定的译法（键为原文，值为译文），出现时必须沿用。\n'
        '同时，请把本次新出现（glossary 中没有）的人名、地名、招式/组织名等专有名词，'
        '连同你采用的译法，收集到 names 字段返回，供后续页面保持一致。'
        'names 只收录简短的专有名词（通常不超过 8 个字），'
        '不要收录整句对白、拟声词、普通词组、数字或网址。\n'
        '只输出一个 JSON 对象，格式为 '
        '{"lines":[{"id":0,"text":"译文"}],"names":{"原文":"译文"}}，'
        'lines 中每个 id 恰好出现一次，不要输出任何其他内容。';
  }

  /// The JSON user message: the bubble texts to translate plus any agreed
  /// glossary entries the model must follow.
  static String userPayload(
    List<String> texts, {
    Map<String, String> glossary = const {},
  }) {
    return jsonEncode({
      if (glossary.isNotEmpty) 'glossary': glossary,
      'lines': [
        for (var i = 0; i < texts.length; i++) {'id': i, 'text': texts[i]},
      ],
    });
  }

  /// Parses model output into aligned translations plus reported names.
  ///
  /// The prompt asks for a JSON object
  /// `{"lines":[{"id","text"}],"names":{...}}`, but models sometimes return a
  /// bare `[{"id","text"}]` array (ignoring the wrapper). Both shapes are
  /// accepted so a slightly non-compliant model still works; a bare array
  /// simply yields no new glossary entries.
  static LlmTranslationResult parse(String content, int count) {
    var object = _extractJsonObject(content);
    List<dynamic>? lines;
    var names = <String, String>{};
    if (object is Map) {
      if (object['lines'] is List) {
        lines = object['lines'] as List;
      }
      if (object['names'] is Map) {
        (object['names'] as Map).forEach((k, v) {
          if (k is String && v is String) {
            var key = k.trim();
            var value = v.trim();
            if (isValidGlossaryTerm(key, value)) {
              names[key] = value;
            }
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

  /// Whether a reported name/translation pair is worth keeping in the glossary.
  /// The glossary exists only for short proper nouns (names, places, techniques)
  /// that must stay consistent across pages; it is sent with every request, so
  /// it must stay small. Models occasionally return whole sentences, URLs or
  /// numbers as "names" — those bloat the prompt without helping consistency,
  /// so they are rejected here as a backstop to the prompt's own instruction.
  /// Also used by the service to sanitize a glossary loaded from an earlier
  /// version that had no such filtering.
  static bool isValidGlossaryTerm(String source, String translation) {
    if (source.isEmpty || translation.isEmpty) return false;
    // Proper nouns are short. Anything long is almost certainly a sentence.
    if (source.length > 16 || translation.length > 16) return false;
    for (var s in [source, translation]) {
      // URLs / emails / paths — never proper nouns, and long enough to bloat.
      if (_urlLike.hasMatch(s)) return false;
      // Sentence-like: contains terminal/comma punctuation or whitespace runs
      // typical of a clause rather than a single term.
      if (_sentenceLike.hasMatch(s)) return false;
    }
    // Pure numbers (page numbers, counts) carry no naming to keep consistent.
    if (_numericOnly.hasMatch(source)) return false;
    return true;
  }

  static final _urlLike = RegExp(
    r'https?://|www\.|@|[./\\][a-zA-Z]{2,}|\.(com|net|org|io|cn|jp)\b',
    caseSensitive: false,
  );

  static final _sentenceLike = RegExp(r'[。！？.!?、,，；;]|\s{1,}\S+\s');

  static final _numericOnly = RegExp(r'^[0-9\s.,]+$');

  /// Pulls the first JSON object or array out of [content], tolerating code
  /// fences and surrounding prose. Prefers an object (the requested shape);
  /// falls back to an array.
  static dynamic _extractJsonObject(String content) {
    var objStart = content.indexOf('{');
    var objEnd = content.lastIndexOf('}');
    var arrStart = content.indexOf('[');
    var arrEnd = content.lastIndexOf(']');
    // An object wrapping the array has its '{' before the '['.
    if (objStart != -1 &&
        objEnd > objStart &&
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
}

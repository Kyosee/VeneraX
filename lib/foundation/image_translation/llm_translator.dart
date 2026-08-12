import 'dart:convert';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/rate_limiter.dart';
import 'package:venera/foundation/image_translation/translation_performance_config.dart';
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

/// One user-configured OpenAI-compatible LLM service: a stable [id], a
/// display [name], and the endpoint/credential/model triple that used to be
/// the app's single global config. Users keep several of these and pick which
/// one is active, so they can switch between vendors (or a paid account and a
/// LAN gateway) without re-typing settings each time.
class LlmProvider {
  LlmProvider({
    required this.id,
    required this.name,
    required this.url,
    required this.key,
    required this.model,
  });

  final String id;
  final String name;
  final String url;
  final String key;
  final String model;

  LlmProvider copyWith({
    String? name,
    String? url,
    String? key,
    String? model,
  }) {
    return LlmProvider(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      key: key ?? this.key,
      model: model ?? this.model,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'key': key,
    'model': model,
  };

  static LlmProvider? fromJson(dynamic json) {
    if (json is! Map) return null;
    var id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return LlmProvider(
      id: id,
      name: (json['name'] as String?)?.trim() ?? '',
      url: (json['url'] as String?)?.trim() ?? '',
      key: (json['key'] as String?)?.trim() ?? '',
      model: (json['model'] as String?)?.trim() ?? '',
    );
  }
}

/// Common OpenAI-compatible endpoints for the beginner setup flow.
class LlmProviderTemplate {
  const LlmProviderTemplate({
    required this.id,
    required this.name,
    required this.url,
  });

  final String id;
  final String name;
  final String url;

  static const values = <LlmProviderTemplate>[
    LlmProviderTemplate(
      id: 'openai',
      name: 'OpenAI',
      url: 'https://api.openai.com/v1',
    ),
    LlmProviderTemplate(
      id: 'deepseek',
      name: 'DeepSeek',
      url: 'https://api.deepseek.com',
    ),
    LlmProviderTemplate(
      id: 'siliconflow',
      name: 'SiliconFlow',
      url: 'https://api.siliconflow.cn/v1',
    ),
    LlmProviderTemplate(
      id: 'openrouter',
      name: 'OpenRouter',
      url: 'https://openrouter.ai/api/v1',
    ),
  ];

  static LlmProviderTemplate? byId(String id) {
    for (var template in values) {
      if (template.id == id) return template;
    }
    return null;
  }

  static String idForUrl(String url) {
    var normalized = LlmTranslator.baseUrlOf(url).toLowerCase();
    for (var template in values) {
      if (LlmTranslator.baseUrlOf(template.url).toLowerCase() == normalized) {
        return template.id;
      }
    }
    return 'custom';
  }
}

/// Reads and writes the user's list of LLM providers and which one is active.
///
/// The list is stored in settings (and synced across devices as a whole), so
/// this is the single source of truth the translator reads from. All mutating
/// helpers persist via [appdata.saveData] and notify listeners so open
/// settings pages refresh.
abstract class LlmProviderStore {
  static const _listKey = 'imageTranslationProviders';
  static const _activeKey = 'imageTranslationActiveProviderId';

  static List<LlmProvider> get providers {
    var raw = appdata.settings[_listKey];
    if (raw is! List) return const [];
    var result = <LlmProvider>[];
    for (var item in raw) {
      var provider = LlmProvider.fromJson(item);
      if (provider != null) result.add(provider);
    }
    return result;
  }

  static String get activeId =>
      (appdata.settings[_activeKey] as String? ?? '').trim();

  /// The active provider, or the first configured one as a fallback so a list
  /// that lost its active pointer still translates. Null when the list is empty.
  static LlmProvider? get active {
    var all = providers;
    if (all.isEmpty) return null;
    var id = activeId;
    for (var p in all) {
      if (p.id == id) return p;
    }
    return all.first;
  }

  static void _persist(List<LlmProvider> list) {
    appdata.settings[_listKey] = [for (var p in list) p.toJson()];
  }

  /// Adds [provider] and returns it. Becomes active if none was set.
  static void add(LlmProvider provider) {
    var list = providers..add(provider);
    _persist(list);
    if (active == null || activeId.isEmpty) {
      appdata.settings[_activeKey] = provider.id;
    }
    appdata.saveData();
  }

  static void update(LlmProvider provider) {
    var list = providers;
    var index = list.indexWhere((p) => p.id == provider.id);
    if (index == -1) return;
    list[index] = provider;
    _persist(list);
    appdata.saveData();
  }

  static void remove(String id) {
    var list = providers..removeWhere((p) => p.id == id);
    _persist(list);
    // Reassign the active pointer if the removed provider was selected.
    if (activeId == id) {
      appdata.settings[_activeKey] = list.isEmpty ? '' : list.first.id;
    }
    appdata.saveData();
  }

  static void setActive(String id) {
    appdata.settings[_activeKey] = id;
    appdata.saveData();
  }

  /// One-time migration from the legacy single-config keys
  /// (imageTranslationLlmUrl/Key/Model) to the provider list. Runs at startup;
  /// only fires when no providers exist yet and a legacy URL is present. The
  /// legacy keys are left untouched so an older app version can still read them.
  static void migrateLegacyIfNeeded() {
    if (providers.isNotEmpty) return;
    var url = (appdata.settings['imageTranslationLlmUrl'] as String? ?? '')
        .trim();
    if (url.isEmpty) return;
    var provider = LlmProvider(
      id: const Uuid().v4(),
      name: 'LLM',
      url: url,
      key: (appdata.settings['imageTranslationLlmKey'] as String? ?? '').trim(),
      model: (appdata.settings['imageTranslationLlmModel'] as String? ?? '')
          .trim(),
    );
    _persist([provider]);
    appdata.settings[_activeKey] = provider.id;
    // sync:false — this runs during init before the sync layer is ready, and
    // a migration is not a user edit that should trigger an upload.
    appdata.saveData(false);
  }
}

/// Translates recognized bubble texts through a user-configured
/// OpenAI-compatible chat endpoint.
///
/// The app ships with no endpoint, key or vendor — everything is supplied by
/// the user in settings, so translation quality is whatever model they point
/// it at. All bubbles of a page go out as ONE request, together with the
/// comic's running glossary so names stay consistent across pages/chapters.
abstract class LlmTranslator {
  /// Shared, per-provider concurrency limiter. Both the reader's inline
  /// translation and background pre-translation call [translateBatch], so they
  /// share this gate — neither path can overrun the endpoint on its own. The
  /// effective limit is min(user setting, AIMD estimate); AIMD backs off on a
  /// 429/503 and recovers on success.
  static final _aimd = AimdController(min: 1, max: 4);
  static final _gate = ConcurrencyGate((bucket) {
    var userMax = TranslationPerformanceConfig.effective.llmConcurrency.clamp(
      1,
      4,
    );
    return math.min(userMax, _aimd.limitFor(bucket));
  });

  /// Hard ceiling for one translation request, transport level included.
  ///
  /// A slow model on a long batch legitimately needs a minute or two, so this is
  /// generous — but it must exist. The request holds a [_gate] slot while in
  /// flight, so an unbounded one does not just lose its own page: it permanently
  /// removes a concurrency slot, and once every slot is held by a stalled request
  /// no further page can start. Background pre-translation, which commits page
  /// counts in strict order, then freezes at zero visible progress (#176).
  static const requestTimeout = Duration(minutes: 3);

  /// Wall-clock ceiling for one [translateBatch] call including all its retries.
  /// Bounds the total time a single call can occupy a concurrency slot.
  static const totalRetryBudget = Duration(minutes: 6);

  /// How long a caller may wait for a free concurrency slot before giving up.
  /// Deliberately much larger than [totalRetryBudget] so a normal queue never
  /// trips it; it exists purely to break a slot that was never released.
  static const _slotWaitBackstop = Duration(minutes: 30);

  static String get _rawUrl => (LlmProviderStore.active?.url ?? '').trim();

  static String get _apiKey => (LlmProviderStore.active?.key ?? '').trim();

  static String get _model => (LlmProviderStore.active?.model ?? '').trim();

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

  /// Strips trailing slashes and a trailing '/chat/completions' from [rawUrl]
  /// so sibling endpoints (e.g. '/models') can be derived from any accepted
  /// URL shape. Shared by the active-provider getter and the ad-hoc fetch used
  /// while editing a not-yet-active provider.
  static String baseUrlOf(String rawUrl) {
    var url = rawUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) {
      url = url.substring(0, url.length - '/chat/completions'.length);
    }
    return url;
  }

  static bool isValidBaseUrl(String rawUrl) {
    var uri = Uri.tryParse(rawUrl.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// Fetches the model id list from the endpoint's `/models` (OpenAI-style).
  /// Returns the ids; throws with a readable message on failure so the UI can
  /// fall back to manual entry.
  ///
  /// [url]/[key] default to the active provider's, but the provider-editing UI
  /// passes the values being edited so the model list matches the provider the
  /// user is configuring, not whichever one is currently active.
  static Future<List<String>> fetchModels({String? url, String? key}) async {
    var rawUrl = (url ?? _rawUrl).trim();
    var apiKey = (key ?? _apiKey).trim();
    if (rawUrl.isEmpty) {
      throw Exception('LLM API URL not configured');
    }
    var baseUrl = baseUrlOf(rawUrl);
    const probeTimeout = Duration(seconds: 30);
    var dio = AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: probeTimeout,
        headers: {if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey'},
        validateStatus: (status) => status != null && status < 500,
      ),
      probeTimeout,
    );
    try {
      var response = await dio.get('$baseUrl/models');
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
      'ja' => '日本語',
      'ko' => '한국어',
      'fr' => 'Français',
      'de' => 'Deutsch',
      'es' => 'Español',
      'ru' => 'Русский',
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
        '你是资深的二次元漫画本地化译者，热爱 ACGN 文化。将用户提供的 JSON 对象中 lines '
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
    var payload = jsonEncode({
      if (glossary.isNotEmpty) 'glossary': glossary,
      'lines': [
        for (var i = 0; i < texts.length; i++) {'id': i, 'text': texts[i]},
      ],
    });

    var dio = AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: requestTimeout,
        headers: {
          'Content-Type': 'application/json',
          if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
      // Hard transport-level bound. Without it a stalled endpoint holds the
      // request open forever; because the request is made while holding a slot
      // of [_gate], two such requests starve every later page and background
      // pre-translation stops reporting progress entirely (#176).
      requestTimeout,
    );
    var bucket = LlmProviderStore.active?.id ?? 'default';
    // Backstop for a leaked slot, NOT a congestion limit. Queueing behind other
    // pages is normal and must be allowed to wait: with the limit backed off to
    // 1, several queued callers each taking up to [totalRetryBudget] can add up,
    // so this is set far above any legitimate wait. It only ever fires if a slot
    // is never released at all, and then fails one page instead of silently
    // freezing every page behind it forever.
    await _gate.acquire(bucket, maxWait: _slotWaitBackstop);
    try {
      const maxAttempts = 6;
      // Retries share one wall-clock budget. Per-attempt bounds alone are not
      // enough: 6 attempts each allowed [requestTimeout] would let a dead
      // endpoint hold a concurrency slot for the better part of an hour, which
      // is the stall this fix is meant to remove. Whichever limit is hit first
      // wins, and the page is reported failed so a later retry pass can redo it.
      var giveUpAt = DateTime.now().add(totalRetryBudget);
      Object? lastError;
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        HttpErrorClass? cls;
        Duration? retryAfter;
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
          var status = response.statusCode ?? 0;
          if (status == 200) {
            var content =
                response.data['choices']?[0]?['message']?['content'] as String?;
            if (content == null || content.isEmpty) {
              throw Exception('LLM response has no content');
            }
            _aimd.onSuccess(bucket);
            return _parse(content, texts.length);
          }
          lastError = Exception(
            'LLM endpoint returned $status: ${_briefBody(response.data)}',
          );
          cls = classifyStatus(status);
          retryAfter = parseRetryAfter(response.headers.value('retry-after'));
        } on DioException catch (e) {
          lastError = e;
          var status = e.response?.statusCode;
          cls = status != null
              ? classifyStatus(status)
              : HttpErrorClass.transient;
          retryAfter = parseRetryAfter(
            e.response?.headers.value('retry-after'),
          );
          Log.warning('Image Translation', 'LLM request failed: $e');
        } catch (e) {
          // Parse/other unexpected error: allow a couple of retries.
          lastError = e;
          cls = HttpErrorClass.transient;
          Log.warning('Image Translation', 'LLM request failed: $e');
        }
        // Decide retry vs fail OUTSIDE the try, so a fast-fail doesn't get
        // swallowed by the catch above.
        if (cls == HttpErrorClass.clientError || cls == HttpErrorClass.fatal) {
          break; // bad model/auth: retrying won't help
        }
        if (cls == HttpErrorClass.rateLimited) {
          _aimd.onRateLimited(bucket);
        }
        var wait = backoff(attempt, retryAfter: retryAfter);
        // Stop if the budget is already spent, or if sleeping would overrun it.
        if (DateTime.now().add(wait).isAfter(giveUpAt)) {
          break;
        }
        await Future.delayed(wait);
      }
      throw Exception('LLM translation failed: $lastError');
    } finally {
      _gate.release(bucket);
    }
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

  static String _briefBody(Object? body) {
    var text = body.toString();
    return text.length > 200 ? text.substring(0, 200) : text;
  }
}

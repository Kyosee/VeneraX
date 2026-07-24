import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/local_llm/llama_ffi.dart';
import 'package:venera/foundation/image_translation/local_llm/local_llm_models.dart';
import 'package:venera/foundation/image_translation/local_llm/local_llm_worker.dart';
import 'package:venera/foundation/image_translation/translation_prompt.dart';

/// The translation back-ends the app can route a request to.
enum TranslationEngineKind {
  /// User-configured OpenAI-compatible endpoint (network, uses the user's
  /// tokens). The original — and default — engine.
  api,

  /// On-device GGUF model via llama.cpp (offline, no tokens, bounded by the
  /// device's memory/compute).
  local,
}

/// Single entry point every caller uses to translate a page's bubbles,
/// regardless of which engine is active.
///
/// Both engines speak the exact same prompt/format contract
/// ([TranslationPrompt]) and return the same [LlmTranslationResult], so the
/// pipeline and pre-translation paths don't branch on the engine — they call
/// [translateBatch] and get aligned texts plus discovered glossary entries
/// either way. Which engine runs is a single per-device setting.
abstract class TranslationEngine {
  static TranslationEngineKind get kind {
    return appdata.settings['imageTranslationEngine'] == 'local'
        ? TranslationEngineKind.local
        : TranslationEngineKind.api;
  }

  static String? get _localModelId =>
      appdata.settings['imageTranslationLocalModel'] as String?;

  /// Whether the on-device engine's native runtime (`venera_llama`) is present
  /// in this build. It is only compiled where the plugin is registered, so on
  /// platforms/builds without it the local engine can't run — the UI uses this
  /// to hide or disable the option instead of letting a user pick it, download
  /// gigabytes of model, and then hit a load failure at translate time.
  static bool get isLocalRuntimeAvailable => LlamaFfi.isAvailable;

  /// Whether the active engine is fully configured and ready to translate.
  /// (Detection/OCR-model readiness is checked separately by the service; this
  /// covers only the translation back-end.)
  static bool get isReady {
    switch (kind) {
      case TranslationEngineKind.api:
        return LlmTranslator.isConfigured;
      case TranslationEngineKind.local:
        return isLocalRuntimeAvailable &&
            LocalLlmModels.active(_localModelId) != null;
    }
  }

  /// The active engine's per-page concurrency. The API engine overlaps a
  /// second page's OCR with the first's network wait; the local engine holds a
  /// single resident model and must run one page at a time.
  static int get maxConcurrent {
    return kind == TranslationEngineKind.local ? 1 : 2;
  }

  /// Translates [texts] into [targetLang] through the active engine, folding in
  /// the comic's running [glossary] for name consistency. Aligned 1:1 with the
  /// input; entries are empty where the model refused or failed.
  static Future<LlmTranslationResult> translateBatch(
    List<String> texts,
    String targetLang, {
    Map<String, String> glossary = const {},
  }) async {
    if (texts.isEmpty) {
      return const LlmTranslationResult([], {});
    }
    switch (kind) {
      case TranslationEngineKind.api:
        return LlmTranslator.translateBatch(
          texts,
          targetLang,
          glossary: glossary,
        );
      case TranslationEngineKind.local:
        if (!isLocalRuntimeAvailable) {
          throw Exception(
            'On-device translation is not available on this platform',
          );
        }
        var model = LocalLlmModels.active(_localModelId);
        if (model == null) {
          throw Exception('No local translation model is installed');
        }
        return LocalLlmWorker.instance.translateBatch(
          texts,
          targetLang,
          modelPath: model.filePath,
          template: model.template,
          contextSize: model.contextSize,
          glossary: glossary,
        );
    }
  }

  /// Releases whatever native resources the active engine holds while idle.
  /// For the local engine this frees the resident model (~1GB); the API engine
  /// holds nothing, so it's a no-op.
  static void releaseIfIdle() {
    LocalLlmWorker.instance.release();
  }
}

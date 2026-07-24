import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_translation/local_llm/local_llm_worker.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/utils/io.dart';

/// How well a device can be expected to run a given local model. Purely a
/// PERFORMANCE fit — whether the device has the memory/compute to run it — and
/// deliberately NOT a judgement of translation quality or content. The UI
/// shows this so a user knows what their hardware can handle before paying a
/// ~1GB download; it never recommends a model for what it translates.
enum ModelFit {
  /// Comfortably within the device's memory budget.
  good,

  /// Runnable but close to the memory ceiling; may be slow or risk pressure.
  tight,

  /// Very likely to fail to load or be killed by the OS for memory.
  insufficient,
}

/// A downloadable on-device translation LLM (a single GGUF file plus the
/// metadata the runtime and the recommender need).
class LocalLlmModel {
  const LocalLlmModel({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.urls,
    required this.approxSizeBytes,
    required this.template,
    required this.minRecommendedRamBytes,
    required this.tightRamBytes,
    this.contextSize = 4096,
  });

  final String id;

  /// Shown in the model list (e.g. "Qwen2.5 1.5B Instruct").
  final String displayName;
  final String fileName;

  /// Download fallback chain; `{hf}` is replaced with the configured endpoint.
  final List<String> urls;
  final int approxSizeBytes;
  final ChatTemplate template;

  /// RAM (total physical) at or above which this model is a comfortable fit.
  final int minRecommendedRamBytes;

  /// RAM below which the model is considered insufficient (won't fit); between
  /// this and [minRecommendedRamBytes] the fit is "tight".
  final int tightRamBytes;

  /// Token context window to load the model with.
  final int contextSize;

  String get directory =>
      FilePath.join(App.dataPath, 'translation_models', 'llm', id);

  String get filePath => FilePath.join(directory, fileName);

  bool get isInstalled {
    var f = File(filePath);
    return f.existsSync() && f.lengthSync() > 0;
  }

  /// As a [ModelComponent] so the existing [TranslationModelStore] download /
  /// progress / mirror-fallback machinery can install it unchanged.
  ModelComponent get asComponent => ModelComponent(
    id: 'llm/$id',
    approxSizeBytes: approxSizeBytes,
    files: [ModelFile(fileName, urls)],
  );
}

/// Registry of the local translation LLMs offered for download.
///
/// All are public, permissively-licensed GGUF releases fetched from their
/// official repositories; nothing is bundled, so installing the app stays
/// lightweight until the user opts into on-device translation.
///
/// Preview scope: a small general model that fits most phones and a slightly
/// larger one for higher-memory devices. GPU offload (Metal on Apple) is used
/// where available so these stay usable on mobile.
abstract class LocalLlmModels {
  /// ~1GB. Fits comfortably on 6GB+ devices; the safe default on mobile.
  static const qwen15b = LocalLlmModel(
    id: 'qwen2.5-1.5b-instruct-q4',
    displayName: 'Qwen2.5 1.5B Instruct (Q4_K_M)',
    fileName: 'model.gguf',
    urls: [
      '{hf}/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf',
    ],
    approxSizeBytes: 1120000000,
    template: ChatTemplate.chatml,
    minRecommendedRamBytes: 6 * 1024 * 1024 * 1024,
    tightRamBytes: 4 * 1024 * 1024 * 1024,
    contextSize: 4096,
  );

  /// ~500MB. For low-memory devices where the 1.5B is too tight. Lower quality
  /// but the point is that it loads at all.
  static const qwen05b = LocalLlmModel(
    id: 'qwen2.5-0.5b-instruct-q4',
    displayName: 'Qwen2.5 0.5B Instruct (Q4_K_M)',
    fileName: 'model.gguf',
    urls: [
      '{hf}/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf',
    ],
    approxSizeBytes: 400000000,
    template: ChatTemplate.chatml,
    minRecommendedRamBytes: 3 * 1024 * 1024 * 1024,
    tightRamBytes: 2 * 1024 * 1024 * 1024,
    contextSize: 4096,
  );

  static const all = [qwen15b, qwen05b];

  static LocalLlmModel? find(String id) {
    for (var m in all) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// The installed model to actually run: the user's explicit choice if it is
  /// installed, else the first installed model (so the engine still works if
  /// they downloaded one without picking it). Null when none is installed.
  static LocalLlmModel? active(String? selectedId) {
    if (selectedId != null) {
      var chosen = find(selectedId);
      if (chosen != null && chosen.isInstalled) return chosen;
    }
    for (var m in all) {
      if (m.isInstalled) return m;
    }
    return null;
  }

  /// Whether any local model is installed and ready to run.
  static bool anyInstalled() => all.any((m) => m.isInstalled);

  /// Rates how well a model fits a device with [totalRamBytes] of physical
  /// memory. Performance-only; see [ModelFit].
  static ModelFit fitFor(LocalLlmModel model, int? totalRamBytes) {
    if (totalRamBytes == null || totalRamBytes <= 0) {
      // Unknown memory (some platforms may not report it): don't scare the
      // user off, but don't over-promise either.
      return ModelFit.tight;
    }
    if (totalRamBytes >= model.minRecommendedRamBytes) return ModelFit.good;
    if (totalRamBytes >= model.tightRamBytes) return ModelFit.tight;
    return ModelFit.insufficient;
  }

  /// The single model to badge as "recommended" for a device: the largest
  /// model that is still a comfortable ([ModelFit.good]) fit; if none is a
  /// good fit, the smallest one (best chance of running at all). Returns null
  /// only when the registry is empty.
  static LocalLlmModel? recommendedFor(int? totalRamBytes) {
    if (all.isEmpty) return null;
    // `all` is ordered large -> small; the first good-fit is the largest good.
    for (var m in all) {
      if (fitFor(m, totalRamBytes) == ModelFit.good) return m;
    }
    return all.last;
  }
}

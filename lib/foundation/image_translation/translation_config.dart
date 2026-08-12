import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/source_platform.dart';

/// The translation settings that describe *how a given comic is translated*:
/// the language pair and how the original lettering is removed.
///
/// These three resolve through the per-comic reader-settings channel, so a comic
/// with "comic specific settings" on keeps its own choice instead of writing the
/// global one — picking Japanese for one comic used to change every other comic
/// too (#178). The remaining translation settings (OCR workers, concurrency,
/// model endpoint) stay global on purpose: they are device/throughput knobs, not
/// a property of the work being read.
class TranslationConfig {
  const TranslationConfig({
    required this.sourceLang,
    required this.targetLang,
    required this.mode,
  });

  /// 'auto', or a concrete source language ('ja', 'zh', 'en', 'ko').
  final String sourceLang;

  final String targetLang;

  /// Text-removal / render mode.
  final InpaintMode mode;

  /// The settings keys backing this config, exposed so callers that mirror
  /// reader settings (the settings page, the sync opt-out list) stay in step.
  static const sourceKeyName = 'imageTranslationSource';
  static const targetKeyName = 'imageTranslationTarget';
  static const inpaintKeyName = 'imageTranslationInpaintMode';

  /// Resolves the config for one comic.
  ///
  /// [sourceKey] is nullable to match the cache-key call sites, which pass
  /// `ComicType.comicSource?.key` (null for local comics); it is normalized to
  /// the same identity the settings page writes under.
  static TranslationConfig of(String cid, String? sourceKey) {
    var key = sourceKey ?? SourcePlatformResolver.localCanonicalKey;
    String read(String name, String fallback) {
      var value = appdata.settings.getReaderSetting(cid, key, name);
      return value is String && value.isNotEmpty ? value : fallback;
    }

    return TranslationConfig(
      sourceLang: read(sourceKeyName, 'auto'),
      targetLang: read(targetKeyName, 'zh'),
      mode: InpaintMode.fromSettings(
        appdata.settings.getReaderSetting(cid, key, inpaintKeyName),
      ),
    );
  }

  /// The global values, for contexts with no comic in scope (the app-wide
  /// settings page).
  static TranslationConfig get global {
    return TranslationConfig(
      sourceLang: appdata.settings[sourceKeyName] as String? ?? 'auto',
      targetLang: appdata.settings[targetKeyName] as String? ?? 'zh',
      mode: InpaintMode.fromSettings(appdata.settings[inpaintKeyName]),
    );
  }

  /// Cache-key prefix for this language pair. Every page key of every comic
  /// translated with these languages starts with it, so changing the pair
  /// naturally addresses a different cache generation instead of serving pages
  /// translated into another language.
  // Generation 2 stores per-line erase rectangles and uses stricter OCR block
  // grouping. Reusing generation-1 rows would keep their broad erase boxes and
  // could still remove artwork even though the renderer itself was fixed.
  String get cachePrefix => 'pageTranslation@2@$sourceLang>$targetLang@';
}

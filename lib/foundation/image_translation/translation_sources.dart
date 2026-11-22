import 'dart:convert';

import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_targets.dart';

const _rapidOcrBase =
    'https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/master';

/// The same recognizer and dictionary can serve several source languages.
class RecognitionModel {
  const RecognitionModel({
    required this.modelUrl,
    required this.dictUrl,
    this.inputHeight = 48,
    this.sizeBytes = 0,
  });

  const RecognitionModel.ppOcrV5(String script, this.sizeBytes)
    : modelUrl =
          '$_rapidOcrBase/onnx/PP-OCRv5/rec/${script}_PP-OCRv5_rec_mobile.onnx',
      dictUrl =
          '$_rapidOcrBase/paddle/PP-OCRv5/rec/${script}_PP-OCRv5_rec_mobile/ppocrv5_${script}_dict.txt',
      inputHeight = 48;

  final String modelUrl;
  final String dictUrl;

  /// Recognition input height: 48 for PP-OCRv3 and later, 32 for older models.
  final int inputHeight;

  /// Download size probed when the entry was saved; 0 when the host did not
  /// report one.
  final int sizeBytes;

  /// Worker engine key. Derived from the files rather than the code, so
  /// editing a URL never reuses the files downloaded for the old one.
  String get engine =>
      'custom_${modelHash('$modelUrl\n$dictUrl\n$inputHeight')}';

  ModelComponent get component => ModelComponent(
    id: engine,
    approxSizeBytes: sizeBytes,
    marker: true,
    files: [
      ModelFile('rec.onnx', [modelUrl]),
      ModelFile('dict.txt', [dictUrl]),
    ],
  );
}

class CustomSourceLanguage extends RecognitionModel {
  const CustomSourceLanguage({
    required this.code,
    required this.name,
    required super.modelUrl,
    required super.dictUrl,
    super.inputHeight,
    super.sizeBytes,
  });

  /// Part of stored translation keys, so fixed once added.
  final String code;
  final String name;

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'model': modelUrl,
    'dict': dictUrl,
    'height': inputHeight,
    'size': sizeBytes,
  };

  static CustomSourceLanguage? fromJson(Object? item) {
    if (item is! Map) return null;
    var code = TranslationTargets.normalizeCode('${item['code'] ?? ''}');
    var name = '${item['name'] ?? ''}'.trim();
    var model = '${item['model'] ?? ''}'.trim();
    var dict = '${item['dict'] ?? ''}'.trim();
    if (code == null || name.isEmpty) return null;
    if (!TranslationSources.isValidUrl(model)) return null;
    if (!TranslationSources.isValidUrl(dict)) return null;
    var height = item['height'] == 32 ? 32 : 48;
    var size = item['size'] is int ? item['size'] as int : 0;
    return CustomSourceLanguage(
      code: code,
      name: name,
      modelUrl: model,
      dictUrl: dict,
      inputHeight: height,
      sizeBytes: size,
    );
  }
}

/// A user-supplied text detection model (PP-OCR DBNet, ONNX) replacing the
/// built-in detector. Language independent.
class CustomDetectorModel {
  const CustomDetectorModel({required this.url, this.sizeBytes = 0});

  final String url;
  final int sizeBytes;

  ModelComponent get component => ModelComponent(
    id: 'detector_${modelHash(url)}',
    approxSizeBytes: sizeBytes,
    marker: true,
    files: [
      ModelFile('det.onnx', [url]),
    ],
  );

  Map<String, dynamic> toJson() => {'url': url, 'size': sizeBytes};

  static CustomDetectorModel? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = '${raw['url'] ?? ''}'.trim();
    if (!TranslationSources.isValidUrl(url)) return null;
    return CustomDetectorModel(
      url: url,
      sizeBytes: raw['size'] is int ? raw['size'] : 0,
    );
  }
}

/// Source languages: the built-in set plus the user's own.
abstract class TranslationSources {
  static const settingKey = 'imageTranslationCustomSources';
  static const detectorKey = 'imageTranslationCustomDetector';

  static const recognitionPresets = {
    'Latin script (French, German, Spanish...)': RecognitionModel.ppOcrV5(
      'latin',
      7900000,
    ),
    'Cyrillic (Russian, Ukrainian...)': RecognitionModel.ppOcrV5(
      'cyrillic',
      8100000,
    ),
    'Thai': RecognitionModel.ppOcrV5('th', 7900000),
  };
  static const detectorPresets = {
    'PP-OCRv6 small': CustomDetectorModel(
      url: '$_rapidOcrBase/onnx/PP-OCRv6/det/PP-OCRv6_det_small.onnx',
      sizeBytes: 9900000,
    ),
  };

  /// code -> English UI label. Codes are part of stored translation keys and
  /// of the per-comic language locks, so they must never change.
  static const builtIn = <String, String>{
    'ja': 'Japanese',
    'zh': 'Simplified Chinese',
    'zh-TW': 'Traditional Chinese',
    'en': 'English',
    'ko': 'Korean',
  };

  static List<CustomSourceLanguage> get custom {
    var raw = appdata.settings[settingKey];
    var result = <CustomSourceLanguage>[];
    if (raw is! List) return result;
    var seen = <String>{};
    for (var item in raw) {
      var language = CustomSourceLanguage.fromJson(item);
      if (language == null) continue;
      if (builtIn.containsKey(language.code) || !seen.add(language.code)) {
        continue;
      }
      result.add(language);
    }
    return result;
  }

  static CustomSourceLanguage? find(String code) {
    for (var e in custom) {
      if (e.code == code) return e;
    }
    return null;
  }

  static bool isTaken(String code) =>
      code == 'auto' || builtIn.containsKey(code) || find(code) != null;

  static bool isValidUrl(String value) {
    var uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }

  /// Adds [language], or replaces the entry with the same code. Files of a
  /// replaced model that no other entry uses are deleted.
  static void save(CustomSourceLanguage language) {
    var list = custom;
    var index = list.indexWhere((e) => e.code == language.code);
    CustomSourceLanguage? old;
    if (index == -1) {
      list.add(language);
    } else {
      old = list[index];
      list[index] = language;
    }
    _persist(list);
    if (old != null && old.engine != language.engine) {
      _deleteIfUnused(old);
    }
  }

  /// Removes the entry and its model files when no other entry shares them.
  /// Pages already translated from [code] stay stored.
  static void remove(String code) {
    var list = custom;
    var index = list.indexWhere((e) => e.code == code);
    if (index == -1) return;
    var removed = list.removeAt(index);
    _persist(list);
    _deleteIfUnused(removed);
  }

  static void _deleteIfUnused(CustomSourceLanguage language) {
    if (custom.any((e) => e.engine == language.engine)) return;
    TranslationModelStore.instance.delete(language.component);
  }

  static void _persist(List<CustomSourceLanguage> list) {
    appdata.settings[settingKey] = [for (var e in list) e.toJson()];
    appdata.saveData();
    TranslationModels.invalidateReadyCache();
  }

  static CustomDetectorModel? get detector =>
      CustomDetectorModel.fromJson(appdata.settings[detectorKey]);

  /// Older settings only stored the selected URL at the top level.
  static Map<String, CustomDetectorModel> get savedDetectors {
    final raw = appdata.settings[detectorKey];
    final urls = detectorPresets.values.map((model) => model.url).toSet();
    return {
      for (final item in [
        if (raw is Map && raw['saved'] is List) ...raw['saved'],
        raw,
      ])
        if (CustomDetectorModel.fromJson(item) case final model?)
          if (!urls.contains(model.url)) model.url: model,
    };
  }

  static void _writeDetectors(
    CustomDetectorModel? selected,
    Map<String, CustomDetectorModel> saved,
  ) {
    appdata.settings[detectorKey] = {
      ...?selected?.toJson(),
      if (saved.isNotEmpty)
        'saved': [for (final model in saved.values) model.toJson()],
    };
    appdata.saveData();
    TranslationModels.invalidateReadyCache();
  }

  /// Changing the active detector never removes a downloaded alternative.
  static void setDetector(CustomDetectorModel? model, {bool select = true}) {
    final saved = savedDetectors;
    if (model != null &&
        !detectorPresets.values.any((preset) => preset.url == model.url)) {
      saved[model.url] = model;
    }
    _writeDetectors(select ? model : detector, saved);
  }

  static Future<void> removeDetector(CustomDetectorModel model) {
    _writeDetectors(
      detector?.url == model.url ? null : detector,
      savedDetectors..remove(model.url),
    );
    return TranslationModelStore.instance.delete(model.component);
  }
}

/// Stable short hash (FNV-1a, 32 bit) for model folder names; unlike
/// [String.hashCode] it does not change between Dart versions.
String modelHash(String value) {
  var hash = 0x811c9dc5;
  for (var byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

// The AI-translation language pair and text-removal mode are per-comic (#178).
// They used to be written straight to the global settings keys even while
// "comic specific settings" was on, so choosing Japanese for one comic changed
// every other comic too. These tests pin the resolution rules.

const cidA = 'comic-a';
const cidB = 'comic-b';
const sourceKey = 'demo';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['deviceSpecificSettings'] = <String, dynamic>{};
    appdata.settings['imageTranslationSource'] = 'auto';
    appdata.settings['imageTranslationTarget'] = 'zh';
    appdata.settings['imageTranslationInpaintMode'] = 'smart';
  });

  void enableFor(String cid) {
    appdata.settings.setEnabledComicSpecificSettings(cid, sourceKey, true);
  }

  test('falls back to the global values when no override exists', () {
    var config = TranslationConfig.of(cidA, sourceKey);
    expect(config.sourceLang, 'auto');
    expect(config.targetLang, 'zh');
    expect(config.mode, InpaintMode.smart);
  });

  test('a per-comic override does not leak to another comic', () {
    enableFor(cidA);
    appdata.settings.setReaderSetting(
      cidA,
      sourceKey,
      'imageTranslationSource',
      'ja',
    );

    expect(TranslationConfig.of(cidA, sourceKey).sourceLang, 'ja');
    // The regression: comic B used to read comic A's choice via the global key.
    expect(TranslationConfig.of(cidB, sourceKey).sourceLang, 'auto');
    expect(TranslationConfig.global.sourceLang, 'auto');
  });

  test('two comics hold independent language pairs at the same time', () {
    enableFor(cidA);
    enableFor(cidB);
    appdata.settings.setReaderSetting(
      cidA,
      sourceKey,
      'imageTranslationSource',
      'ja',
    );
    appdata.settings.setReaderSetting(
      cidB,
      sourceKey,
      'imageTranslationSource',
      'ko',
    );
    appdata.settings.setReaderSetting(
      cidB,
      sourceKey,
      'imageTranslationTarget',
      'en',
    );

    expect(TranslationConfig.of(cidA, sourceKey).sourceLang, 'ja');
    expect(TranslationConfig.of(cidA, sourceKey).targetLang, 'zh');
    expect(TranslationConfig.of(cidB, sourceKey).sourceLang, 'ko');
    expect(TranslationConfig.of(cidB, sourceKey).targetLang, 'en');
  });

  test('an override is ignored while the per-comic switch is off', () {
    appdata.settings.setReaderSetting(
      cidA,
      sourceKey,
      'imageTranslationSource',
      'ja',
    );
    // Stored but not enabled: the comic must follow the global value.
    expect(TranslationConfig.of(cidA, sourceKey).sourceLang, 'auto');

    enableFor(cidA);
    expect(TranslationConfig.of(cidA, sourceKey).sourceLang, 'ja');
  });

  test('text-removal mode is per-comic and drives the render cache key', () {
    enableFor(cidA);
    appdata.settings.setReaderSetting(
      cidA,
      sourceKey,
      'imageTranslationInpaintMode',
      'patch',
    );

    expect(TranslationConfig.of(cidA, sourceKey).mode, InpaintMode.patch);
    expect(TranslationConfig.of(cidB, sourceKey).mode, InpaintMode.smart);
  });

  test('the cache prefix separates comics reading different languages', () {
    enableFor(cidA);
    appdata.settings.setReaderSetting(
      cidA,
      sourceKey,
      'imageTranslationSource',
      'ja',
    );

    var a = TranslationConfig.of(cidA, sourceKey).cachePrefix;
    var b = TranslationConfig.of(cidB, sourceKey).cachePrefix;
    expect(a, isNot(b));
    // Both stay under the shared namespace so "clear all" still matches them.
    expect(a, startsWith('pageTranslation@'));
    expect(b, startsWith('pageTranslation@'));
  });

  test('the cache prefix uses the per-line erase generation', () {
    expect(
      TranslationConfig.global.cachePrefix,
      startsWith('pageTranslation@2@'),
    );
  });

  test('local comics resolve without a source key', () {
    expect(TranslationConfig.of(cidA, null).sourceLang, 'auto');
    appdata.settings.setEnabledComicSpecificSettings(cidA, 'local', true);
    appdata.settings.setReaderSetting(
      cidA,
      'local',
      'imageTranslationSource',
      'en',
    );
    expect(TranslationConfig.of(cidA, null).sourceLang, 'en');
  });

  test('a device-level override applies when no per-comic value is set', () {
    appdata.settings['deviceId'] = 'device-1';
    appdata.settings.setEnabledDeviceSpecificSettings(true);
    appdata.settings.setDeviceReaderSetting('imageTranslationTarget', 'en');

    expect(TranslationConfig.of(cidA, sourceKey).targetLang, 'en');
  });
}

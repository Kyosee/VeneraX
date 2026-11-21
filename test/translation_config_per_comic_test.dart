import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_service.dart';
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
    appdata.settings[TranslationConfig.scopeKeyName] = 'all';
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

  test('text scope follows comic, device and global reader settings', () {
    const key = TranslationConfig.scopeKeyName;
    final allPrefix = TranslationConfig.of(cidB, sourceKey).cachePrefix;
    expect(TranslationConfig.global.dialogueOnly, isFalse);
    appdata.settings['deviceId'] = 'scope-test';
    appdata.settings.setEnabledDeviceSpecificSettings(true);
    appdata.settings.setDeviceReaderSetting(key, 'dialogue');
    expect(TranslationConfig.device.dialogueOnly, isTrue);
    expect(TranslationConfig.of(cidB, sourceKey).dialogueOnly, isTrue);
    expect(TranslationConfig.of(cidB, sourceKey).cachePrefix, isNot(allPrefix));
    enableFor(cidA);
    appdata.settings.setReaderSetting(cidA, sourceKey, key, 'all');
    expect(TranslationConfig.of(cidA, sourceKey).cachePrefix, allPrefix);
    expect(TranslationConfig.global.dialogueOnly, isFalse);
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

  // #287: pre-translate a chapter online, then download it, and every page read
  // as untranslated — the key ended with the image key, which is a source url
  // online but an absolute file:// path once downloaded. The page's position in
  // its chapter is the one identity both paths agree on.
  group('page cache keys are independent of how the page is fetched', () {
    test('the same page maps to one key whether online or downloaded', () {
      var online = ImageTranslationService.cacheKeyFor(
        sourceKey,
        cidA,
        'ch1',
        3,
      );
      var downloaded = ImageTranslationService.cacheKeyFor(
        sourceKey,
        cidA,
        'ch1',
        3,
      );
      expect(online, downloaded);
    });

    test('distinct pages, chapters and comics stay distinct', () {
      var page3 = ImageTranslationService.cacheKeyFor(
        sourceKey,
        cidA,
        'ch1',
        3,
      );
      expect(
        page3,
        isNot(ImageTranslationService.cacheKeyFor(sourceKey, cidA, 'ch1', 4)),
      );
      expect(
        page3,
        isNot(ImageTranslationService.cacheKeyFor(sourceKey, cidA, 'ch2', 3)),
      );
      expect(
        page3,
        isNot(ImageTranslationService.cacheKeyFor(sourceKey, cidB, 'ch1', 3)),
      );
    });

    test('the key stays under its chapter scope prefix so deletes match', () {
      expect(
        ImageTranslationService.cacheKeyFor(sourceKey, cidA, 'ch1', 3),
        startsWith(
          ImageTranslationService.chapterScopePrefix(sourceKey, cidA, 'ch1'),
        ),
      );
    });

    test('a sibling page number does not prefix-match another', () {
      // 'p1' must not be a prefix of 'p10', or a per-page probe could collide.
      var p1 = ImageTranslationService.cacheKeyFor(sourceKey, cidA, 'ch1', 1);
      var p10 = ImageTranslationService.cacheKeyFor(sourceKey, cidA, 'ch1', 10);
      expect(p10, isNot(startsWith(p1)));
    });

    test('the legacy key reproduces the old transport-derived shape', () {
      expect(
        ImageTranslationService.legacyCacheKeyFor(
          'https://cdn/page-3.jpg',
          sourceKey,
          cidA,
          'ch1',
        ),
        '${ImageTranslationService.chapterScopePrefix(sourceKey, cidA, 'ch1')}'
        'https://cdn/page-3.jpg',
      );
    });
  });
}

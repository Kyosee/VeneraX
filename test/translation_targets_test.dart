import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_config.dart';
import 'package:venera/foundation/image_translation/translation_targets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appdata.settings[TranslationTargets.settingKey] = <dynamic>[];
  });

  // Codes are part of every stored translation key and names go into the
  // prompt; changing either would orphan existing users' translations.
  test('built-in codes and prompt names stay fixed', () {
    expect(
      {
        for (var e in TranslationTargets.builtIn.entries)
          e.key: e.value.promptName,
      },
      {
        'zh': '简体中文',
        'zh-TW': '繁体中文（台湾用语习惯）',
        'en': 'English',
        'ja': '日本語',
        'ko': '한국어',
        'fr': 'Français',
        'de': 'Deutsch',
        'es': 'Español',
        'ru': 'Русский',
        'vi': 'Tiếng Việt',
      },
    );
  });

  test('normalizeCode canonicalizes typed codes', () {
    expect(TranslationTargets.normalizeCode(' TH '), 'th');
    expect(TranslationTargets.normalizeCode('pt_br'), 'pt-BR');
    expect(TranslationTargets.normalizeCode('ZH-hant'), 'zh-Hant');
    expect(TranslationTargets.normalizeCode('zh-hant-hk'), 'zh-Hant-HK');
    expect(TranslationTargets.normalizeCode('es-419'), 'es-419');
    expect(TranslationTargets.normalizeCode('fil'), 'fil');
  });

  test('normalizeCode rejects anything that is not a language tag', () {
    for (var bad in [
      '',
      'a',
      'auto',
      'th@x',
      'en>zh',
      'pt BR',
      'pt-',
      '-pt',
      'th--x',
      '泰语',
    ]) {
      expect(TranslationTargets.normalizeCode(bad), isNull, reason: bad);
    }
  });

  test('custom skips malformed, duplicate and built-in entries', () {
    appdata.settings[TranslationTargets.settingKey] = [
      {'code': 'th', 'name': 'ไทย'},
      {'code': 'TH', 'name': 'dup'},
      {'code': 'zh-tw', 'name': 'shadows a built-in'},
      {'code': 'bad code', 'name': 'x'},
      {'code': 'id', 'name': '  '},
      'not a map',
      {'code': 'pt_br', 'name': 'Português'},
    ];
    var custom = TranslationTargets.custom;
    expect(custom.map((e) => e.code), ['th', 'pt-BR']);
    expect(custom.map((e) => e.name), ['ไทย', 'Português']);

    appdata.settings[TranslationTargets.settingKey] = 'corrupt';
    expect(TranslationTargets.custom, isEmpty);
  });

  test('promptName prefers built-in, then custom, then the code itself', () {
    appdata.settings[TranslationTargets.settingKey] = [
      {'code': 'th', 'name': 'ไทย'},
    ];
    expect(TranslationTargets.promptName('vi'), 'Tiếng Việt');
    expect(TranslationTargets.promptName('th'), 'ไทย');
    // A removed custom language still selected somewhere keeps translating.
    expect(TranslationTargets.promptName('id'), 'id');
  });

  test('a custom code flows into the cache key unchanged', () {
    appdata.settings['comicSpecificSettings'] = <String, dynamic>{};
    appdata.settings['imageTranslationSource'] = 'auto';
    appdata.settings['imageTranslationTarget'] = 'pt-BR';
    try {
      expect(
        TranslationConfig.of('c', 'demo').cachePrefix,
        'pageTranslation@2@auto>pt-BR@',
      );
    } finally {
      appdata.settings['imageTranslationTarget'] = 'zh';
    }
  });

  test('save adds, renames in place and remove drops the entry', () async {
    final dir = await Directory.systemTemp.createTemp('venera_targets_');
    App.dataPath = dir.path;
    try {
      TranslationTargets.save(
        const CustomTargetLanguage(code: 'th', name: 'Thai'),
      );
      TranslationTargets.save(
        const CustomTargetLanguage(code: 'id', name: 'Bahasa Indonesia'),
      );
      TranslationTargets.save(
        const CustomTargetLanguage(code: 'th', name: 'ไทย'),
      );
      expect(TranslationTargets.custom.map((e) => '${e.code}=${e.name}'), [
        'th=ไทย',
        'id=Bahasa Indonesia',
      ]);
      expect(TranslationTargets.isTaken('th'), isTrue);
      expect(TranslationTargets.isTaken('vi'), isTrue);
      expect(TranslationTargets.isTaken('ms'), isFalse);

      TranslationTargets.remove('th');
      expect(TranslationTargets.custom.map((e) => e.code), ['id']);
      expect(TranslationTargets.isTaken('th'), isFalse);
      // Let the background writes finish before the directory goes away.
      await appdata.saveData(false);
    } finally {
      appdata.settings[TranslationTargets.settingKey] = <dynamic>[];
      await dir.delete(recursive: true);
    }
  });
}

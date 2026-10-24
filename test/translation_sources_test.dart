import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/translation_models.dart';
import 'package:venera/foundation/image_translation/translation_pipeline.dart';
import 'package:venera/foundation/image_translation/translation_sources.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/utils/opencc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await OpenCC.init();
  });

  setUp(() {
    appdata.settings[TranslationSources.settingKey] = <dynamic>[];
  });

  group('resolveOcrEngines', () {
    test('Traditional uses v5, falling back to v4 for an auto lock', () {
      expect(resolveOcrEngines('zh-TW', installed: {'zh5', 'zh'}), ['zh5']);
      expect(resolveOcrEngines('zh-TW', installed: {'zh'}), ['zh']);
      expect(resolveOcrEngines('zh-TW', installed: {'en'}), isEmpty);
    });

    test('v5 replaces v4 for Simplified and auto', () {
      expect(resolveOcrEngines('zh', installed: {'zh', 'zh5'}), ['zh5']);
      expect(resolveOcrEngines('zh', installed: {'zh'}), ['zh']);
      expect(
        resolveOcrEngines('auto', installed: {'zh', 'zh5', 'en', 'ko', 'ja'}),
        ['zh5', 'en', 'ko'],
      );
      expect(resolveOcrEngines('auto', installed: {'zh', 'en'}), ['zh', 'en']);
    });

    test('other languages keep their single engine', () {
      expect(resolveOcrEngines('ja', installed: {'ja', 'zh'}), ['ja']);
      expect(resolveOcrEngines('ko', installed: {'zh'}), isEmpty);
      expect(
        resolveOcrEngines(
          'th',
          installed: {'custom_1', 'zh'},
          customEngine: 'custom_1',
        ),
        ['custom_1'],
      );
      expect(resolveOcrEngines('th', installed: {'zh'}), isEmpty);
    });
  });

  group('detectBlockLanguage', () {
    test('built-in engines keep their labels', () {
      expect(detectBlockLanguage('あいう', 'zh'), 'ja');
      expect(detectBlockLanguage('안녕하세요', 'zh'), 'ko');
      expect(detectBlockLanguage('你們好', 'zh'), 'zh');
      expect(detectBlockLanguage('本当', 'ja'), 'ja');
      expect(detectBlockLanguage('Hello', 'zh'), 'en');
      expect(detectBlockLanguage('Hello', 'en'), 'en');
    });

    test('a custom engine labels its own script', () {
      expect(detectBlockLanguage('Ça va très bien', 'fr'), 'fr');
      expect(detectBlockLanguage('Что ты делаешь', 'ru'), 'ru');
      expect(detectBlockLanguage('สวัสดีครับ', 'th'), 'th');
      expect(detectBlockLanguage('你好', 'zh-HK'), 'zh-HK');
      expect(detectBlockLanguage('你好', 'th'), 'zh');
    });

    test('letters of other scripts count as text', () {
      for (var text in ['Ж', 'ส', 'ั', 'é', '字']) {
        expect(isScriptLetter(text.runes.first), isTrue, reason: text);
      }
      for (var text in ['!', '1', '…', ' ']) {
        expect(isScriptLetter(text.runes.first), isFalse, reason: text);
      }
    });
  });

  group('Chinese scripts', () {
    test('Traditional text is told apart from Simplified', () {
      expect(OpenCC.isMostlyTraditional('你們這些傢伙到底在說什麼'), isTrue);
      expect(OpenCC.isMostlyTraditional('你们这些家伙到底在说什么'), isFalse);
      // Shared characters only: nothing to convert, read as Simplified.
      expect(OpenCC.isMostlyTraditional('你好'), isFalse);
    });

    test('Traditional into Simplified is translated, not skipped', () {
      expect(sameLanguageAction('zh-TW', 'zh'), SameLanguageAction.translate);
      expect(sameLanguageAction('zh', 'zh'), SameLanguageAction.skip);
      expect(sameLanguageAction('zh-TW', 'zh-TW'), SameLanguageAction.skip);
      expect(
        sameLanguageAction('zh', 'zh-TW'),
        SameLanguageAction.toTraditional,
      );
      expect(sameLanguageAction('ja', 'zh'), SameLanguageAction.translate);
      expect(sameLanguageAction('en', 'en'), SameLanguageAction.skip);
      // A custom target is the model's job even for Chinese text.
      expect(sameLanguageAction('zh', 'zh-HK'), SameLanguageAction.translate);
    });
  });

  test('a vertical column is turned so its top reads first', () {
    // 2 wide x 4 tall; each pixel's red channel holds 10 * row + column.
    var pixels = Uint8List(2 * 4 * 4);
    for (var row = 0; row < 4; row++) {
      for (var col = 0; col < 2; col++) {
        pixels[(row * 2 + col) * 4] = 10 * row + col;
      }
    }
    var out = resizeTextLine(
      RgbaImage(2, 4, pixels),
      IntRect(0, 0, 2, 4),
      4,
      2,
      rotate: true,
    );
    int red(int x, int y) => out[(y * 4 + x) * 4];
    // Left to right walks the column top to bottom; the top row is the
    // column's right edge.
    expect([for (var x = 0; x < 4; x++) red(x, 0)], [1, 11, 21, 31]);
    expect([for (var x = 0; x < 4; x++) red(x, 1)], [0, 10, 20, 30]);
  });

  group('TranslationSources', () {
    Map<String, dynamic> entry(String code, {String? model}) => {
      'code': code,
      'name': 'Name $code',
      'model': model ?? 'https://example.com/$code.onnx',
      'dict': 'https://example.com/$code.txt',
      'height': 48,
      'size': 100,
    };

    test('reads entries, skipping malformed ones and built-in codes', () {
      appdata.settings[TranslationSources.settingKey] = [
        entry('TH'),
        entry('th'),
        entry('zh-tw'),
        entry('ru', model: 'ftp://example.com/ru.onnx'),
        {'code': 'fr', 'name': ''},
        'corrupt',
        {...entry('fr'), 'height': 32},
      ];
      var custom = TranslationSources.custom;
      expect(custom.map((e) => e.code), ['th', 'fr']);
      expect(custom.last.inputHeight, 32);
      expect(TranslationSources.isTaken('auto'), isTrue);
      expect(TranslationSources.isTaken('zh-TW'), isTrue);
      expect(TranslationSources.isTaken('th'), isTrue);
      expect(TranslationSources.isTaken('de'), isFalse);
    });

    test('engine key follows the files, not the code', () {
      var a = CustomSourceLanguage.fromJson(entry('th'))!;
      var renamed = CustomSourceLanguage.fromJson({
        ...entry('th'),
        'name': 'ไทย',
      })!;
      var moved = CustomSourceLanguage.fromJson(
        entry('th', model: 'https://example.com/other.onnx'),
      )!;
      expect(renamed.engine, a.engine);
      expect(moved.engine, isNot(a.engine));
      expect(a.component.marker, isTrue);
    });

    test('folder hash is stable across versions', () {
      expect(modelHash('abc'), '1a47e90b');
    });
  });
}

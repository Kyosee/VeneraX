import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';

void main() {
  group('resolveOcrPoolSize', () {
    test('mobile Japanese workloads always use one worker', () {
      expect(
        resolveOcrPoolSize(
          requested: 6,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'ja',
          hasJapaneseModel: true,
        ),
        1,
      );
      expect(
        resolveOcrPoolSize(
          requested: 2,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'auto',
          hasJapaneseModel: true,
        ),
        1,
      );
    });

    test('other mobile workloads cap explicit values at two', () {
      expect(
        resolveOcrPoolSize(
          requested: 6,
          processorCount: 8,
          isMobile: true,
          isDesktop: false,
          sourceLang: 'en',
          hasJapaneseModel: true,
        ),
        2,
      );
    });

    test('desktop keeps the existing explicit and automatic caps', () {
      expect(
        resolveOcrPoolSize(
          requested: 6,
          processorCount: 16,
          isMobile: false,
          isDesktop: true,
          sourceLang: 'auto',
          hasJapaneseModel: true,
        ),
        6,
      );
      expect(
        resolveOcrPoolSize(
          requested: 0,
          processorCount: 16,
          isMobile: false,
          isDesktop: true,
          sourceLang: 'auto',
          hasJapaneseModel: true,
        ),
        3,
      );
    });
  });

  group('OcrPageEngineHint', () {
    test('locks after two matching unambiguous signals', () {
      var hint = OcrPageEngineHint();
      hint.observe(
        text: 'ありがとう',
        language: 'ja',
        engine: 'ja',
        isVertical: false,
      );
      expect(hint.preferredEngine, isNull);
      hint.observe(
        text: 'こんにちは',
        language: 'ja',
        engine: 'ja',
        isVertical: false,
      );
      expect(hint.preferredEngine, 'ja');
    });

    test('does not use horizontal Han-only text as evidence', () {
      var hint = OcrPageEngineHint();
      for (var i = 0; i < 2; i++) {
        hint.observe(
          text: '世界和平',
          language: 'zh',
          engine: 'zh',
          isVertical: false,
        );
      }
      expect(hint.preferredEngine, isNull);
    });

    test('accepts vertical Japanese Han-only text', () {
      var hint = OcrPageEngineHint();
      for (var i = 0; i < 2; i++) {
        hint.observe(
          text: '世界',
          language: 'ja',
          engine: 'ja',
          isVertical: true,
        );
      }
      expect(hint.preferredEngine, 'ja');
    });

    test('rejects a signal when engine and detected language disagree', () {
      var hint = OcrPageEngineHint();
      for (var i = 0; i < 2; i++) {
        hint.observe(
          text: 'hello',
          language: 'en',
          engine: 'zh',
          isVertical: false,
        );
      }
      expect(hint.preferredEngine, isNull);
    });

    test('does not hint when the first two strong engines disagree', () {
      var hint = OcrPageEngineHint();
      hint.observe(
        text: 'hello',
        language: 'en',
        engine: 'en',
        isVertical: false,
      );
      hint.observe(
        text: 'ありがとう',
        language: 'ja',
        engine: 'ja',
        isVertical: false,
      );
      expect(hint.preferredEngine, isNull);
    });
  });
}

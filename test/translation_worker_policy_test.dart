import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/translation_worker.dart';
import 'package:venera/foundation/image_translation/translation_types.dart';

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

  group('clusterOcrBoxes', () {
    test('keeps aligned lines in one block', () {
      var groups = clusterOcrBoxes(
        [
          IntRect(20, 20, 100, 34),
          IntRect(24, 40, 104, 54),
          IntRect(22, 60, 102, 74),
        ],
        200,
        200,
      );
      expect(groups, hasLength(1));
      expect(groups.single, hasLength(3));
    });

    test('does not join horizontal and vertical captions', () {
      var groups = clusterOcrBoxes(
        [IntRect(20, 20, 100, 34), IntRect(72, 16, 86, 70)],
        200,
        200,
      );
      expect(groups, hasLength(2));
    });

    test('does not join text with a large scale mismatch', () {
      var groups = clusterOcrBoxes(
        [IntRect(20, 20, 100, 34), IntRect(26, 42, 108, 80)],
        200,
        200,
      );
      expect(groups, hasLength(2));
    });

    test('joins adjacent fragments from the same horizontal line', () {
      var groups = clusterOcrBoxes(
        [IntRect(20, 20, 60, 34), IntRect(68, 20, 108, 34)],
        200,
        200,
      );
      expect(groups, hasLength(1));
    });

    test('does not join adjacent long text columns', () {
      var groups = clusterOcrBoxes(
        [IntRect(10, 20, 180, 30), IntRect(184, 20, 354, 30)],
        400,
        200,
      );
      expect(groups, hasLength(2));
    });

    test('prevents transitive scale chaining across a group', () {
      var groups = clusterOcrBoxes(
        [
          IntRect(20, 10, 100, 20),
          IntRect(20, 25, 100, 45),
          IntRect(20, 50, 100, 90),
        ],
        200,
        200,
      );
      expect(groups, hasLength(2));
    });

    test('does not join captions through a diagonal bridge', () {
      var groups = clusterOcrBoxes(
        [
          IntRect(20, 20, 100, 34),
          IntRect(80, 40, 160, 54),
          IntRect(140, 60, 220, 74),
        ],
        260,
        120,
      );
      expect(groups, hasLength(2));
    });
  });
}

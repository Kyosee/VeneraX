import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';

/// Guards the glossary hygiene rule: the per-comic glossary is sent with every
/// LLM request, so it must only ever hold short proper nouns. These cases pin
/// the boundary so a future prompt/parser change can't silently let sentences,
/// URLs or numbers back in and bloat the context.
void main() {
  group('LlmTranslator.isValidGlossaryTerm', () {
    test('accepts short proper-noun pairs', () {
      expect(LlmTranslator.isValidGlossaryTerm('田中', 'Tanaka'), isTrue);
      expect(LlmTranslator.isValidGlossaryTerm('必殺技', '必杀技'), isTrue);
      expect(LlmTranslator.isValidGlossaryTerm('カカシ', '卡卡西'), isTrue);
    });

    test('rejects empty source or translation', () {
      expect(LlmTranslator.isValidGlossaryTerm('', 'x'), isFalse);
      expect(LlmTranslator.isValidGlossaryTerm('x', ''), isFalse);
    });

    test('rejects over-long entries (sentences)', () {
      expect(
        LlmTranslator.isValidGlossaryTerm(
          'これはとても長い文章です',
          'this is a very long sentence indeed',
        ),
        isFalse,
      );
    });

    test('rejects URLs / emails / paths', () {
      expect(
        LlmTranslator.isValidGlossaryTerm('site', 'https://a.com'),
        isFalse,
      );
      expect(
        LlmTranslator.isValidGlossaryTerm('mail', 'a@b.com'),
        isFalse,
      );
      expect(
        LlmTranslator.isValidGlossaryTerm('www.example.net', 'x'),
        isFalse,
      );
    });

    test('rejects sentence-like punctuation', () {
      expect(LlmTranslator.isValidGlossaryTerm('你好，世界', 'hi'), isFalse);
      expect(LlmTranslator.isValidGlossaryTerm('go!', '走'), isFalse);
    });

    test('rejects pure numbers', () {
      expect(LlmTranslator.isValidGlossaryTerm('123', '456'), isFalse);
    });
  });
}

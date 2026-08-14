import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/public_translator.dart';

/// The keyless engine returns one translation per input line, and the render
/// stage maps them onto bubbles by position. A response that is short, long or
/// oddly shaped must therefore fail loudly instead of being padded — a silent
/// pad would put a translation on the wrong bubble. These cases pin that, plus
/// the chunking that keeps a page's bubbles aligned across several requests.
void main() {
  group('PublicTranslator.parse', () {
    test('accepts the plain string-array shape', () {
      expect(
        PublicTranslator.parseForTest('["你好","谢谢"]', 2),
        equals(['你好', '谢谢']),
      );
    });

    test('accepts the [text, detectedLang] pair shape', () {
      expect(
        PublicTranslator.parseForTest('[["你好","ja"],["谢谢","ja"]]', 2),
        equals(['你好', '谢谢']),
      );
    });

    test('keeps empty entries so positions still line up', () {
      expect(
        PublicTranslator.parseForTest('[["你好","ja"],["","en"],["谢谢","ja"]]', 3),
        equals(['你好', '', '谢谢']),
      );
    });

    test('rejects a response with too few or too many entries', () {
      expect(() => PublicTranslator.parseForTest('["你好"]', 2), throwsException);
      expect(
        () => PublicTranslator.parseForTest('["你好","谢谢","早上好"]', 2),
        throwsException,
      );
    });

    test('rejects non-list and unparsable bodies', () {
      expect(
        () => PublicTranslator.parseForTest('{"error":"quota"}', 1),
        throwsException,
      );
      expect(
        () => PublicTranslator.parseForTest('<html>429</html>', 1),
        throwsException,
      );
    });

    test('unescapes entities the endpoint sometimes emits', () {
      expect(
        PublicTranslator.parseForTest('["it&#39;s a trap"]', 1),
        equals(["it's a trap"]),
      );
    });
  });

  group('PublicTranslator.chunks', () {
    test('keeps a small batch as one request', () {
      var chunks = PublicTranslator.chunksForTest(['a', 'b', 'c']);
      expect(chunks.length, 1);
      expect(chunks.first.length, 3);
    });

    test('splits on the line cap without losing or reordering lines', () {
      var texts = [for (var i = 0; i < 150; i++) 'line$i'];
      var chunks = PublicTranslator.chunksForTest(texts);
      expect(chunks.length, greaterThan(1));
      expect(chunks.expand((c) => c).toList(), equals(texts));
      expect(chunks.every((c) => c.length <= 64), isTrue);
    });

    test('splits on the character cap', () {
      var texts = [for (var i = 0; i < 8; i++) 'x' * 2000];
      var chunks = PublicTranslator.chunksForTest(texts);
      expect(chunks.length, greaterThan(1));
      expect(chunks.expand((c) => c).toList(), equals(texts));
    });

    test('a single over-long line goes out on its own, uncut', () {
      var long = 'y' * 20000;
      var chunks = PublicTranslator.chunksForTest([long]);
      expect(chunks, equals([[long]]));
    });

    test('empty input yields no requests', () {
      expect(PublicTranslator.chunksForTest(const []), isEmpty);
    });
  });

  group('LlmProvider kind round-trip', () {
    test('the keyless kind survives serialization', () {
      var provider = LlmProvider(
        id: 'p1',
        name: 'free',
        url: '',
        key: '',
        model: '',
        kind: LlmProviderKind.publicFree,
      );
      var restored = LlmProvider.fromJson(provider.toJson())!;
      expect(restored.kind, LlmProviderKind.publicFree);
      expect(restored.isPublicFree, isTrue);
    });

    test('entries written before the field existed read as OpenAI', () {
      var restored = LlmProvider.fromJson({
        'id': 'legacy',
        'name': 'old',
        'url': 'https://example.com/v1',
        'key': 'sk-x',
        'model': 'gpt-4',
      })!;
      expect(restored.kind, LlmProviderKind.openai);
      expect(restored.isPublicFree, isFalse);
    });

    test('copyWith preserves the kind unless it is replaced', () {
      var free = LlmProvider(
        id: 'p1',
        name: 'free',
        url: '',
        key: '',
        model: '',
        kind: LlmProviderKind.publicFree,
      );
      expect(free.copyWith(name: 'renamed').kind, LlmProviderKind.publicFree);
      expect(
        free.copyWith(kind: LlmProviderKind.openai).kind,
        LlmProviderKind.openai,
      );
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';

void main() {
  test('known provider URL resolves to beginner template', () {
    expect(
      LlmProviderTemplate.idForUrl(
        'https://api.openai.com/v1/chat/completions/',
      ),
      'openai',
    );
    expect(
      LlmProviderTemplate.idForUrl('https://api.deepseek.com/'),
      'deepseek',
    );
  });

  test('unknown provider remains custom', () {
    expect(
      LlmProviderTemplate.idForUrl('http://192.168.1.8:11434/v1'),
      'custom',
    );
  });

  test('base URL validation accepts remote and LAN endpoints', () {
    expect(LlmTranslator.isValidBaseUrl('https://api.openai.com'), isTrue);
    expect(LlmTranslator.isValidBaseUrl('http://192.168.1.8:11434/v1'), isTrue);
    expect(LlmTranslator.isValidBaseUrl('api.openai.com/v1'), isFalse);
    expect(LlmTranslator.isValidBaseUrl('file:///tmp/model'), isFalse);
  });
}

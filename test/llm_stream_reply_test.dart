import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';

Stream<List<int>> _bytes(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

String _sse(String delta, {String key = 'content'}) =>
    'data: ${jsonEncode({
      'choices': [
        {'delta': {key: delta}}
      ]
    })}\n\n';

void main() {
  test('collects SSE content and skips reasoning', () async {
    var text = await LlmTranslator.readCompletion(
      _bytes([': keep-alive\n\n', _sse('think', key: 'reasoning_content'),
        _sse('{"a"'), _sse(':1}'), 'data: [DONE]\n\n']),
      isEventStream: true,
      maxContentChars: 100,
    );
    expect(text, '{"a":1}');
  });

  test('falls back to plain JSON body', () async {
    var text = await LlmTranslator.readCompletion(
      _bytes([jsonEncode({
        'choices': [
          {'message': {'content': 'ok'}}
        ]
      })]),
      isEventStream: false,
      maxContentChars: 100,
    );
    expect(text, 'ok');
  });

  test('aborts a runaway reply', () async {
    expect(
      LlmTranslator.readCompletion(
        _bytes(List.filled(50, _sse('xxxxx'))),
        isEventStream: true,
        maxContentChars: 100,
      ),
      throwsException,
    );
  });

  test('aborts a stalled stream', () async {
    var controller = StreamController<List<int>>();
    controller.add(utf8.encode(_sse('a')));
    await expectLater(
      LlmTranslator.readCompletion(
        controller.stream,
        isEventStream: true,
        maxContentChars: 100,
        idleTimeout: const Duration(milliseconds: 50),
      ),
      throwsException,
    );
    await controller.close();
  });
}

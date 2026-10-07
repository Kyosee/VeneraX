import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_translation/llm_translator.dart';
import 'package:venera/foundation/image_translation/script_translator.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/translations.dart';

class _Adapter implements HttpClientAdapter {
  RequestOptions? request;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString('{"translations":["你好"]}', 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(AppTranslation.init);

  LlmProvider provider(String script) => LlmProvider(
    id: 'custom',
    name: 'Custom',
    url: 'https://example.invalid/translate',
    key: 'test-key',
    model: '',
    kind: LlmProviderKind.customScript,
    script: script,
  );

  test('passes languages, text and glossary through an async script', () async {
    final result = await ScriptTranslator.translate(
      provider('''
      async function translate(input) {
        await Promise.resolve();
        if (input.sourceLang !== 'ja' || input.targetLang !== 'zh' ||
            input.glossary.Alice !== '爱丽丝') throw new Error('Wrong input');
        return {texts: input.texts.map(text => text + '!'), glossary: {Alice: '爱丽丝'}};
      }
    '''),
      ['one', 'two'],
      'ja',
      'zh',
      glossary: {'Alice': '爱丽丝'},
    );
    expect(result.texts, ['one!', 'two!']);
    expect(result.glossary, {'Alice': '爱丽丝'});
  });

  test(
    'custom request method, headers and response mapping reach the adapter',
    () async {
      final adapter = _Adapter();
      final client = Dio()..httpClientAdapter = adapter;
      final script = ScriptTranslator.template.replaceFirst("'POST'", "'PUT'");
      final result = await ScriptTranslator.translate(
        provider(script),
        ['Hello'],
        'en',
        'zh',
        client: client,
      );
      expect(result.texts, ['你好']);
      expect(adapter.request!.method, 'PUT');
      expect(adapter.request!.headers['Authorization'], 'Bearer test-key');
      expect(jsonDecode(adapter.request!.data as String), {
        'texts': ['Hello'],
        'source': 'en',
        'target': 'zh',
      });
    },
  );

  test(
    'bad output, exceptions and missing function fail instead of misaligning text',
    () async {
      for (final (script, error) in [
        (
          'function translate() { return {texts: []}; }',
          'Translation script must return one string per input text'.tl,
        ),
        (
          'function translate() { return {texts: [42]}; }',
          'Translation script must return one string per input text'.tl,
        ),
        ('async function translate() { throw new Error("failed"); }', 'failed'),
        ('const value = 1;', 'Define function translate(input)'.tl),
      ]) {
        await expectLater(
          ScriptTranslator.translate(provider(script), ['Hello'], 'en', 'zh'),
          throwsA(predicate((e) => e.toString().contains(error))),
        );
      }
      expect(
        () => ScriptTranslator.parse({
          'texts': ['ok'],
          'glossary': {'name': 42},
        }, 1),
        throwsException,
      );
    },
  );

  test('unsettled promise times out and a later script still runs', () async {
    await expectLater(
      ScriptTranslator.translate(
        provider('function translate() { return new Promise(() => {}); }'),
        ['Hello'],
        'en',
        'zh',
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(
        predicate(
          (e) => e.toString().contains('Translation script timed out'.tl),
        ),
      ),
    );
    final result = await ScriptTranslator.translate(
      provider('function translate(input) { return input.texts; }'),
      ['ok'],
      'en',
      'zh',
    );
    expect(result.texts, ['ok']);
  });

  test('infinite JavaScript is interrupted', () async {
    await expectLater(
      ScriptTranslator.translate(
        provider('function translate() { while (true) {} }'),
        ['Hello'],
        'en',
        'zh',
        timeout: const Duration(seconds: 3),
      ),
      throwsA(predicate((e) => e.toString().contains('interrupted'))),
    );
  });

  test(
    'provider metadata round-trips while scripts stay device-local',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'venera_script_settings_',
      );
      App.dataPath = dir.path;
      appdata.settings['imageTranslationProviders'] = [];
      appdata.settings[LlmProviderStore.scriptsKey] = {};
      try {
        final entry = provider(
          'function translate(input) { return input.texts; }',
        );
        LlmProviderStore.add(entry);
        await appdata.saveData(false);
        expect(LlmProviderStore.active!.script, entry.script);
        expect(LlmTranslator.isConfigured, isTrue);
        expect(entry.toJson().containsKey('script'), isFalse);
        expect(
          LlmProvider.fromJson(entry.toJson())!.kind,
          LlmProviderKind.customScript,
        );
        expect(
          Appdata.syncDisabledFields([]),
          contains(LlmProviderStore.scriptsKey),
        );
        appdata.settings[LlmProviderStore.scriptsKey] = {};
        expect(LlmTranslator.isConfigured, isFalse);
      } finally {
        appdata.settings['imageTranslationProviders'] = [];
        appdata.settings['imageTranslationActiveProviderId'] = '';
        appdata.settings[LlmProviderStore.scriptsKey] = {};
        await dir.delete(recursive: true);
      }
    },
  );
}

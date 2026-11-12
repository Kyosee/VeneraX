import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/search_result_page.dart';

void main() {
  String apply(
    String text, {
    String sourceKey = 'a',
    Object? language = 'chinese',
    Object? sources = const ['a'],
  }) => applyAutoLanguageFilter(
    text,
    sourceKey: sourceKey,
    language: language,
    enabledSources: sources,
  );

  test('appends the language for a selected source', () {
    expect(apply('abc'), 'abc language:chinese');
  });

  test('leaves sources the user did not select untouched', () {
    expect(apply('abc', sourceKey: 'b'), 'abc');
    expect(apply('abc', sources: const []), 'abc');
  });

  test('does nothing when the filter is off or unset', () {
    expect(apply('abc', language: 'none'), 'abc');
    expect(apply('abc', language: null), 'abc');
    expect(apply('abc', sources: null), 'abc');
  });

  test('keeps a language the user typed', () {
    expect(apply('abc language:english'), 'abc language:english');
  });
}

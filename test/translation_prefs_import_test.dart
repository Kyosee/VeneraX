import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data.dart';

void main() {
  group('mergeTranslationPrefs', () {
    test('a translation-only import adds comics and keeps local ones', () {
      final merged = mergeTranslationPrefs(
        {
          'a@src': {'Taro': '太郎'},
        },
        {
          'a@src': {'Taro': '太朗'},
          'b@src': {'Hana': '花'},
        },
        replace: false,
      );
      expect(merged, {
        'a@src': {'Taro': '太郎'},
        'b@src': {'Hana': '花'},
      });
    });

    test('a full restore adopts the incoming map', () {
      final incoming = {'b@src': true};
      expect(
        mergeTranslationPrefs({'a@src': true}, incoming, replace: true),
        incoming,
      );
    });

    test('a device with nothing stored takes the incoming map', () {
      final incoming = {'b@src': 'ja'};
      expect(mergeTranslationPrefs(null, incoming, replace: false), incoming);
    });
  });
}

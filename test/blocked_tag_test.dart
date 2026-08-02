import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/tags_translation.dart';

// blockedTagOf backs the tag blocklist (#179). The list a user types and the
// tags a comic carries rarely have the same shape: sources emit bare tags or
// `namespace:value`, and a Chinese UI shows a translation of either. These
// tests pin the matching rules that bridge that gap.

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    appdata.settings['blockedTags'] = [];
    // Loads assets/tags.json through rootBundle so the translated-tag case
    // exercises the real table rather than an empty map.
    await TagsTranslation.readData();
  });

  test('no entries means nothing is blocked', () {
    expect(blockedTagOf(['NTR', 'female:sole male']), isNull);
  });

  test('empty or null tag lists are not blocked', () {
    appdata.settings['blockedTags'] = ['NTR'];
    expect(blockedTagOf(null), isNull);
    expect(blockedTagOf([]), isNull);
  });

  test('matches a bare tag, ignoring case', () {
    appdata.settings['blockedTags'] = ['ntr'];
    expect(blockedTagOf(['NTR']), 'ntr');
  });

  test('matches the value half of a namespaced tag', () {
    appdata.settings['blockedTags'] = ['sole male'];
    expect(blockedTagOf(['female:sole male']), 'sole male');
  });

  test('a partial entry covers a family of tags', () {
    appdata.settings['blockedTags'] = ['loli'];
    expect(blockedTagOf(['female:lolicon']), 'loli');
    expect(blockedTagOf(['loli']), 'loli');
  });

  test('an entry written with a namespace only matches that namespace', () {
    appdata.settings['blockedTags'] = ['female:sole'];
    expect(blockedTagOf(['female:sole male']), 'female:sole');
    expect(blockedTagOf(['male:sole female']), isNull);
  });

  test('matches the translated form of a source tag', () {
    // Users type the tag as the app renders it, not as the source sends it.
    appdata.settings['blockedTags'] = ['扶她'];
    expect(blockedTagOf(['female:futanari']), '扶她');
  });

  test('returns the first matching entry', () {
    appdata.settings['blockedTags'] = ['ntr', 'loli'];
    expect(blockedTagOf(['loli', 'ntr']), 'ntr');
  });

  test('unrelated tags are left alone', () {
    appdata.settings['blockedTags'] = ['ntr'];
    expect(blockedTagOf(['romance', 'female:sole male']), isNull);
  });

  test('ignores malformed entries instead of throwing', () {
    appdata.settings['blockedTags'] = ['', 42, 'ntr'];
    expect(blockedTagOf(['NTR']), 'ntr');
  });
}

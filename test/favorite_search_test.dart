import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';

FavoriteItem comic(
  String title, {
  String author = '',
  List<String> tags = const [],
}) {
  return FavoriteItem(
    id: title,
    name: title,
    coverPath: '',
    author: author,
    type: ComicType.local,
    tags: tags,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    appdata.settings['language'] = 'zh-CN';
    await OpenCC.init();
    await TagsTranslation.readData();
  });

  test(
    'each word matches independently across simplified and traditional fields',
    () {
      final item = comic('监狱', author: '畫師');
      expect(searchLocalFavorites([item], '監獄 画师'), [item]);
      expect(searchLocalFavorites([item], '画师 監獄'), [item]);
      expect(searchLocalFavorites([item], '监狱 畫師 missing'), isEmpty);
    },
  );

  test('pasted whitespace separates words and a blank query keeps order', () {
    final first = comic('Alpha', author: 'Beta');
    final second = comic('Other');
    expect(searchLocalFavorites([first, second], '  alpha\t beta\n'), [first]);
    expect(searchLocalFavorites([second, first], ' \t\n'), [second, first]);
  });

  test('preserves smart case and title substring matching', () {
    final item = comic('Alpha Beta');
    expect(searchLocalFavorites([item], 'alpha beta'), [item]);
    expect(searchLocalFavorites([item], 'Alpha Beta'), [item]);
    expect(searchLocalFavorites([item], 'Alpha beta'), isEmpty);
    expect(searchLocalFavorites([item], 'pha'), [item]);
  });

  test('preserves exact tags, namespaces and translated tags', () {
    final item = comic('One', tags: ['female:glasses', 'language:chinese']);
    expect(searchLocalFavorites([item], 'glasses chinese'), [item]);
    expect(searchLocalFavorites([item], 'female:glasses'), [item]);
    expect(searchLocalFavorites([item], 'glasse'), isEmpty);
    final translated = 'female:glasses'.translateTagsToCN;
    expect(translated, isNot('female:glasses'));
    expect(searchLocalFavorites([item], 'one $translated'), [item]);
  });

  test('all words are required and filtering keeps input order', () {
    final first = comic('Alpha', author: 'Beta');
    final second = comic('Alpha Two', author: 'Beta');
    expect(searchLocalFavorites([second, first], 'alpha beta'), [
      second,
      first,
    ]);
    expect(searchLocalFavorites([first], 'alpha missing'), isEmpty);
  });
}

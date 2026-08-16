import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/random_comic_scope.dart';

void main() {
  testWidgets('missing remembered folder never reaches the dropdown value', (
    tester,
  ) async {
    const rememberedFolder = '默认收藏';
    const folders = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DropdownButtonFormField<String?>(
            initialValue: randomComicAvailableFolder(rememberedFolder, folders),
            items: const [
              DropdownMenuItem<String?>(value: null, child: Text('全部收藏')),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });

  test('available remembered folder is retained', () {
    expect(randomComicAvailableFolder('默认收藏', const ['默认收藏', '稍后看']), '默认收藏');
  });

  test('reading status is restored by its stored name', () {
    expect(
      randomComicReadingScopeFromName('completed'),
      RandomComicReadingScope.completed,
    );
    expect(
      randomComicReadingScopeFromName('removed-value'),
      RandomComicReadingScope.all,
    );
  });
}

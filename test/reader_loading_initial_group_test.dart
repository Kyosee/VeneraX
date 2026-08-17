import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  test('explicit chapter index does not apply the history group offset', () {
    expect(
      resolveReaderInitialChapterGroup(initialChapter: 7, historyGroup: 2),
      isNull,
    );
  });

  test('history restoration keeps applying the history group offset', () {
    expect(
      resolveReaderInitialChapterGroup(initialChapter: null, historyGroup: 2),
      2,
    );
  });
}

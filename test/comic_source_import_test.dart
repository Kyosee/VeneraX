import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/data.dart';

void main() {
  test(
    'source reload comparison includes accounts, additions and removals',
    () async {
      final root = await Directory.systemTemp.createTemp('source-import-');
      try {
        final incoming = await Directory('${root.path}/incoming').create();
        final live = Directory('${root.path}/live');
        expect(await comicSourceFilesEqual(incoming, live), isFalse);
        await live.create();
        Future<void> write(Directory dir, String name, String text) =>
            File('${dir.path}/$name').writeAsString(text).then((_) {});
        for (final dir in [incoming, live]) {
          await write(dir, 'source.js', 'script');
          await write(dir, 'source.data', '{"account":"a"}');
        }
        await write(live, 'ignored.tmp', 'unfinished write');
        expect(await comicSourceFilesEqual(incoming, live), isTrue);
        await write(incoming, 'source.data', '{"account":"b"}');
        expect(await comicSourceFilesEqual(incoming, live), isFalse);
        await write(live, 'source.data', '{"account":"b"}');
        await write(incoming, 'source.js', 'Script');
        expect(await comicSourceFilesEqual(incoming, live), isFalse);
        await write(live, 'source.js', 'Script');
        await write(incoming, 'extra.js', 'new');
        expect(await comicSourceFilesEqual(incoming, live), isFalse);
        await write(live, 'extra.js', 'new');
        expect(await comicSourceFilesEqual(incoming, live), isTrue);
        await File('${incoming.path}/extra.js').delete();
        expect(await comicSourceFilesEqual(incoming, live), isFalse);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}

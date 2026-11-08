import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf_import.dart';

import 'fixtures/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final ohos = TargetPlatform.values.where(
    (platform) => platform.name == 'ohos',
  );
  const channel = MethodChannel('venera/pdf');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jB1kAAAAASUVORK5CYII=',
  );

  group(
    'HarmonyOS PDF import cleanup',
    () {
      late Directory root;
      late Directory library;
      late File source;
      late TargetPlatform? previousTarget;
      late bool previousMuted;

      setUp(() {
        previousTarget = debugDefaultTargetPlatformOverride;
        previousMuted = Log.isMuted;
        debugDefaultTargetPlatformOverride = ohos.single;
        Log.isMuted = true;
        expect(App.isOhos, isTrue);
        root = Directory.systemTemp.createTempSync('venera_ohos_pdf_import_');
        library = Directory(FilePath.join(root.path, 'library'))..createSync();
        source = File(FilePath.join(root.path, 'book.pdf'))
          ..writeAsBytesSync(pdfFixture(pageCount: 2));
      });

      tearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = previousTarget;
        Log.isMuted = previousMuted;
        root.deleteSync(recursive: true);
      });

      test(
        'close failure preserves a successfully imported image directory',
        () async {
          final calls = <String>[];
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            switch (call.method) {
              case 'open':
                expect(call.arguments, {'path': source.path});
                return {'id': 7, 'pages': 2};
              case 'render':
                expect(call.arguments['id'], 7);
                expect(call.arguments['index'], calls.length - 2);
                return png;
              case 'close':
                expect(call.arguments, {'id': 7});
                throw PlatformException(code: 'CLOSE_FAILED');
              default:
                fail('Unexpected PDF operation: ${call.method}');
            }
          });

          final comic = await importPdfComic(
            source,
            localPath: library.path,
            cachePath: root.path,
          );

          expect(calls, ['open', 'render', 'render', 'close']);
          expect(comic.title, 'book');
          expect(comic.cover, '1.png');
          final directory = Directory(
            FilePath.join(library.path, comic.directory),
          );
          expect(directory.existsSync(), isTrue);
          expect(directory.listSync(), hasLength(2));
          for (var page = 1; page <= 2; page++) {
            expect(
              File(
                FilePath.join(directory.path, '$page.png'),
              ).readAsBytesSync(),
              png,
            );
          }
          expect(source.existsSync(), isTrue);
        },
      );

      test(
        'render failure survives close failure and removes partial pages',
        () async {
          final calls = <String>[];
          final existing = Directory(FilePath.join(library.path, 'keep'))
            ..createSync();
          final marker = File(FilePath.join(existing.path, 'existing.txt'))
            ..writeAsStringSync('existing content');
          final partial = Directory(FilePath.join(library.path, 'book'));
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            switch (call.method) {
              case 'open':
                expect(call.arguments, {'path': source.path});
                return {'id': 9, 'pages': 2};
              case 'render':
                expect(call.arguments['id'], 9);
                if (call.arguments['index'] == 0) return png;
                expect(call.arguments['index'], 1);
                expect(
                  File(FilePath.join(partial.path, '1.png')).readAsBytesSync(),
                  png,
                );
                throw PlatformException(
                  code: 'RENDER_FAILED',
                  message: 'Original render failure',
                  details: {'page': 1},
                );
              case 'close':
                expect(call.arguments, {'id': 9});
                throw PlatformException(code: 'CLOSE_FAILED');
              default:
                fail('Unexpected PDF operation: ${call.method}');
            }
          });

          await expectLater(
            importPdfComic(
              source,
              localPath: library.path,
              cachePath: root.path,
            ),
            throwsA(
              isA<PlatformException>()
                  .having((error) => error.code, 'code', 'RENDER_FAILED')
                  .having(
                    (error) => error.message,
                    'message',
                    'Original render failure',
                  )
                  .having((error) => error.details, 'details', {'page': 1}),
            ),
          );

          expect(calls, ['open', 'render', 'render', 'close']);
          expect(partial.existsSync(), isFalse);
          expect(library.listSync().map((entry) => entry.path), [
            existing.path,
          ]);
          expect(marker.readAsStringSync(), 'existing content');
          expect(source.existsSync(), isTrue);
        },
      );
    },
    skip: ohos.isEmpty ? 'Requires the HarmonyOS Flutter SDK.' : false,
  );
}

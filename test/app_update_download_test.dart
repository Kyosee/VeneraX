import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/network/app_update_download.dart';

class _ResponseAdapter implements HttpClientAdapter {
  _ResponseAdapter(this.body);
  final ResponseBody body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => body;

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('venerax-update-test-');
    file = File('${directory.path}/package.zip');
  });
  tearDown(() async => directory.delete(recursive: true));

  Future<void> download(
    ResponseBody body, {
    CancelToken? token,
    void Function(double?)? progress,
    int size = 0,
  }) async {
    final dio = Dio()..httpClientAdapter = _ResponseAdapter(body);
    try {
      await downloadAppUpdate(
        dio: dio,
        url: 'https://updates.invalid/package.zip',
        destination: file,
        cancelToken: token ?? CancelToken(),
        onProgress: progress ?? (_) {},
        expectedSize: size,
      );
    } finally {
      dio.close(force: true);
    }
  }

  test(
    'stale update attempts are reclaimed without touching other files',
    () async {
      final updates = Directory('${directory.path}/updates')..createSync();
      final old = Directory('${updates.path}/download-old')..createSync();
      File(
        '${old.path}/VeneraX-1.0.1-windows.zip',
      ).writeAsStringSync('package');
      final unrelated = Directory('${updates.path}/keep')..createSync();
      final updater = File('${updates.path}/venera_updater.exe')
        ..writeAsStringSync('updater');
      final namedLikeAttempt = File('${updates.path}/download-file')
        ..writeAsStringSync('not a directory');

      await removeStaleUpdateAttempts(updates);
      expect(old.existsSync(), isTrue, reason: 'a fresh attempt may be in use');

      await removeStaleUpdateAttempts(
        updates,
        now: DateTime.now().add(const Duration(days: 2)),
      );
      expect(old.existsSync(), isFalse);
      expect(unrelated.existsSync(), isTrue);
      expect(updater.existsSync(), isTrue);
      expect(namedLikeAttempt.existsSync(), isTrue);

      await removeStaleUpdateAttempts(Directory('${directory.path}/missing'));
    },
  );

  test('writes complete package and reports progress', () async {
    final progress = <double?>[];
    await download(
      ResponseBody.fromBytes(
        [1, 2, 3, 4],
        200,
        headers: {
          'content-length': ['4'],
        },
      ),
      progress: progress.add,
    );
    expect(await file.readAsBytes(), [1, 2, 3, 4]);
    expect(progress.last, 1);
  });

  test('unknown package length uses indeterminate progress', () async {
    final progress = <double?>[];
    await download(ResponseBody.fromBytes([1, 2], 200), progress: progress.add);
    expect(progress, isNotEmpty);
    expect(progress.every((value) => value == null), isTrue);
    expect(await file.length(), 2);
  });

  test('expected asset size overrides a misleading content length', () async {
    await expectLater(
      download(
        ResponseBody.fromBytes(
          [1, 2],
          200,
          headers: {
            'content-length': ['2'],
          },
        ),
        size: 4,
      ),
      throwsA(isA<HttpException>()),
    );
    expect(file.existsSync(), isFalse);
  });

  test('oversized responses are stopped and removed', () async {
    await expectLater(
      download(ResponseBody.fromBytes([1, 2, 3, 4], 200), size: 2),
      throwsA(isA<HttpException>()),
    );
    expect(file.existsSync(), isFalse);
  });

  test(
    'a truncated package is removed before installation can be offered',
    () async {
      await expectLater(
        download(ResponseBody.fromBytes([1, 2], 200), size: 4),
        throwsA(isA<HttpException>()),
      );
      expect(await file.exists(), isFalse);
    },
  );

  test(
    'cancelling mid-stream closes and deletes the partial package',
    () async {
      final token = CancelToken();
      final body = ResponseBody(
        Stream.fromIterable([
          Uint8List.fromList([1, 2]),
          Uint8List.fromList([3, 4]),
        ]),
        200,
      );
      await expectLater(
        download(body, token: token, size: 4, progress: (_) => token.cancel()),
        throwsA(isA<DioException>()),
      );
      expect(await file.exists(), isFalse);
    },
  );

  test('stream failures close the file and allow a successful retry', () async {
    Stream<Uint8List> broken() async* {
      yield Uint8List.fromList([1, 2]);
      throw const HttpException('connection interrupted');
    }

    await expectLater(download(ResponseBody(broken(), 200)), throwsA(anything));
    expect(await file.exists(), isFalse);
    await download(ResponseBody.fromBytes([3, 4], 200), size: 2);
    expect(await file.readAsBytes(), [3, 4]);
  });

  test('a dismissed dialog never begins writing a package', () async {
    final token = CancelToken()..cancel();
    await expectLater(
      download(ResponseBody.fromBytes([1], 200), token: token),
      throwsA(isA<DioException>()),
    );
    expect(await file.exists(), isFalse);
  });

  test(
    'early disk errors are handled while network chunks are still pending',
    () async {
      file = File('${directory.path}/missing/package.zip');
      Stream<Uint8List> delayed() async* {
        yield Uint8List.fromList([1]);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        yield Uint8List.fromList([2]);
      }

      await expectLater(
        download(ResponseBody(delayed(), 200)),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.exists(), isFalse);
    },
  );
}

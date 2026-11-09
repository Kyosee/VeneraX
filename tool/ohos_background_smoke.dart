import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_keepalive.dart';

const _autoRun = bool.fromEnvironment('OHOS_BACKGROUND_AUTORUN');
const _chunkSize = 16 * 1024;
const _channel = MethodChannel('venera/background_keepalive');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // App.init/initComponents would open user stores and are unnecessary here.
  runApp(const MaterialApp(home: _BackgroundProbe()));
}

void _check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _Transfer {
  _Transfer(this.name, this.blocks, {this.disconnect = false});

  final String name;
  final int blocks;
  final bool disconnect;
  int get expectedBytes => blocks * _chunkSize;
  int received = 0;
  int progressEvents = 0;
  int loggedPercent = -10;
  bool serverDisconnected = false;
}

class _ProbeRun {
  _ProbeRun(this.directory, this.server, this.onEvent)
    : transcript = File('${directory.path}/events.jsonl').openWrite();

  final Directory directory;
  final HttpServer server;
  final void Function(String) onEvent;
  final IOSink transcript;
  final clock = Stopwatch()..start();
  final transfers = <String, _Transfer>{};
  final clients = <HttpClient>{};
  final handlers = <Future<void>>{};
  final serverErrors = <String>[];
  int serving = 0;
  int maxServing = 0;
  bool closed = false;

  static Future<_ProbeRun> create(void Function(String) onEvent) async {
    final cache = await getTemporaryDirectory();
    final directory = await Directory(
      cache.path,
    ).createTemp('background_probe_');
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final run = _ProbeRun(directory, server, onEvent);
    server.listen((request) {
      final work = run.serve(request).catchError((Object error) {
        if (!run.closed) run.serverErrors.add(error.toString());
      });
      run.handlers.add(work);
      unawaited(work.then((_) => run.handlers.remove(work)));
    }, onError: (Object error) => run.serverErrors.add(error.toString()));
    run.record('READY', {'directory': directory.path, 'port': server.port});
    return run;
  }

  void record(String event, [Map<String, Object?> values = const {}]) {
    final line = jsonEncode({
      'event': event,
      'elapsedMs': clock.elapsedMilliseconds,
      ...values,
    });
    debugPrint('OHOS_BACKGROUND $line');
    if (!closed) transcript.writeln(line);
    onEvent(line);
  }

  Future<void> serve(HttpRequest request) async {
    final transfer = transfers[request.uri.path];
    if (request.method != 'GET' || transfer == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    serving++;
    if (serving > maxServing) maxServing = serving;
    final response = request.response
      ..bufferOutput = false
      ..headers.contentType = ContentType.binary
      ..contentLength = transfer.expectedBytes;
    final bytes = Uint8List.fromList(
      List<int>.generate(_chunkSize, (index) => index & 255),
    );
    Socket? detached;
    try {
      final IOSink output;
      if (transfer.disconnect) {
        // Detach before sending headers; then intentionally truncate the body.
        final socket = await response.detachSocket(writeHeaders: false);
        detached = socket;
        socket.add(
          ascii.encode(
            'HTTP/1.1 200 OK\r\n'
            'Content-Type: application/octet-stream\r\n'
            'Content-Length: ${transfer.expectedBytes}\r\n'
            'Connection: close\r\n\r\n',
          ),
        );
        output = socket;
      } else {
        output = response;
      }
      final blocks = transfer.disconnect ? 3 : transfer.blocks;
      for (var index = 0; index < blocks && !closed; index++) {
        output.add(bytes);
        await output.flush();
        if (index + 1 < blocks) {
          // Pace real socket writes so background execution can be observed.
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      if (transfer.disconnect && !closed) {
        transfer.serverDisconnected = true;
        detached!.destroy();
        record('SERVER_DISCONNECT', {'transfer': transfer.name});
      } else {
        await output.close();
      }
    } finally {
      detached?.destroy();
      serving--;
    }
  }

  Future<void> download(
    _Transfer transfer,
    void Function(int, int) progress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..autoUncompress = false
      ..findProxy = (_) => 'DIRECT';
    clients.add(client);
    final file = File('${directory.path}/${transfer.name}.bin');
    final output = file.openWrite();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${server.port}/${transfer.name}'),
      );
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 5),
      );
      _check(response.statusCode == HttpStatus.ok, 'Unexpected HTTP status');
      _check(response.contentLength == transfer.expectedBytes, 'Wrong length');
      record('NETWORK_BEGIN', {'transfer': transfer.name});
      await for (final chunk in response.timeout(const Duration(seconds: 15))) {
        _check(
          transfer.received + chunk.length <= transfer.expectedBytes,
          'Response exceeded its declared length',
        );
        for (var index = 0; index < chunk.length; index++) {
          if (chunk[index] != ((transfer.received + index) & 255)) {
            throw StateError('Wrong body byte at ${transfer.received + index}');
          }
        }
        output.add(chunk);
        transfer.received += chunk.length;
        transfer.progressEvents++;
        progress(transfer.received, transfer.expectedBytes);
        final percent = transfer.received * 100 ~/ transfer.expectedBytes;
        if (percent >= transfer.loggedPercent + 10 || percent == 100) {
          transfer.loggedPercent = percent;
          record('PROGRESS', {
            'transfer': transfer.name,
            'bytes': transfer.received,
            'total': transfer.expectedBytes,
            'percent': percent,
          });
        }
      }
      _check(transfer.received == transfer.expectedBytes, 'Truncated response');
      await output.flush();
      _check(
        await file.length() == transfer.expectedBytes,
        'Wrong file length',
      );
      _check(transfer.progressEvents > 1, 'Expected multiple receive events');
    } finally {
      clients.remove(client);
      client.close(force: true);
      await output.close();
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> transfer(_Transfer transfer) async {
    var success = false;
    record('TRANSFER_BEGIN', {'transfer': transfer.name});
    try {
      await BackgroundKeepAlive.instance.runTransfer<void>(
        'Background probe ${transfer.name}',
        (progress) => download(transfer, progress),
      );
      success = true;
    } finally {
      // runTransfer awaits native remove; OS grant state needs device inspection.
      record('TRANSFER_FINALLY_RETURNED', {
        'transfer': transfer.name,
        'success': success,
        'bytes': transfer.received,
      });
    }
  }

  Future<void> verify({required bool longRun}) async {
    final first = _Transfer('first', longRun ? 80 : 8);
    final last = _Transfer('last', longRun ? 240 : 20);
    final failure = _Transfer('failure', 12, disconnect: true);
    final recovery = _Transfer('recovery', 4);
    for (final item in [first, last, failure, recovery]) {
      transfers['/${item.name}'] = item;
    }
    var lastDone = false;
    final a = transfer(first).then((_) {
      _check(!lastDone, 'The first transfer did not finish first');
      _check(
        last.received > 0 && last.received < last.expectedBytes,
        'The other transfer was not actively receiving at first completion',
      );
      record('FIRST_DONE_OTHER_ACTIVE', {
        'otherReceivedBytes': last.received,
        'otherTotalBytes': last.expectedBytes,
      });
    });
    final b = transfer(last).then((_) => lastDone = true);
    await Future.wait([a, b]);
    _check(maxServing >= 2, 'The server did not serve concurrent requests');
    record('LAST_DONE_EXPECT_NO_GRANT');

    Object? failureError;
    try {
      await transfer(failure);
    } catch (error) {
      failureError = error;
    }
    _check(
      failureError is HttpException || failureError is SocketException,
      'Expected a real HTTP/socket failure, got $failureError',
    );
    _check(
      failure.serverDisconnected &&
          failure.received > 0 &&
          failure.received < failure.expectedBytes,
      'The failure did not interrupt a partially received response',
    );
    record('FAILURE_FINALLY_EXPECT_NO_GRANT', {
      'received': failure.received,
      'errorType': failureError.runtimeType.toString(),
    });
    await transfer(recovery);
    record('RECOVERY_DONE_EXPECT_NO_GRANT');
    _check(serverErrors.isEmpty, 'Unexpected server errors: $serverErrors');
    final result = {
      'result': 'PASS',
      'checks':
          'real HTTP body, progress, concurrency, ordering, failure, recovery',
      'nativeGrant':
          'Inspect device task/notification state at lifecycle markers',
      'elapsedMs': clock.elapsedMilliseconds,
      'maxConcurrentRequests': maxServing,
      'receivedBytes': {
        for (final item in [first, last, failure, recovery])
          item.name: item.received,
      },
    };
    await File(
      '${directory.path}/result.json',
    ).writeAsString(jsonEncode(result));
    record('PASS', result);
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    for (final client in clients.toList()) {
      client.close(force: true);
    }
    await server.close(force: true);
    await Future.wait(handlers.toList());
    await transcript.flush();
    await transcript.close();
  }
}

class _BackgroundProbe extends StatefulWidget {
  const _BackgroundProbe();

  @override
  State<_BackgroundProbe> createState() => _BackgroundProbeState();
}

class _BackgroundProbeState extends State<_BackgroundProbe>
    with WidgetsBindingObserver {
  bool busy = false;
  bool granted = false;
  String status = '准备中';
  String reportPath = '';
  final events = <String>[];
  _ProbeRun? run;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_autoRun) {
        await start(longRun: false);
      } else {
        await permission(request: false);
      }
    });
  }

  void event(String line) {
    if (!mounted) return;
    setState(() {
      events.add(line);
      if (events.length > 12) events.removeAt(0);
    });
  }

  Future<bool> permission({required bool request}) async {
    try {
      _check(App.isOhos, 'Requires a HarmonyOS device');
      granted =
          await _channel.invokeMethod<bool>('notificationGranted') == true;
      if (!granted && request) {
        granted =
            await _channel.invokeMethod<bool>('requestNotification') == true;
      }
      status = granted ? '通知已允许，可以开始' : '请先允许通知，再开始传输';
    } catch (error) {
      granted = false;
      status = 'FAIL：$error';
      debugPrint('OHOS_BACKGROUND $status');
    }
    if (mounted) setState(() {});
    return granted;
  }

  Future<void> start({required bool longRun}) async {
    if (busy) return;
    setState(() {
      busy = true;
      events.clear();
      reportPath = '';
    });
    try {
      if (!await permission(request: true) || !mounted) return;
      BackgroundKeepAlive.instance.allowTransferBackground();
      final current = await _ProbeRun.create(event);
      run = current;
      if (!mounted) return;
      reportPath = current.directory.path;
      setState(() {
        status = longRun
            ? '正在传输：现在退到后台；约 20 秒结束第一路，60 秒结束第二路'
            : '正在快速自检（约 6 秒）';
      });
      await current.verify(longRun: longRun);
      status = 'PASS：真实传输、并发顺序、断流和恢复；系统授权请核对通知及设备状态';
    } catch (error, stack) {
      status = 'FAIL：$error';
      debugPrint('OHOS_BACKGROUND $status\n$stack');
      run?.record('FAIL', {'error': error.toString()});
    } finally {
      await run?.close();
      run = null;
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    run?.record('LIFECYCLE', {'state': state.name});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(run?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('鸿蒙后台传输探针')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(status),
        const SizedBox(height: 12),
        ElevatedButton(
          onPressed: busy ? null : () => permission(request: true),
          child: Text(granted ? '重新检查通知权限' : '允许通知'),
        ),
        ElevatedButton(
          onPressed: busy || !granted ? null : () => start(longRun: false),
          child: const Text('快速自检（约 6 秒）'),
        ),
        ElevatedButton(
          onPressed: busy || !granted ? null : () => start(longRun: true),
          child: const Text('后台传输（约 60 秒）'),
        ),
        const Text(
          '仅使用设备内 127.0.0.1 的真实 HTTP 传输。第一路结束后通知应保留；'
          '最后一路结束或断流后授权应释放。文件内容和字节数自动校验，'
          '系统授权需结合设备状态确认。',
        ),
        if (reportPath.isNotEmpty) SelectableText('报告：$reportPath'),
        const Divider(),
        for (final line in events) SelectableText(line),
      ],
    ),
  );
}

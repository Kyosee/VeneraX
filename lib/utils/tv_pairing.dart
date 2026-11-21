import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart'
    show AEADParameters, AESEngine, GCMBlockCipher, KeyParameter;

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

bool _lan(InternetAddress ip) {
  final b = ip.rawAddress;
  return b.length == 4 &&
      (b[0] == 10 ||
          b[0] == 192 && b[1] == 168 ||
          b[0] == 172 && b[1] >= 16 && b[1] <= 31);
}

class TvPairingCode {
  TvPairingCode._(this.address, this.port, this._key);
  final InternetAddress address;
  final int port;
  final Uint8List _key;

  Uri get qr => Uri(
    scheme: 'venera',
    host: 'tv',
    path: '/1',
    queryParameters: {'ip': address.address, 'port': '$port'},
    fragment: base64Url.encode(_key),
  );

  static TvPairingCode? parse(String input) {
    if (input.length > 512) return null;
    try {
      final uri = Uri.parse(input);
      if (uri.scheme != 'venera' || uri.host != 'tv' || uri.path != '/1') {
        return null;
      }
      final ip = InternetAddress.tryParse(uri.queryParameters['ip'] ?? '');
      final port = int.tryParse(uri.queryParameters['port'] ?? '');
      final key = base64Url.decode(uri.fragment);
      if (ip == null ||
          !_lan(ip) ||
          port == null ||
          port < 1024 ||
          port > 65535 ||
          key.length != 32) {
        return null;
      }
      return TvPairingCode._(ip, port, key);
    } on FormatException {
      return null;
    }
  }

  Uint8List _crypt(
    bool encrypt,
    Uint8List iv,
    Uint8List input,
    String purpose,
  ) =>
      (GCMBlockCipher(AESEngine())..init(
            encrypt,
            AEADParameters(
              KeyParameter(_key),
              128,
              iv,
              Uint8List.fromList(utf8.encode(purpose)),
            ),
          ))
          .process(input);

  Uint8List _seal(Map<String, dynamic> data, String purpose) {
    final iv = _randomBytes(12);
    return Uint8List.fromList([
      ...iv,
      ..._crypt(
        true,
        iv,
        Uint8List.fromList(utf8.encode(jsonEncode(data))),
        purpose,
      ),
    ]);
  }

  Map<String, dynamic> _open(Uint8List bytes, String purpose) {
    if (bytes.length < 28) throw const FormatException();
    final plain = _crypt(
      false,
      Uint8List.sublistView(bytes, 0, 12),
      Uint8List.sublistView(bytes, 12),
      purpose,
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  Future<bool> send(Map<String, dynamic> settings) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (_) => 'DIRECT';
    try {
      final id = base64Url.encode(_randomBytes(16));
      final request = await client.postUrl(
        Uri(
          scheme: 'http',
          host: address.address,
          port: port,
          path: '/settings',
        ),
      );
      request.followRedirects = false;
      request.add(_seal({'id': id, 'settings': settings}, 'settings'));
      final response = await request.close().timeout(
        const Duration(minutes: 2),
      );
      if (response.statusCode != 200) throw const FormatException();
      final ack = _open(await _read(response), 'receipt');
      return ack['id'] == id && ack['accepted'] == true;
    } finally {
      client.close(force: true);
    }
  }
}

Future<Uint8List> _read(Stream<List<int>> stream) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(const Duration(seconds: 8))) {
    if (bytes.length + chunk.length > 16384) throw const FormatException();
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

class TvPairingSession {
  TvPairingSession._(this._server, this.code);
  final HttpServer _server;
  final TvPairingCode code;
  Timer? _expiry;
  bool active = true;
  bool _pending = false;
  final _used = <String>{};

  static Future<TvPairingSession> start(
    Future<bool> Function(Map<String, dynamic>) receive,
    void Function(bool applied) ended, {
    InternetAddress? bindAddress,
    Duration lifetime = const Duration(minutes: 2),
  }) async {
    final address =
        bindAddress ??
        (await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        )).expand((interface) => interface.addresses).where(_lan).firstOrNull;
    if (address == null) throw const SocketException('LAN unavailable');
    final server = await HttpServer.bind(address, 0);
    final session = TvPairingSession._(
      server,
      TvPairingCode._(address, server.port, _randomBytes(32)),
    );
    session._expiry = Timer(lifetime, () {
      session.close();
      ended(false);
    });
    server.idleTimeout = const Duration(seconds: 10);
    server.listen((request) => session._handle(request, receive, ended));
    return session;
  }

  Future<void> _handle(
    HttpRequest request,
    Future<bool> Function(Map<String, dynamic>) receive,
    void Function(bool applied) ended,
  ) async {
    final response = request.response;
    bool ownsRequest = false;
    bool applied = false;
    try {
      if (!active ||
          _pending ||
          request.method != 'POST' ||
          request.uri.path != '/settings') {
        response.statusCode = 403;
        return;
      }
      _pending = ownsRequest = true;
      final body = code._open(await _read(request), 'settings');
      final id = body['id'];
      if (id is! String ||
          id.length != 24 ||
          _used.length >= 64 ||
          !_used.add(id) ||
          !active) {
        response.statusCode = 403;
        return;
      }
      applied = await receive(body['settings'] as Map<String, dynamic>);
      if (active) {
        response.add(code._seal({'id': id, 'accepted': applied}, 'receipt'));
      }
    } catch (_) {
      response.statusCode = 400;
    } finally {
      try {
        await response.close();
      } on IOException {
        /* Peer disconnected. */
      } finally {
        if (ownsRequest) _pending = false;
        if (applied && active) {
          close();
          ended(true);
        }
      }
    }
  }

  void close() {
    if (!active) return;
    active = false;
    _expiry?.cancel();
    unawaited(_server.close(force: true));
  }
}

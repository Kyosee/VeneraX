import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/sync_config_transfer.dart';
import 'package:venera/utils/tv_pairing.dart';

void main() {
  test('existing sync codes and TV codes have independent routes', () {
    final privateCode = Uri(
      scheme: 'venera',
      host: 'tv',
      path: '/1',
      queryParameters: {'ip': '192.168.1.10', 'port': '34000'},
      fragment: base64Url.encode(List.filled(32, 7)),
    );
    expect(TvPairingCode.parse(privateCode.toString())?.qr, privateCode);
    expect(isSyncConfigUri(privateCode.toString()), isFalse);
    expect(TvPairingCode.parse('venera://sync?v=1&d=sample'), isNull);
  });

  test('reject, retry, confirm selected fields and retire the code', () async {
    const settings = {
      'readerMode': 'galleryRightToLeft',
      'autoPageTurningInterval': 4,
    };
    var accept = false;
    var attempts = 0;
    final ended = Completer<bool>();
    final session = await TvPairingSession.start(
      (data) async {
        expect(data, settings);
        attempts++;
        return accept;
      },
      ended.complete,
      bindAddress: InternetAddress.loopbackIPv4,
    );
    addTearDown(session.close);
    expect(await session.code.send(settings), isFalse);
    accept = true;
    expect(await session.code.send(settings), isTrue);
    expect(await ended.future, isTrue);
    expect(session.active, isFalse);
    await expectLater(session.code.send(settings), throwsA(isA<IOException>()));
    expect(attempts, 2);
  });

  test('expiration and explicit revocation close the listener', () async {
    final ended = Completer<bool>();
    final session = await TvPairingSession.start(
      (_) async => fail('expired'),
      ended.complete,
      bindAddress: InternetAddress.loopbackIPv4,
      lifetime: const Duration(milliseconds: 40),
    );
    expect(await ended.future, isFalse);
    await expectLater(session.code.send({}), throwsA(isA<IOException>()));
    final revoked = await TvPairingSession.start(
      (_) async => fail('revoked'),
      (_) => fail('manual close'),
      bindAddress: InternetAddress.loopbackIPv4,
    );
    revoked.close();
    await expectLater(revoked.code.send({}), throwsA(isA<IOException>()));
  });
}

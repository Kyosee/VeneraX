import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reader/reader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('reader applies one stable system UI mode from its setting', () async {
    await applyReaderSystemUiMode(false);
    await applyReaderSystemUiMode(true);

    expect(
      calls,
      containsAllInOrder([
        isA<MethodCall>()
            .having(
              (call) => call.method,
              'method',
              'SystemChrome.setEnabledSystemUIMode',
            )
            .having(
              (call) => call.arguments,
              'arguments',
              'SystemUiMode.immersive',
            ),
        isA<MethodCall>()
            .having(
              (call) => call.method,
              'method',
              'SystemChrome.setEnabledSystemUIMode',
            )
            .having(
              (call) => call.arguments,
              'arguments',
              'SystemUiMode.edgeToEdge',
            ),
      ]),
    );
  });
}
